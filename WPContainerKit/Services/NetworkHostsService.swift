import Foundation

/// Keeps `Site.networkHosts` in step with a multisite network's subsites: reads
/// their URLs from WordPress (`wp site list`), records the hostnames other than
/// the site's own, and maps new ones inside the running container so WordPress
/// loopback requests to a subsite resolve.
///
/// Recording a host never touches the Mac's `/etc/hosts`: that write needs an
/// admin or Touch ID approval, so callers flag the missing entries and the user
/// syncs them (`wp-container domain sync`, or the Domain card).
public enum NetworkHostsService {
    /// The subsite hostnames in `wp site list --format=json` output, other than
    /// `site`'s own hosts. nil when the output isn't a JSON list of rows.
    public static func hosts(fromSiteList json: String, for site: Site) -> [String]? {
        guard let data = json.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return hosts(fromURLs: rows.compactMap { $0["url"] as? String }, for: site)
    }

    /// The hostnames of `urls` other than `site`'s own, lowercased, deduped and
    /// sorted. URLs whose host is no valid DNS name (an IP address, a bare
    /// `localhost`) are skipped: they need no hosts entry and can't hold one.
    static func hosts(fromURLs urls: [String], for site: Site) -> [String] {
        let own: Set<String> = [site.localhostHost, site.primaryHost.lowercased()]
        var hosts = Set<String>()
        for raw in urls {
            guard let host = URL(string: raw)?.host,
                  let name = DomainService.normalize(host),
                  !own.contains(name), !isIPv4Literal(name) else { continue }
            hosts.insert(name)
        }
        return hosts.sorted()
    }

    /// Read the network's subsite hosts from WordPress. nil when `site` is no
    /// multisite network or WordPress can't answer (stopped, wp-cli failed).
    public static func discover(_ site: Site, cli: ContainerCLI) async -> [String]? {
        guard site.networkType.isMultisite,
              let dbHost = try? await cli.ipAddress(of: site.dbContainerName), !dbHost.isEmpty,
              let result = try? await cli.runCapturing(SiteRecipe.wpSiteListArgs(site, dbHost: dbHost)),
              result.succeeded else { return nil }
        return hosts(fromSiteList: result.stdout, for: site)
    }

    /// Discover the network's subsite hosts and record them. Returns the site
    /// as stored afterwards, or `site` unchanged when WordPress couldn't answer.
    @discardableResult
    public static func refresh(_ site: Site, cli: ContainerCLI,
                               persistence: StorePersistence) async -> Site {
        guard let hosts = await discover(site, cli: cli) else { return site }
        return await record(hosts, for: site, cli: cli, persistence: persistence)
    }

    /// Store `hosts` as the site's `networkHosts` when they differ from the
    /// stored ones, writing only that field so a concurrent change to the rest
    /// of the record survives, and map them inside the running wp container.
    @discardableResult
    public static func record(_ hosts: [String], for site: Site, cli: ContainerCLI,
                              persistence: StorePersistence) async -> Site {
        let stored = (try? await persistence.load())?.sites.first { $0.id == site.id }
        guard let stored, stored.networkHosts != hosts else { return stored ?? site }
        let envelope = try? await persistence.mutateIfChanged { store in
            guard let i = store.sites.firstIndex(where: { $0.id == site.id }),
                  store.sites[i].networkHosts != hosts else { return false }
            store.sites[i].networkHosts = hosts
            return true
        }
        var updated = envelope?.sites.first { $0.id == site.id } ?? stored
        updated.status = site.status
        // Best-effort, like the injection on start: a stopped container gets
        // the full list on its next start anyway.
        if let gateway = (try? await cli.inspect(site.dbContainerName))?.first?.gatewayAddress,
           let args = SiteRecipe.injectLoopbackHostsArgs(updated, gateway: gateway) {
            _ = try? await cli.run(args)
        }
        return updated
    }

    /// Run after a CLI or MCP start: re-read a multisite network's subsite
    /// hosts, then return the warning to show when any of the site's hostnames
    /// are missing from `/etc/hosts`, or nil when none are.
    public static func hostsWarningAfterStart(_ site: Site, cli: ContainerCLI,
                                              persistence: StorePersistence) async -> String? {
        let current = site.networkType.isMultisite
            ? await refresh(site, cli: cli, persistence: persistence)
            : site
        let missing = HostsFileService.missingDomains(for: current)
        guard !missing.isEmpty else { return nil }
        return "\(missing.joined(separator: ", ")) \(missing.count == 1 ? "is" : "are") not in /etc/hosts — run `wp-container domain sync` (prompts for admin)."
    }

    private static func isIPv4Literal(_ host: String) -> Bool {
        host.split(separator: ".").allSatisfy { label in label.allSatisfy(\.isNumber) }
    }
}
