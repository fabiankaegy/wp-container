import Foundation

/// Orchestrates enabling/disabling trusted HTTPS for a site (PLAN.md §2f):
/// injects/removes the `X-Forwarded-Proto` snippet in wp-config.php and, when the
/// site is running, rewrites `home`/`siteurl` via wp-cli. Certificate generation
/// and the listener live in `CertificateAuthority` / `HTTPSProxy`.
public actor HTTPSIntegration {
    private let cli: ContainerCLI
    private let ca: CertificateAuthority

    public init(cli: ContainerCLI = ContainerCLI(), ca: CertificateAuthority = CertificateAuthority()) {
        self.cli = cli
        self.ca = ca
    }

    /// Enable HTTPS for `site`. Ensures certs exist, injects the wp-config
    /// snippet (backed up), and — if the DB container is running — points
    /// home/siteurl at `https://<slug>.localhost`.
    public func enable(_ site: Site) async throws {
        try await ca.ensureGenerated()
        try WPConfigService.enableForwardedProto(wordpressFolder: site.wordpressFolder)
        if let dbHost = try? await cli.ipAddress(of: site.dbContainerName), !dbHost.isEmpty {
            try await cli.run(SiteRecipe.wpSetURLsArgs(site, dbHost: dbHost, url: site.secureURL.absoluteString))
        }
    }

    /// Disable HTTPS for `site`. Removes the wp-config snippet and reverts
    /// home/siteurl to `http://127.0.0.1:<port>` when the site is running.
    public func disable(_ site: Site) async throws {
        try WPConfigService.disableForwardedProto(wordpressFolder: site.wordpressFolder)
        if let dbHost = try? await cli.ipAddress(of: site.dbContainerName), !dbHost.isEmpty {
            try await cli.run(SiteRecipe.wpSetURLsArgs(site, dbHost: dbHost, url: site.localURL.absoluteString))
        }
    }
}
