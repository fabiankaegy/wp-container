import Foundation
import Observation
import OSLog
import WPContainerKit

/// Each running site's WordPress Site Icon (the `site_icon` option), resolved
/// from its database (and downloaded through the site when its media isn't
/// local) and handed to `FaviconImageCache` as the preferred avatar image. Resolved once per run of a site, so an icon changed in WP Admin shows
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
            var file: URL?
            let relative = await SiteIconQuery.attachmentPath(for: site, cli: cli)
            if let relative {
                file = SiteIconQuery.localFile(for: site, relativePath: relative)
                if file == nil { file = await Self.download(relative, from: site) }
            }
            Self.log.notice("\(site.slug, privacy: .public): site_icon \(relative ?? "none", privacy: .public) → \(file?.path ?? "no file", privacy: .public)")
            await FaviconImageCache.shared.setPreferred(file, wordpressFolder: site.wordpressFolder)
            version += 1
        }
    }

    private static let log = Logger(subsystem: "com.fabiankaegy.wpcontainer", category: "SiteIcons")

    private static let folder: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("com.fabiankaegy.wpcontainer/SiteIcons", isDirectory: true)
    }()

    /// Fetches a Site Icon that isn't on disk (sites whose media is served from
    /// production) through the running site, which serves or redirects to it,
    /// and caches it per site and attachment path. Images only, at most 2 MB.
    private static func download(_ relative: String, from site: Site) async -> URL? {
        let ext = (relative as NSString).pathExtension.lowercased()
        guard ["png", "jpg", "jpeg", "ico", "gif", "webp"].contains(ext) else { return nil }
        let cached = folder.appendingPathComponent("\(site.id.uuidString)-\(relative.hashValueStable).\(ext)")
        if FileManager.default.fileExists(atPath: cached.path) { return cached }
        let url = site.url.appendingPathComponent("wp-content/uploads").appendingPathComponent(relative)
        let request = URLRequest(url: url, timeoutInterval: 15)
        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request, delegate: LocalTrust(host: url.host())) }
        catch { log.error("\(url.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)"); return nil }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.mimeType?.hasPrefix("image/") == true, data.count < 2_000_000 else {
            log.error("\(url.absoluteString, privacy: .public): unusable response \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            return nil
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (try? data.write(to: cached, options: .atomic)) == nil ? nil : cached
    }
}

/// Accepts the local CA's certificate for the site's own host only, so an
/// HTTPS site's icon downloads even before the CA is trusted. Redirects to
/// other hosts (e.g. production media) use normal certificate checks.
private final class LocalTrust: NSObject, URLSessionTaskDelegate, Sendable {
    let host: String?
    init(host: String?) { self.host = host }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == host, let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }
}

private extension String {
    /// A stable short hash for cache file names (Swift's `hashValue` is randomized per launch).
    var hashValueStable: String {
        var hash: UInt64 = 5381
        for byte in utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return String(hash, radix: 36)
    }
}

extension AppViewModel {
    /// Keeps Site Icons current while the main window is open.
    func syncSiteIcons() async {
        await SiteIcons.shared.sync(sites, cli: cli)
    }
}
