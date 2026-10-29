import Foundation

/// Orchestrates enabling/disabling trusted HTTPS for a site (PLAN.md §2f):
/// injects/removes the `X-Forwarded-Proto` snippet in wp-config.php and, when the
/// site is running, moves every blog's URLs onto the new scheme
/// (`SiteURLReconciler`). A stopped site is reconciled on its next start.
/// Certificate generation and the listener live in `CertificateAuthority` /
/// `HTTPSProxy`.
public actor HTTPSIntegration {
    private let cli: ContainerCLI
    private let ca: CertificateAuthority

    public init(cli: ContainerCLI = ContainerCLI(), ca: CertificateAuthority = CertificateAuthority()) {
        self.cli = cli
        self.ca = ca
    }

    /// Enable HTTPS for `site`. Ensures certs exist, injects the wp-config
    /// snippet (backed up), and — if the DB container is running — points
    /// every blog at `https://<primary host>`.
    public func enable(_ site: Site) async throws {
        try await ca.ensureGenerated()
        try WPConfigService.enableForwardedProto(wordpressFolder: site.wordpressFolder)
        try await reconcile(site, https: true)
    }

    /// Disable HTTPS for `site`. Removes the wp-config snippet and, when the
    /// site is running, points every blog at its plain-HTTP URL: `http://` on
    /// the custom domain, else `http://127.0.0.1:<port>`.
    public func disable(_ site: Site) async throws {
        try WPConfigService.disableForwardedProto(wordpressFolder: site.wordpressFolder)
        try await reconcile(site, https: false)
    }

    private func reconcile(_ site: Site, https: Bool) async throws {
        guard let dbHost = try? await cli.ipAddress(of: site.dbContainerName), !dbHost.isEmpty else { return }
        let url = SiteURL.effective(httpsEnabled: https, customDomain: site.customDomain,
                                    slug: site.slug, port: site.port)
        try await SiteURLReconciler(cli: cli).reconcile(site, dbHost: dbHost, url: url)
    }
}
