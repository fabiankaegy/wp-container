import AppKit
import Observation
import WebKit

/// Homepage snapshots for the gallery cards and the site screen hero.
///
/// A running site is loaded once in an offscreen `WKWebView` and snapshotted;
/// the PNG is cached under ~/Library/Caches so stopped sites still show their
/// last look (rendered grayscale by the views). Snapshots refresh when a site
/// is seen running and its cached image is older than `maxAge`. Captures run
/// one at a time so a gallery full of sites doesn't spin up a dozen web views.
@MainActor
@Observable
final class SitePreviews {
    private(set) var images: [UUID: NSImage] = [:]

    static let maxAge: TimeInterval = 30 * 60

    @ObservationIgnored private var capturedAt: [UUID: Date] = [:]
    @ObservationIgnored private var loadedFromDisk: Set<UUID> = []
    @ObservationIgnored private var pending: Set<UUID> = []
    @ObservationIgnored private var chain: Task<Void, Never>?

    private static let folder: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("com.fabiankaegy.wpcontainer/Previews", isDirectory: true)
    }()

    private static func file(_ id: UUID) -> URL { folder.appendingPathComponent("\(id.uuidString).png") }

    /// Loads the cached snapshot, then recaptures it when the instance is
    /// running and the snapshot is missing or stale. Call from a view's `.task`.
    func refresh(id: UUID, url: URL, isRunning: Bool, force: Bool = false) {
        loadFromDisk(id)
        guard isRunning, !pending.contains(id) else { return }
        if !force, let date = capturedAt[id], Date().timeIntervalSince(date) < Self.maxAge { return }
        pending.insert(id)
        let previous = chain
        chain = Task { [weak self] in
            await previous?.value
            // Give a freshly started site a moment to finish booting PHP.
            try? await Task.sleep(for: .seconds(2))
            let image = await PreviewCapture.snapshot(url)
            self?.store(image, for: id)
        }
    }

    private func store(_ image: NSImage?, for id: UUID) {
        pending.remove(id)
        guard let image else { return }
        images[id] = image
        capturedAt[id] = Date()
        guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        try? png.write(to: Self.file(id), options: .atomic)
    }

    private func loadFromDisk(_ id: UUID) {
        guard !loadedFromDisk.contains(id) else { return }
        loadedFromDisk.insert(id)
        let url = Self.file(id)
        guard images[id] == nil, let image = NSImage(contentsOf: url) else { return }
        images[id] = image
        capturedAt[id] = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}

/// Loads a page offscreen and returns a 1280×800 snapshot of its top.
@MainActor
private enum PreviewCapture {
    static func snapshot(_ url: URL) async -> NSImage? {
        let frame = CGRect(x: 0, y: 0, width: 1280, height: 800)
        let web = WKWebView(frame: frame, configuration: WKWebViewConfiguration())
        // WebKit only lays out and paints a view that lives in a window; this
        // one is never ordered on screen.
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        let waiter = LoadWaiter(host: url.host())
        web.navigationDelegate = waiter
        defer { web.navigationDelegate = nil; window.contentView = nil }

        web.load(URLRequest(url: url, timeoutInterval: 20))
        guard await waiter.finished(within: .seconds(25)) else { return nil }
        // Let web fonts, images and entrance animations settle.
        try? await Task.sleep(for: .seconds(1.5))
        let config = WKSnapshotConfiguration()
        config.rect = frame
        config.snapshotWidth = 960
        return try? await web.takeSnapshot(configuration: config)
    }
}

/// Resolves once the main frame finishes or fails loading. Accepts the local
/// CA's certificate for the site's own host, so HTTPS sites snapshot even
/// before the CA is trusted.
@MainActor
private final class LoadWaiter: NSObject, WKNavigationDelegate {
    private let host: String?
    private var continuation: CheckedContinuation<Bool, Never>?
    private var result: Bool?

    init(host: String?) { self.host = host }

    func finished(within timeout: Duration) async -> Bool {
        if let result { return result }
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.resolve(false)
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { continuation = $0 }
    }

    private func resolve(_ value: Bool) {
        guard result == nil else { return }
        result = value
        continuation?.resume(returning: value)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { resolve(true) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { resolve(false) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { resolve(false) }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == host, let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }
}
