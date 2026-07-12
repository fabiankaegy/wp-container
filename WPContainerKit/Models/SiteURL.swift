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

    /// The plain-HTTP URL for a proxy-served hostname (custom domains with HTTPS
    /// off route through the plain HTTP listener, PLAN.md §2i).
    public static func plain(host: String) -> URL {
        URL(string: "http://\(host)")!
    }

    /// The effective public URL, accounting for HTTPS and custom domains (§2f/§2i):
    /// - custom domain set → `http(s)://<domain>` (always via the host proxy),
    /// - else HTTPS on → `https://<slug>.localhost`,
    /// - else → `http://127.0.0.1:<port>` (direct container port).
    public static func effective(httpsEnabled: Bool, customDomain: String?, slug: String, port: Int) -> URL {
        if let domain = customDomain, !domain.isEmpty {
            return httpsEnabled ? secure(host: domain) : plain(host: domain)
        }
        return httpsEnabled ? secure(host: "\(slug).localhost") : local(port: port)
    }
}
