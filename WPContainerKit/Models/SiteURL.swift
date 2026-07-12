import Foundation

/// Single source of truth for computing a site's/env's public URLs (PLAN.md
/// §2f, and forward-looking to §2i custom domains). Keeping the http-vs-https
/// and host-selection logic here means adding a custom domain later is a
/// one-file change — `Site`/`WorktreeEnv` only forward into these helpers.
public enum SiteURL {
    /// The always-valid local URL on the published port.
    public static func local(port: Int) -> URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }

    /// The HTTPS URL for a proxy-served hostname (e.g. `<slug>.localhost`).
    public static func secure(host: String) -> URL {
        URL(string: "https://\(host)")!
    }

    /// The effective public URL: the secure host when HTTPS is enabled, else the
    /// local port. `host` is the proxy hostname (today `<slug>.localhost`; a
    /// custom domain later).
    public static func effective(httpsEnabled: Bool, host: String, port: Int) -> URL {
        httpsEnabled ? secure(host: host) : local(port: port)
    }

    /// The effective `/wp-admin` URL.
    public static func admin(httpsEnabled: Bool, host: String, port: Int) -> URL {
        effective(httpsEnabled: httpsEnabled, host: host, port: port).appendingPathComponent("wp-admin")
    }
}
