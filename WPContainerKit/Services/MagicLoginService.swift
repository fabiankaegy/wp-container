import CryptoKit
import Foundation
import Security

/// Issues one-time "magic" browser login links so agents never have to drive the
/// `wp-login.php` form (issue #13).
///
/// Design constraint — ZERO footprint in the project tree. An earlier version
/// dropped a mu-plugin into `wp-content/mu-plugins/`, but that path can sit
/// inside a user's tracked git repo (e.g. when the repo *is* `wp-content`) and
/// get committed by accident. A single-file bind mount nested inside the
/// `wordpress/` mount was rejected too: Apple `container` materializes a
/// zero-byte placeholder on the HOST at the mount point, which is equally
/// committable.
///
/// Instead the handler lives in the per-instance `php/` folder (`inst.phpConfFolder`,
/// a sibling of `wordpress/`, already bind-mounted at `/usr/local/etc/php/wpc-conf.d`
/// and activated via `PHP_INI_SCAN_DIR`) — entirely OUTSIDE any project repo. A
/// managed `wpc-login.ini` sets `auto_prepend_file` to `wpc-login-prepend.php`,
/// which returns immediately on every normal request and only bootstraps
/// WordPress when the `?wpc_login=` token is present. Because containers are
/// `--rm` and PHP reads its ini set only at startup, a newly-added handler takes
/// effect on the NEXT site start (see `ensurePrepend`'s stale-container return).
public enum MagicLoginService {
    /// The option the handler reads (SHA-256 hash + user + expiry).
    public static let optionName = "wpc_magic_login"

    /// Default link lifetime.
    public static let defaultTTL: TimeInterval = 15 * 60

    /// Handler filenames inside an instance's `php/` folder.
    static let prependFileName = "wpc-login-prepend.php"
    static let iniFileName = "wpc-login.ini"

    /// Markers used to detect our managed files for idempotent overwrite.
    static let prependMarker = "WP Container: Magic Login auto_prepend handler (managed — do not edit)"
    static let iniMarker = "; WP Container: Magic Login (managed — do not edit)"

    /// Legacy mu-plugin (pre-auto_prepend design) marker + relative path, cleaned
    /// up by `ensurePrepend` so sites created by earlier builds shed the in-tree file.
    static let legacyMuPluginRelPath = "wp-content/mu-plugins/wpc-magic-login.php"
    static let legacyMuPluginMarker = "WP Container: Magic Login (managed — do not edit)"

    /// The container-side absolute path of the prepend handler (the `php/` folder
    /// is mounted at `SiteRecipe.phpConfContainerPath`).
    static let prependContainerPath = "\(SiteRecipe.phpConfContainerPath)/\(prependFileName)"

    /// The `auto_prepend_file` handler. Runs before every PHP entry point but
    /// short-circuits unless the one-time login token is present, so normal
    /// requests pay ~nothing and never bootstrap WordPress from here. Kept in its
    /// own ini/file pair — `wpc-defaults.ini`'s user-ownership semantics stay untouched.
    static let prependContents = """
    <?php
    /*
     * \(prependMarker)
     * auto_prepend_file handler for WP Container's one-time browser login links
     * (`wpc login`). Returns immediately on every request except the single-use
     * ?wpc_login= redirect, which it validates against the \(optionName) option
     * (deleted on every attempt) before starting a logged-in wp-admin session.
     * Never echoes the token or the failure reason.
     */

    // wp-cli one-shot containers don't mount this ini, but guard anyway.
    if ( PHP_SAPI === 'cli' ) {
        return;
    }

    // Every normal web request bails here — no WordPress bootstrap, no overhead.
    if ( empty( $_GET['wpc_login'] ) ) {
        return;
    }

    // Only now (token present) do we boot WordPress, so a fatal in wp-load can
    // never white-screen a normal request.
    require_once '/var/www/html/wp-load.php';

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
    """

    /// Managed ini that wires the handler in via `auto_prepend_file`.
    static let iniContents = """
    \(iniMarker)
    ; Managed by WP Container — enables the one-time magic-login handler (issue
    ; #13). Loaded via PHP_INI_SCAN_DIR; refreshed on every site start. Do not
    ; edit; separate from wpc-defaults.ini on purpose.
    auto_prepend_file = "\(prependContainerPath)"
    """

    /// A minted login link plus the user it logs in as and its expiry.
    public struct LoginLink: Codable, Sendable {
        public let url: URL
        public let user: String
        public let expiresAt: Date
    }

    public static func prependURL(phpConfFolder: URL) -> URL {
        phpConfFolder.appendingPathComponent(prependFileName)
    }
    public static func iniURL(phpConfFolder: URL) -> URL {
        phpConfFolder.appendingPathComponent(iniFileName)
    }

    /// Ensure the auto_prepend handler + its ini exist and are current in the
    /// instance's `php/` folder (created if needed — it is bind-mounted, so it
    /// MUST exist before `container run`). Also deletes the legacy in-tree
    /// mu-plugin from earlier builds when it is ours (marker match). Idempotent:
    /// rewrites only when the shipped content changed.
    ///
    /// Returns whether the handler was ALREADY active before this call (both
    /// files present). `false` means a currently-running container predates the
    /// handler and must be restarted for magic login to work (PHP reads its ini
    /// set only at startup, and containers are `--rm`).
    @discardableResult
    public static func ensurePrepend(for inst: any RunnableInstance) throws -> Bool {
        cleanupLegacyMuPlugin(wordpressFolder: inst.wordpressFolder)

        let folder = inst.phpConfFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let php = prependURL(phpConfFolder: folder)
        let ini = iniURL(phpConfFolder: folder)
        let existedBefore = FileManager.default.fileExists(atPath: php.path)
            && FileManager.default.fileExists(atPath: ini.path)

        try writeIfDiffers(prependContents, to: php)
        try writeIfDiffers(iniContents, to: ini)
        return existedBefore
    }

    /// Remove the legacy `wp-content/mu-plugins/wpc-magic-login.php` if present
    /// AND ours (marker match) — never touches a same-named user file.
    static func cleanupLegacyMuPlugin(wordpressFolder: URL) {
        let url = wordpressFolder.appendingPathComponent(legacyMuPluginRelPath)
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              text.contains(legacyMuPluginMarker) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func writeIfDiffers(_ contents: String, to url: URL) throws {
        if let existing = try? String(contentsOf: url, encoding: .utf8), existing == contents { return }
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Mint a one-time login link for `user`: verifies the user exists, stores the
    /// token's SHA-256 hash (never the token) in the `wpc_magic_login` option via
    /// wp-cli, and returns `<publicURL>/?wpc_login=<token>` plus its expiry.
    /// `ensurePrepend(for:)` must have run (and the site been started since) first.
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
