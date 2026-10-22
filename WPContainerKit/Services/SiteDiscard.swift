import Foundation

public enum SiteDiscard {
    /// Removes a just-created site: its containers, store record, and
    /// certificate hosts, and its folder unless that was on disk before.
    public static func discard(_ site: Site, keepFolder: Bool, lifecycle: SiteLifecycle, persistence: StorePersistence) async {
        await lifecycle.deleteContainers(site)
        if !keepFolder { try? FileManager.default.trashItem(at: site.path, resultingItemURL: nil) }
        _ = try? await persistence.mutate { store in store.sites.removeAll { $0.id == site.id } }
        try? await CertificateAuthority().removeLeafCoverage(site.proxyHosts)
    }
}
