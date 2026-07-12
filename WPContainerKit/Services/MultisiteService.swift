import Foundation

/// Provisions a WordPress multisite network for a site (PLAN.md §2j): runs
/// `wp core multisite-install`, injects the `MULTISITE` constants into
/// wp-config.php (idempotent), and writes the standard network `.htaccess` into
/// the mounted `wordpress/` folder.
public actor MultisiteService {
    private let cli: ContainerCLI

    public init(cli: ContainerCLI = ContainerCLI()) {
        self.cli = cli
    }

    /// Full first-run provisioning for a network site. `installURL` is the URL
    /// the network is registered against (the site's effective URL). Assumes the
    /// site's containers are already running and `dbHost` resolved.
    public func provision(_ site: Site, dbHost: String, installURL: URL) async throws {
        let subdomains = site.networkType.isSubdomain
        try await cli.run(SiteRecipe.wpMultisiteInstallArgs(
            site, dbHost: dbHost, url: installURL.absoluteString, subdomains: subdomains))
        // `wp core multisite-install` seeds most constants, but re-assert them so
        // the config is correct regardless of what it could write to the mount.
        try injectConstants(site: site, installURL: installURL, subdomains: subdomains)
        try writeHtaccess(wordpressFolder: site.wordpressFolder, subdomains: subdomains)
    }

    /// Inject/refresh the multisite constants in wp-config.php (idempotent).
    public func injectConstants(site: Site, installURL: URL, subdomains: Bool) throws {
        // WordPress stores the network domain WITH the port for non-standard
        // ports (verified: `wp core multisite-install --url=http://127.0.0.1:8882`
        // writes `127.0.0.1:8882` into wp_site), so DOMAIN_CURRENT_SITE must match.
        let host = Self.domainWithPort(installURL) ?? site.primaryHost
        let folder = site.wordpressFolder
        try WPConfigService.setConstant("WP_ALLOW_MULTISITE", value: "true", rawValue: true, wordpressFolder: folder)
        try WPConfigService.setConstant("MULTISITE", value: "true", rawValue: true, wordpressFolder: folder)
        try WPConfigService.setConstant("SUBDOMAIN_INSTALL", value: subdomains ? "true" : "false", rawValue: true, wordpressFolder: folder)
        try WPConfigService.setConstant("DOMAIN_CURRENT_SITE", value: host, rawValue: false, wordpressFolder: folder)
        try WPConfigService.setConstant("PATH_CURRENT_SITE", value: "/", rawValue: false, wordpressFolder: folder)
        try WPConfigService.setConstant("SITE_ID_CURRENT_SITE", value: "1", rawValue: true, wordpressFolder: folder)
        try WPConfigService.setConstant("BLOG_ID_CURRENT_SITE", value: "1", rawValue: true, wordpressFolder: folder)
    }

    /// The `host[:port]` string WordPress uses for the network domain — the port
    /// is included only when it is non-standard for the scheme.
    static func domainWithPort(_ url: URL) -> String? {
        guard let host = url.host else { return nil }
        guard let port = url.port else { return host }
        let isDefault = (url.scheme == "http" && port == 80) || (url.scheme == "https" && port == 443)
        return isDefault ? host : "\(host):\(port)"
    }

    /// Write the network `.htaccess` into the mounted folder (host-side write).
    public func writeHtaccess(wordpressFolder: URL, subdomains: Bool) throws {
        let content = subdomains ? Self.subdomainHtaccess : Self.subdirectoryHtaccess
        let url = wordpressFolder.appendingPathComponent(".htaccess")
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Standard network .htaccess (WordPress core rules)

    static let subdirectoryHtaccess = """
    # BEGIN WordPress Multisite
    # Using subfolder network type: https://wordpress.org/documentation/article/htaccess/#multisite
    RewriteEngine On
    RewriteRule .* - [E=HTTP_AUTHORIZATION:%{HTTP:Authorization}]
    RewriteBase /
    RewriteRule ^index\\.php$ - [L]

    # add a trailing slash to /wp-admin
    RewriteRule ^([_0-9a-zA-Z-]+/)?wp-admin$ $1wp-admin/ [R=301,L]

    RewriteCond %{REQUEST_FILENAME} -f [OR]
    RewriteCond %{REQUEST_FILENAME} -d
    RewriteRule ^ - [L]
    RewriteRule ^([_0-9a-zA-Z-]+/)?(wp-(content|admin|includes).*) $2 [L]
    RewriteRule ^([_0-9a-zA-Z-]+/)?(.*\\.php)$ $2 [L]
    RewriteRule . index.php [L]
    # END WordPress Multisite
    """

    static let subdomainHtaccess = """
    # BEGIN WordPress Multisite
    # Using subdomain network type: https://wordpress.org/documentation/article/htaccess/#multisite
    RewriteEngine On
    RewriteRule .* - [E=HTTP_AUTHORIZATION:%{HTTP:Authorization}]
    RewriteBase /
    RewriteRule ^index\\.php$ - [L]

    # add a trailing slash to /wp-admin
    RewriteRule ^wp-admin$ wp-admin/ [R=301,L]

    RewriteCond %{REQUEST_FILENAME} -f [OR]
    RewriteCond %{REQUEST_FILENAME} -d
    RewriteRule ^ - [L]
    RewriteRule ^(wp-(content|admin|includes).*) $1 [L]
    RewriteRule ^(.*\\.php)$ $1 [L]
    RewriteRule . index.php [L]
    # END WordPress Multisite
    """
}
