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

    // MARK: - Worktree envs

    /// The ONE place a worktree env's hostname is derived: `<label>.localhost`,
    /// where the label is the env slug made DNS-safe (`dnsLabel`). Routes, cert
    /// SANs, in-container loopback hosts and advertised URLs all go through
    /// `WorktreeEnv.domainHost`, which forwards here — so moving envs to another
    /// zone is a one-line change.
    ///
    /// `.localhost` resolves to loopback natively in browsers and curl, so this
    /// never needs an /etc/hosts entry (and therefore never a Touch ID prompt —
    /// envs are routinely created by agents through the CLI/MCP).
    public static func envHost(envSlug: String) -> String {
        "\(dnsLabel(envSlug)).localhost"
    }

    /// A worktree env's domain URL: `https://<host>` when the env was migrated
    /// onto HTTPS, else `http://<host>` — both served by the host proxy (443/80).
    public static func env(host: String, https: Bool) -> URL {
        https ? secure(host: host) : plain(host: host)
    }

    /// DNS caps a single label at 63 bytes.
    public static let maxDNSLabelLength = 63

    /// `label` unchanged when it fits in one DNS label, else truncated and
    /// suffixed with `-<6-hex>`, a STABLE hash of the full input, so two long
    /// slugs sharing a prefix can't collide. Mirrors `WorktreeEnv.schemaName`,
    /// but deterministic derivation is enough here — nothing persists it.
    public static func dnsLabel(_ label: String) -> String {
        guard label.utf8.count > maxDNSLabelLength else { return label }
        let hash = WorktreeEnv.shortHash(label)
        var head = String(label.prefix(maxDNSLabelLength - hash.count - 1)) // "-" + hash
        // Avoid a doubled "--" before the hash.
        while head.hasSuffix("-") { head.removeLast() }
        return head + "-" + hash
    }
}
