import AppKit
import Foundation
import UserNotifications
import WPContainerKit

/// Native macOS notifications via `UserNotifications` (PLAN.md Task 1).
///
/// APP TARGET ONLY. `UNUserNotificationCenter` requires a proper application
/// bundle, so this type lives in the app (never the kit) and the CLI never
/// links or initializes it; a `Bundle.main.bundleIdentifier` guard additionally
/// degrades every entry point to a no-op if ever constructed outside a bundle
/// (unit tests, previews).
///
/// Authorization is requested LAZILY on the first notifiable event — never at
/// launch. A denial is remembered by the system (a subsequent
/// `requestAuthorization` never re-prompts once the status is determined), so we
/// never nag; the Settings → General pane reflects the state and deep-links to
/// System Settings when the user has turned notifications off.
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()

    /// userInfo key carrying the URL a notification's default action opens.
    /// `nonisolated` so the (nonisolated) delegate callbacks can read it.
    private nonisolated static let urlKey = "wpc.url"

    /// nil in a process without a proper bundle id (CLI, tests): calling
    /// `UNUserNotificationCenter.current()` there traps, so we guard.
    private var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }

    /// Install the delegate so notification clicks are handled while the app
    /// runs. Call once at launch. Does NOT request authorization.
    func configure() {
        center?.delegate = self
    }

    // MARK: - Master switch + authorization

    private var masterEnabled: Bool { AppSettings.notificationsEnabled }

    /// The current system authorization status (for the Settings pane).
    func authorizationStatus() async -> UNAuthorizationStatus {
        guard let center else { return .denied }
        return await center.notificationSettings().authorizationStatus
    }

    /// Explicitly request authorization (Settings "Request" button, shown only
    /// when the status is still `notDetermined`).
    @discardableResult
    func requestAuthorization() async -> Bool {
        guard let center else { return false }
        return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// Whether we may post: master switch on AND the system has (or now grants)
    /// authorization. The first notifiable event triggers the one-time prompt.
    private func ensureAuthorized() async -> Bool {
        guard masterEnabled, let center else { return false }
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .denied:                               return false
        case .notDetermined:                        return await requestAuthorization()
        @unknown default:                           return false
        }
    }

    // MARK: - Notifiable events (PLAN.md Task 1 matrix)

    /// (1) A site/env started. The caller only invokes this when the app is NOT
    /// frontmost (menu-bar-first mode); posting here is unconditional.
    func notifyStarted(name: String, url: URL, faviconFolder: URL?) {
        post(title: "\(name) is running", body: url.absoluteString, url: url, faviconFolder: faviconFolder)
    }

    /// (1) A site/env stopped (also only when the app is not frontmost).
    func notifyStopped(name: String) {
        post(title: "\(name) stopped", body: "Its containers are no longer running.", url: nil, faviconFolder: nil)
    }

    /// (2) Site creation completed.
    func notifySiteCreated(name: String, url: URL, faviconFolder: URL?) {
        post(title: "“\(name)” is ready", body: url.absoluteString, url: url, faviconFolder: faviconFolder)
    }

    /// (2) Site creation failed (concise error).
    func notifySiteCreationFailed(name: String, error: String) {
        post(title: "Couldn’t create “\(name)”", body: error, url: nil, faviconFolder: nil)
    }

    /// (3) Branch environment ready — clicking the notification opens its URL.
    func notifyEnvReady(branch: String, parent: String, url: URL, faviconFolder: URL?) {
        post(title: "Environment ready: \(branch)", body: "\(parent) · \(url.absoluteString)",
             url: url, faviconFolder: faviconFolder)
    }

    /// Settled environments were purged after the auto-purge window.
    func notifyEnvsPurged(branches: [String], keptCheckouts: Int) {
        let kept = keptCheckouts == 0 ? "" : " Kept \(keptCheckouts) checkout\(keptCheckouts == 1 ? "" : "s") with uncommitted changes."
        post(title: "Deleted \(branches.count) settled environment\(branches.count == 1 ? "" : "s")",
             body: branches.joined(separator: ", ") + "." + kept, url: nil, faviconFolder: nil)
    }

    /// (4) WordPress core update finished.
    func notifyCoreUpdated(name: String) {
        post(title: "WordPress updated", body: "Core update finished for “\(name)”.", url: nil, faviconFolder: nil)
    }

    /// (5) HTTPS proxy failed to start/bind (actionable reason, e.g. "port busy").
    func notifyProxyFailed(reason: String) {
        post(title: "HTTPS proxy didn’t start", body: reason, url: nil, faviconFolder: nil)
    }

    // MARK: - Delivery

    private func post(title: String, body: String, url: URL?, faviconFolder: URL?) {
        Task { await deliver(title: title, body: body, url: url, faviconFolder: faviconFolder) }
    }

    private func deliver(title: String, body: String, url: URL?, faviconFolder: URL?) async {
        guard await ensureAuthorized(), let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let url { content.userInfo = [Self.urlKey: url.absoluteString] }
        if let faviconFolder, let attachment = await Self.faviconAttachment(for: faviconFolder) {
            content.attachments = [attachment]
        }
        // nil trigger ⇒ deliver immediately. Unique id ⇒ never coalesced.
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await center.add(request)
    }

    /// A notification image attachment built from the site's favicon, if one is
    /// found. Best effort (PLAN "nice touch, skip if fiddly"): the cached PNG is
    /// written to a temp file that UNUserNotificationCenter copies into its own
    /// store on `add`.
    private static func faviconAttachment(for wordpressFolder: URL) async -> UNNotificationAttachment? {
        guard let png = await FaviconImageCache.shared.faviconPNG(wordpressFolder: wordpressFolder) else { return nil }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("wpc-favicon-\(UUID().uuidString).png")
        guard (try? png.write(to: tmp)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: "favicon", url: tmp, options: nil)
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Present banners even while the app is frontmost. Start/stop notifications
    /// are already gated out upstream when frontmost, so this only surfaces the
    /// completion notifications (created / env ready / core updated / proxy) — a
    /// confirmation banner the user just triggered.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Default action (clicking the notification) opens its attached URL.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        let userInfo = response.notification.request.content.userInfo
        guard let urlString = userInfo[Self.urlKey] as? String, let url = URL(string: urlString) else { return }
        await MainActor.run { NSWorkspace.shared.open(url) }
    }
}
