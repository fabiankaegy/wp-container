import Foundation

/// Orchestrates setting/clearing a site's custom domain (PLAN.md §2i): rewrites
/// the managed `/etc/hosts` block (one admin prompt) to every site's hostnames,
/// extends the CA leaf's SANs to cover the domain (+ subdomain-multisite
/// wildcard), and — when the site is running — moves WordPress's URLs onto the
/// new domain (`SiteURLReconciler`); a stopped site is reconciled on its next
/// start. The store mutation and proxy
/// reload are the caller's responsibility (the app/CLI owns those); the proxy's
/// refresh loop also re-covers SANs on its own.
public actor DomainService {
    public enum DomainError: Error, Sendable, CustomStringConvertible {
        case invalidDomain(String)
        case domainInUse(String)

        public var description: String {
            switch self {
            case .invalidDomain(let d): return "\"\(d)\" is not a valid hostname."
            case .domainInUse(let d):   return "\"\(d)\" is already used by another site."
            }
        }
    }

    private let cli: ContainerCLI
    private let ca: CertificateAuthority

    public init(cli: ContainerCLI = ContainerCLI(), ca: CertificateAuthority = CertificateAuthority()) {
        self.cli = cli
        self.ca = ca
    }

    /// Validate a hostname: dot-separated labels of `[a-z0-9-]`, no leading/
    /// trailing dash, at least two labels (e.g. `mysite.local`). Lowercased.
    public static func normalize(_ raw: String) -> String? {
        let host = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !host.isEmpty, host.count <= 253, host.contains(".") else { return nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return nil }
        for label in labels {
            guard !label.isEmpty, label.count <= 63,
                  label.first != "-", label.last != "-",
                  label.allSatisfy({ ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") || $0 == "-" })
            else { return nil }
        }
        return host
    }

    /// Apply a domain change for `site` (already carrying its new `customDomain`).
    /// `hostsDomains` is every hostname the /etc/hosts block must hold across
    /// the store (`HostsFileService.domains(for:)`), written in one pass.
    public func apply(site: Site, hostsDomains: [String]) async throws {
        try await HostsFileService.apply(domains: hostsDomains)
        try await ca.ensureLeafCovers(site.proxyHosts)
        // A custom-domain site is always served through the proxy, so make sure
        // the forwarded-proto snippet is present for correct HTTPS detection.
        if site.customDomain?.isEmpty == false {
            try? WPConfigService.enableForwardedProto(wordpressFolder: site.wordpressFolder)
        }
        if let dbHost = try? await cli.ipAddress(of: site.dbContainerName), !dbHost.isEmpty {
            try await SiteURLReconciler(cli: cli).reconcile(site, dbHost: dbHost, url: site.url)
        }
    }
}
