import CryptoKit
import Foundation
import Security

/// Issues one-time "magic" browser login links so agents never have to drive the
/// `wp-login.php` form (issue #13). The WordPress side is a tiny marker-headed
/// mu-plugin (`wp-content/mu-plugins/wpc-magic-login.php`) that reads a single-use
/// token from `?wpc_login=`, validates it against the `wpc_magic_login` option
/// (a `{hash,user,expires}` JSON blob), and — on success — starts a logged-in
/// wp-admin session. The token itself is never persisted; only its SHA-256 hash
/// is stored, and the option is deleted on the first validation attempt.
public enum MagicLoginService {
    /// Path of the managed mu-plugin, relative to a site's `wordpress/` folder.
    public static let muPluginRelPath = "wp-content/mu-plugins/wpc-magic-login.php"

    /// The option the mu-plugin reads (SHA-256 hash + user + expiry).
    public static let optionName = "wpc_magic_login"

    /// Default link lifetime.
    public static let defaultTTL: TimeInterval = 15 * 60

    /// Unique marker in the file header, used to detect our file for overwrite.
    static let marker = "WP Container: Magic Login (managed — do not edit)"

    /// The mu-plugin body. Static (no per-site interpolation) so the idempotent
    /// overwrite in `ensureMuPlugin` only rewrites when we ship a new version.
    static let pluginContents = """
    <?php
    /*
     * Plugin Name: WPC Magic Login
     * \(marker)
     * One-time browser login links issued by WP Container (`wpc login`). Reads a
     * single-use token from ?wpc_login=, validates it against the \(optionName)
     * option (deleted on every attempt), and starts a logged-in wp-admin session
     * on success. Never echoes the token or the failure reason.
     */

    add_action( 'init', function () {
        if ( empty( $_GET['wpc_login'] ) ) {
            return;
        }

        $token  = (string) wp_unslash( $_GET['wpc_login'] );
        $stored = get_option( '\(optionName)' );

        // Single use: always clear the stored token, whatever the outcome.
        delete_option( '\(optionName)' );

        $fail = static function () {
            wp_safe_redirect( add_query_arg( 'wpc_login_failed', '1', wp_login_url() ) );
            exit;
        };

        if ( ! is_string( $stored ) || '' === $stored ) {
            $fail();
        }

        $data = json_decode( $stored, true );
        if ( ! is_array( $data ) || empty( $data['hash'] ) || empty( $data['user'] ) || empty( $data['expires'] ) ) {
            $fail();
        }

        if ( time() > (int) $data['expires'] ) {
            $fail();
        }

        if ( ! hash_equals( (string) $data['hash'], hash( 'sha256', $token ) ) ) {
            $fail();
        }

        $user = get_user_by( 'login', (string) $data['user'] );
        if ( ! $user ) {
            $fail();
        }

        wp_set_current_user( $user->ID );
        wp_set_auth_cookie( $user->ID, true );
        wp_safe_redirect( admin_url() );
        exit;
    } );
    """

    /// A minted login link plus the user it logs in as and its expiry.
    public struct LoginLink: Codable, Sendable {
        public let url: URL
        public let user: String
        public let expiresAt: Date
    }

    public static func muPluginURL(wordpressFolder: URL) -> URL {
        wordpressFolder.appendingPathComponent(muPluginRelPath)
    }

    /// Write (or overwrite when the shipped content changed) the mu-plugin,
    /// creating `mu-plugins/` as needed. Idempotent — a no-op when the file is
    /// already current, so re-issuing links doesn't churn the filesystem.
    public static func ensureMuPlugin(for inst: any RunnableInstance) throws {
        let url = muPluginURL(wordpressFolder: inst.wordpressFolder)
        if let existing = try? String(contentsOf: url, encoding: .utf8), existing == pluginContents {
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try pluginContents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Mint a one-time login link for `user`: verifies the user exists, stores the
    /// token's SHA-256 hash (never the token) in the `\(optionName)` option via
    /// wp-cli, and returns `<publicURL>/?wpc_login=<token>` plus its expiry.
    /// `ensureMuPlugin(for:)` must have been called first.
    public static func issueLoginLink(for inst: any RunnableInstance,
                                      publicURL: URL,
                                      dbHost: String,
                                      cli: ContainerCLI,
                                      user: String,
                                      ttl: TimeInterval = defaultTTL,
                                      mailpitHost: String? = nil) async throws -> LoginLink {
        // Verify the target user exists (non-zero exit ⇒ absent), so the link is
        // never dead-on-arrival.
        let check = try await cli.runCapturing(
            SiteRecipe.wpProxyArgs(inst, dbHost: dbHost, wpArgs: ["user", "get", user, "--field=user_login"],
                                   mailpitHost: mailpitHost))
        guard check.exitCode == 0 else {
            throw MagicLoginError.userNotFound(user: user, slug: inst.siteSlug)
        }

        let token = randomToken()
        let hash = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
        let expiresAt = Date().addingTimeInterval(ttl)
        let payload: [String: Any] = ["hash": hash, "user": user, "expires": Int(expiresAt.timeIntervalSince1970)]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), as: UTF8.self)

        // `wp option update` upserts (update_option creates when absent). The JSON
        // is a single argv element — no host shell interpolation.
        let result = try await cli.runCapturing(
            SiteRecipe.wpProxyArgs(inst, dbHost: dbHost, wpArgs: ["option", "update", optionName, json],
                                   mailpitHost: mailpitHost))
        guard result.exitCode == 0 else {
            throw ContainerCLIError(command: ["option", "update", optionName],
                                    exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr)
        }

        var components = URLComponents(url: publicURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "wpc_login", value: token)]
        guard let url = components.url else { throw MagicLoginError.badURL(publicURL.absoluteString) }
        return LoginLink(url: url, user: user, expiresAt: expiresAt)
    }

    /// 32 random bytes, hex-encoded (64 chars).
    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            var rng = SystemRandomNumberGenerator()
            bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// Errors surfaced by `MagicLoginService` with agent-actionable messages.
public enum MagicLoginError: Error, CustomStringConvertible {
    case userNotFound(user: String, slug: String)
    case badURL(String)

    public var description: String {
        switch self {
        case .userNotFound(let user, let slug):
            return "No WordPress user '\(user)'. Create one first, e.g. `wp-container wp \(slug) -- user create \(user) \(user)@example.com --role=administrator`."
        case .badURL(let url):
            return "Could not build a login URL from '\(url)'."
        }
    }
}
