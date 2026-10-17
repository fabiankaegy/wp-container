import CryptoKit
import Foundation
import Security

/// Issues one-time "magic" browser login links so agents never have to drive the
/// `wp-login.php` form (issue #13).
///
/// Design constraint — ZERO footprint in the project tree. An earlier version
/// dropped a mu-plugin into `wp-content/mu-plugins/`, but that path can sit
/// inside a user's tracked git repo (e.g. when the repo *is* `wp-content`) and
/// get committed by accident.
///
/// The handler is now a normal `add_action('init', …)` file at
/// `php/prepend.d/wpc-login.php`, loaded by the shared master auto_prepend loader
/// (`PrependService`) at `muplugins_loaded` — entirely OUTSIDE any project repo.
/// It is a no-op on every request except the single-use `?wpc_login=` redirect.
/// Because containers are `--rm` and PHP reads its ini set only at startup, a
/// newly-added handler takes effect on the NEXT site start (see `isLoginActive`).
public enum MagicLoginService {
    /// The option the handler reads (SHA-256 hash + user + expiry).
    public static let optionName = "wpc_magic_login"

    /// Default link lifetime.
    public static let defaultTTL: TimeInterval = 15 * 60

    /// The handler filename inside `php/prepend.d/`.
    static let handlerFileName = "wpc-login.php"

    /// Marker used to detect our managed handler for idempotent overwrite.
    static let handlerMarker = "WP Container: Magic Login handler (managed — do not edit)"

    /// Legacy files cleaned up by `ensureLoginHandler`: the in-tree mu-plugin
    /// (first design) and the single-handler prepend file (second design).
    static let legacyMuPluginRelPath = "wp-content/mu-plugins/wpc-magic-login.php"
    static let legacyMuPluginMarker = "WP Container: Magic Login (managed — do not edit)"
    static let legacyPrependFileName = "wpc-login-prepend.php"
    static let legacyPrependMarker = "WP Container: Magic Login auto_prepend handler (managed — do not edit)"

    /// The handler body. Runs at `muplugins_loaded` (via the master loader) with
    /// WordPress bootstrapping normally, so it's a plain hook — no `wp-load`
    /// require, no SAPI guard beyond the immediate no-op when the token is absent.
    static let handlerContents = """
    <?php
    /*
     * \(handlerMarker)
     * One-time browser login handler for WP Container (`wpc login`), loaded via
     * the master auto_prepend loader at muplugins_loaded. No-op on every request
     * except the single-use ?wpc_login= redirect, which it validates against the
     * \(optionName) option (deleted on every attempt) before starting a
     * logged-in wp-admin session. Never echoes the token or the failure reason.
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

    /// Write (or refresh) the magic-login handler into `php/prepend.d/`, and shed
    /// the legacy in-tree mu-plugin + first-gen single-handler prepend file when
    /// they are ours (marker match). `PrependService.ensure(for:)` must run too
    /// (they're both invoked from the start path). Idempotent.
    public static func ensureLoginHandler(for inst: any RunnableInstance) throws {
        cleanupLegacyFiles(for: inst)
        try PrependService.writeHandler(phpConfFolder: inst.phpConfFolder, name: handlerFileName, contents: handlerContents)
    }

    /// Remove the legacy in-tree mu-plugin (marker-guarded) and the second-design
    /// `wpc-login-prepend.php` (marker-guarded) — never a user's own file.
    static func cleanupLegacyFiles(for inst: any RunnableInstance) {
        PrependService.removeIfMarked(inst.wordpressFolder.appendingPathComponent(legacyMuPluginRelPath),
                                      marker: legacyMuPluginMarker)
        PrependService.removeIfMarked(inst.phpConfFolder.appendingPathComponent(legacyPrependFileName),
                                      marker: legacyPrependMarker)
    }

    /// Whether magic login is fully active for a (running) instance: the master
    /// loader is ensured AND our handler file is present. `false` means a running
    /// container predates it and must be restarted for the link to work.
    public static func isLoginActive(for inst: any RunnableInstance) -> Bool {
        PrependService.isEnsured(for: inst)
            && PrependService.isHandlerPresent(phpConfFolder: inst.phpConfFolder, name: handlerFileName, marker: handlerMarker)
    }

    /// Mint a one-time login link for `user`: verifies the user exists, stores the
    /// token's SHA-256 hash (never the token) in the `wpc_magic_login` option via
    /// wp-cli, and returns `<publicURL>/?wpc_login=<token>` plus its expiry.
    /// `ensureLoginHandler(for:)` must have run (and the site been started since).
    public static func issueLoginLink(for inst: any RunnableInstance,
                                      publicURL: URL,
                                      dbHost: String,
                                      cli: ContainerCLI,
                                      user: String,
                                      ttl: TimeInterval = defaultTTL,
                                      sidecarEnvironment: [String] = []) async throws -> LoginLink {
        // Verify the target user exists (non-zero exit ⇒ absent), so the link is
        // never dead-on-arrival.
        let check = try await cli.runCapturing(
            SiteRecipe.wpProxyArgs(inst, dbHost: dbHost, wpArgs: ["user", "get", user, "--field=user_login"],
                                   sidecarEnvironment: sidecarEnvironment))
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
                                   sidecarEnvironment: sidecarEnvironment))
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
