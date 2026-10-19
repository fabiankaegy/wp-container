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

/// Loads a page offscreen and returns a 1280×800 snapshot of its top, taken
/// once entrance and scroll animations have played out.
@MainActor
private enum PreviewCapture {
    static func snapshot(_ url: URL) async -> NSImage? {
        let frame = CGRect(x: 0, y: 0, width: 1280, height: 800)
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(WKUserScript(source: prepareScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        disableHiddenPageTimerThrottling(configuration.preferences)
        let web = WKWebView(frame: frame, configuration: configuration)
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
        _ = try? await web.callAsyncJavaScript(settleScript, contentWorld: .page)
        let config = WKSnapshotConfiguration()
        config.rect = frame
        config.snapshotWidth = 960
        return try? await web.takeSnapshot(configuration: config)
    }

    /// The page counts as hidden, so WebKit clamps its timers to about one a
    /// second, which would stretch the settle pass to ~20s. There's no public
    /// switch, so flip the SPI preference when it exists.
    private static func disableHiddenPageTimerThrottling(_ preferences: WKPreferences) {
        let selector = NSSelectorFromString("_setHiddenPageDOMTimerThrottlingEnabled:")
        guard preferences.responds(to: selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(preferences.method(for: selector), to: Setter.self)(preferences, selector, false)
    }

    /// Runs before any page script. WebKit never fires requestAnimationFrame
    /// for an offscreen page, which freezes JS-driven entrance animations
    /// (Motion, GSAP) on their first frame, so frames are driven by timers and
    /// the page reports itself visible. It also emulates
    /// `prefers-reduced-motion: reduce` for `matchMedia` and CSS `@media`
    /// rules, so sites that honor it skip their motion entirely.
    private static let prepareScript = #"""
    (() => {
      let last = 0;
      window.requestAnimationFrame = (cb) => setTimeout(() => cb(last = performance.now()), Math.max(0, 16 - (performance.now() - last)));
      window.cancelAnimationFrame = (id) => clearTimeout(id);
      Object.defineProperty(Document.prototype, 'visibilityState', { get: () => 'visible' });
      Object.defineProperty(Document.prototype, 'hidden', { get: () => false });

      const rewrite = (query) => query
        .replace(/\(\s*prefers-reduced-motion\s*(:\s*reduce\s*)?\)/gi, '(min-width: 0px)')
        .replace(/\(\s*prefers-reduced-motion\s*:\s*no-preference\s*\)/gi, '(max-width: -1px)');
      const matchMedia = window.matchMedia.bind(window);
      window.matchMedia = (query) => matchMedia(rewrite(String(query)));
      const visit = (list) => {
        for (const item of list) {
          try {
            if (item.media && /prefers-reduced-motion/i.test(item.media.mediaText)) item.media.mediaText = rewrite(item.media.mediaText);
            if (item.styleSheet) visit([item.styleSheet]);
            if (item.cssRules) visit(item.cssRules);
          } catch (e) {}
        }
      };
      window.__wpcReduceMotion = () => visit(document.styleSheets);
      document.addEventListener('DOMContentLoaded', window.__wpcReduceMotion);
    })();
    """#

    /// Runs after load: scrolls through the page so scroll-triggered reveals
    /// fire, returns to the top, fast-forwards whatever animations are still
    /// running and waits for visible images. Every wait is capped, so a busy
    /// page costs a few seconds at most.
    private static let settleScript = #"""
    const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
    window.__wpcReduceMotion?.();
    await Promise.race([document.fonts.ready, sleep(2000)]);
    const step = innerHeight * 0.8;
    const end = Math.min(document.documentElement.scrollHeight, step * 15);
    for (let y = step; y < end; y += step) {
      scrollTo(0, y);
      await sleep(60);
    }
    scrollTo(0, 0);
    await sleep(300);
    window.__wpcReduceMotion?.();
    for (const animation of document.getAnimations()) {
      try { animation.finish(); } catch (e) {} // infinite ones throw; leave them be
    }
    const inView = (r) => r.bottom > 0 && r.right > 0 && r.top < innerHeight && r.left < innerWidth;
    const images = [...document.images].filter((image) => !image.complete && inView(image.getBoundingClientRect()));
    const loaded = images.map((image) => new Promise((resolve) => {
      image.addEventListener('load', resolve, { once: true });
      image.addEventListener('error', resolve, { once: true });
    }));
    await Promise.race([Promise.all(loaded), sleep(3000)]);
    await sleep(100);
    """#
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
