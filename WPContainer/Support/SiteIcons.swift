import Foundation
import Observation
import WPContainerKit

/// Each running site's WordPress Site Icon (the `site_icon` option), resolved
/// from its database and handed to `FaviconImageCache` as the preferred avatar
/// image. Resolved once per run of a site, so an icon changed in WP Admin shows
/// after the next start. `version` changes whenever an icon resolves, so
/// avatars know to reload.
@MainActor
@Observable
final class SiteIcons {
    static let shared = SiteIcons()

    private(set) var version = 0
    @ObservationIgnored private var resolved: Set<UUID> = []

    /// Resolves icons for newly running sites and forgets stopped ones.
    func sync(_ sites: [Site], cli: ContainerCLI) async {
        let running = sites.filter { $0.status.isRunning }
        resolved.formIntersection(running.map(\.id))
        for site in running where !resolved.contains(site.id) {
            resolved.insert(site.id)
            let file = await SiteIconQuery.iconFile(for: site, cli: cli)
            await FaviconImageCache.shared.setPreferred(file, wordpressFolder: site.wordpressFolder)
            version += 1
        }
    }
}

extension AppViewModel {
    /// Keeps Site Icons current while the main window is open.
    func syncSiteIcons() async {
        await SiteIcons.shared.sync(sites, cli: cli)
    }
}
