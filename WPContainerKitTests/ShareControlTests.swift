import XCTest
@testable import WPContainerKit

final class ShareControlTests: XCTestCase {

    private var tempRoot: URL!
    private var persistence: StorePersistence!
    private var statusFile: URL!

    override func setUp() async throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShareControlTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        persistence = StorePersistence(fileURL: tempRoot.appendingPathComponent("sites.json"))
        statusFile = tempRoot.appendingPathComponent("proxy-shares.json")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testRequestFailsWhenNoProxyIsRunning() async throws {
        let site = try await seed("my-site")
        let control = makeControl(running: false)
        do {
            _ = try await control.request(instanceID: site.id, ShareRequest())
            XCTFail("expected proxyNotRunning")
        } catch ShareError.proxyNotRunning {
            // expected
        }
    }

    func testRequestGeneratesAndKeepsCredentials() async throws {
        let site = try await seed("my-site")
        let control = makeControl()
        let first = try await control.request(instanceID: site.id, ShareRequest())
        XCTAssertEqual(first.password.count, 20)
        XCTAssertTrue(first.active)
        let second = try await control.request(instanceID: site.id, ShareRequest())
        XCTAssertEqual(second.password, first.password)
        let reset = try await control.request(instanceID: site.id, ShareRequest(resetPassword: true))
        XCTAssertNotEqual(reset.password, first.password)
        let stored = try await persistence.load().sites[0].share
        XCTAssertEqual(stored?.password, reset.password)
    }

    func testRequestChangesRequestIDEveryTime() async throws {
        let site = try await seed("my-site")
        let control = makeControl()
        let first = try await control.request(instanceID: site.id, ShareRequest())
        let second = try await control.request(instanceID: site.id, ShareRequest())
        XCTAssertNotNil(first.requestID)
        XCTAssertNotNil(second.requestID)
        XCTAssertNotEqual(first.requestID, second.requestID)
    }

    func testRequestRefusesSubdomainMultisite() async throws {
        let site = try await seed("my-site", networkType: .subdomain)
        do {
            _ = try await makeControl().request(instanceID: site.id, ShareRequest())
            XCTFail("expected subdomainMultisite")
        } catch ShareError.subdomainMultisite {
        }
    }

    func testRequestRefusesHostnameInUseByActiveShare() async throws {
        let other = try await seed("other-site",
            share: ShareSettings(hostname: "share.example.com", username: "share", password: "x", active: true))
        let site = try await seed("my-site", port: 8882)
        do {
            _ = try await makeControl().request(instanceID: site.id, ShareRequest(hostname: .some("share.example.com")))
            XCTFail("expected hostnameInUse")
        } catch ShareError.hostnameInUse(let hostname, let by, let assigned) {
            XCTAssertEqual(hostname, "share.example.com")
            XCTAssertEqual(by, other.slug)
            XCTAssertFalse(assigned)
        }
    }

    func testRequestRefusesHostnameInUseByLiveStatus() async throws {
        let other = try await seed("other-site",
            share: ShareSettings(username: "share", password: "x", active: true))
        let site = try await seed("my-site", port: 8882)
        ProxyControl.writeShares([ShareStatus(instanceID: other.id, slug: "other-site", state: .live,
                                              provider: "ngrok", hostname: "free.example.com")], file: statusFile)
        do {
            _ = try await makeControl().request(instanceID: site.id, ShareRequest(hostname: .some("free.example.com")))
            XCTFail("expected hostnameInUse")
        } catch ShareError.hostnameInUse(_, let by, let assigned) {
            XCTAssertEqual(by, "other-site")
            XCTAssertTrue(assigned)
        }
    }

    func testRequestRejectsInvalidHostnameAndProvider() async throws {
        let site = try await seed("my-site")
        let control = makeControl()
        do {
            _ = try await control.request(instanceID: site.id, ShareRequest(hostname: .some("bad host!")))
            XCTFail("expected invalidShareHostname")
        } catch ShareError.invalidShareHostname {
        }
        do {
            _ = try await control.request(instanceID: site.id, ShareRequest(provider: "no-such-provider"))
            XCTFail("expected providerNotFound")
        } catch ShareError.providerNotFound {
        }
        let stored = try await persistence.load().sites[0].share
        XCTAssertNil(stored)
    }

    func testAllowEntriesAreValidatedAndSaved() async throws {
        let site = try await seed("my-site")
        let control = makeControl()
        do {
            _ = try await control.request(instanceID: site.id, ShareRequest(addAllow: ["nope"]))
            XCTFail("expected invalidException")
        } catch ShareError.invalidException {
        }
        let saved = try await control.request(instanceID: site.id, ShareRequest(addAllow: ["/webhook", "?key=1"]))
        XCTAssertEqual(saved.allow.map(\.description), ["/webhook", "?key=1"])
        let again = try await control.request(instanceID: site.id, ShareRequest(addAllow: ["/webhook"]))
        XCTAssertEqual(again.allow.count, 2)
        let cleared = try await control.request(instanceID: site.id, ShareRequest(clearAllow: true))
        XCTAssertTrue(cleared.allow.isEmpty)
    }

    func testClearHostname() async throws {
        let site = try await seed("my-site")
        let control = makeControl()
        let set = try await control.request(instanceID: site.id, ShareRequest(hostname: .some("share.example.com")))
        XCTAssertEqual(set.hostname, "share.example.com")
        let kept = try await control.request(instanceID: site.id, ShareRequest())
        XCTAssertEqual(kept.hostname, "share.example.com")
        let cleared = try await control.request(instanceID: site.id, ShareRequest(hostname: .some(nil)))
        XCTAssertNil(cleared.hostname)
    }

    func testStopKeepsSettings() async throws {
        let site = try await seed("my-site")
        let control = makeControl()
        let requested = try await control.request(instanceID: site.id, ShareRequest(noAuth: true))
        XCTAssertTrue(requested.authDisabled)
        try await control.stop(instanceID: site.id)
        let storedShare = try await persistence.load().sites[0].share
        let stored = try XCTUnwrap(storedShare)
        XCTAssertFalse(stored.active)
        XCTAssertFalse(stored.authDisabled)
        XCTAssertEqual(stored.password, requested.password)
    }

    func testListReturnsSharedInstancesWithStatus() async throws {
        let shared = try await seed("my-site")
        _ = try await seed("plain-site", port: 8882, share: nil)
        let control = makeControl()
        _ = try await control.request(instanceID: shared.id, ShareRequest())
        ProxyControl.writeShares([ShareStatus(instanceID: shared.id, slug: "my-site", state: .live,
                                              provider: "ngrok")], file: statusFile)
        let rows = try await control.list()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].instance.instanceID, shared.id)
        XCTAssertEqual(rows[0].status?.state, .live)
    }

    func testSetDefaultProviderValidatesAndStores() async throws {
        let control = makeControl()
        try await control.setDefaultProvider("cloudflared")
        let stored = try await persistence.load().shareDefaultProvider
        XCTAssertEqual(stored, "cloudflared")
        do {
            try await control.setDefaultProvider("no-such-provider")
            XCTFail("expected providerNotFound")
        } catch ShareError.providerNotFound {
        }
        try await control.setDefaultProvider(nil)
        let cleared = try await persistence.load().shareDefaultProvider
        XCTAssertNil(cleared)
    }

    func testWaitReturnsLiveStatus() async throws {
        let site = try await seed("my-site")
        let control = makeControl()
        let id = site.id
        let requestID = try await control.request(instanceID: id, ShareRequest()).requestID
        let file = statusFile!
        let writer = Task {
            try await Task.sleep(for: .milliseconds(300))
            ProxyControl.writeShares([ShareStatus(instanceID: id, slug: "my-site", state: .live,
                                                  url: "https://my-site.example.com", provider: "ngrok",
                                                  requestID: requestID)], file: file)
        }
        let status = try await control.waitForStatus(instanceID: id, requestID: requestID, timeout: .seconds(5))
        XCTAssertEqual(status.state, .live)
        try await writer.value
    }

    func testWaitIgnoresStatusOfAnEarlierRequest() async throws {
        let site = try await seed("my-site")
        let control = makeControl()
        let id = site.id
        let requestID = try await control.request(instanceID: id, ShareRequest()).requestID
        ProxyControl.writeShares([ShareStatus(instanceID: id, slug: "my-site", state: .down, provider: "ngrok",
                                              error: "old", requestID: UUID())], file: statusFile)
        do {
            _ = try await control.waitForStatus(instanceID: id, requestID: requestID, timeout: .milliseconds(700))
            XCTFail("expected timedOut")
        } catch ShareError.timedOut {
        }
    }

    func testRerequestOnLiveShareReturnsPromptlyOnceRepublished() async throws {
        let site = try await seed("my-site")
        let control = makeControl()
        let first = try await control.request(instanceID: site.id, ShareRequest())
        ProxyControl.writeShares([ShareStatus(instanceID: site.id, slug: "my-site", state: .live, provider: "ngrok",
                                              requestID: first.requestID)], file: statusFile)
        let second = try await control.request(instanceID: site.id, ShareRequest(addAllow: ["/hook"]))
        let file = statusFile!
        let id = site.id
        let writer = Task {
            try await Task.sleep(for: .milliseconds(300))
            ProxyControl.writeShares([ShareStatus(instanceID: id, slug: "my-site", state: .live, provider: "ngrok",
                                                  requestID: second.requestID)], file: file)
        }
        let started = Date()
        let status = try await control.waitForStatus(instanceID: site.id, requestID: second.requestID, timeout: .seconds(5))
        XCTAssertEqual(status.requestID, second.requestID)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        try await writer.value
    }

    func testStatusOfStoppedShareDoesNotClash() async throws {
        let other = try await seed("other-site",
            share: ShareSettings(username: "share", password: "x", active: false))
        let site = try await seed("my-site", port: 8882)
        ProxyControl.writeShares([ShareStatus(instanceID: other.id, slug: "other-site", state: .live,
                                              provider: "ngrok", hostname: "free.example.com")], file: statusFile)
        let saved = try await makeControl().request(instanceID: site.id,
                                                    ShareRequest(hostname: .some("free.example.com")))
        XCTAssertEqual(saved.hostname, "free.example.com")
    }

    func testClashFromInheritedHostnameIsRefusedAndNothingWritten() async throws {
        _ = try await seed("other-site",
            share: ShareSettings(hostname: "share.example.com", username: "share", password: "x", active: true))
        let site = try await seed("my-site", port: 8882,
            share: ShareSettings(hostname: "share.example.com", username: "share", password: "y"))
        do {
            _ = try await makeControl().request(instanceID: site.id, ShareRequest())
            XCTFail("expected hostnameInUse")
        } catch ShareError.hostnameInUse {
        }
        let stored = try await persistence.load().sites.first { $0.id == site.id }?.share
        XCTAssertEqual(stored?.active, false)
    }

    func testWaitTimesOut() async throws {
        let site = try await seed("my-site")
        let control = makeControl()
        let requestID = try await control.request(instanceID: site.id, ShareRequest()).requestID
        do {
            _ = try await control.waitForStatus(instanceID: site.id, requestID: requestID, timeout: .milliseconds(600))
            XCTFail("expected timedOut")
        } catch ShareError.timedOut {
        }
    }

    func testWaitFailsFastWhenProxyDisappears() async throws {
        let control = makeControl(running: false)
        do {
            _ = try await control.waitForStatus(instanceID: UUID(), requestID: nil, timeout: .seconds(5))
            XCTFail("expected proxyNotRunning")
        } catch ShareError.proxyNotRunning {
        }
    }

    func testClearProviderRestoresTheStoreDefault() async throws {
        let site = try await seed("my-site")
        let control = makeControl()
        let pinned = try await control.request(instanceID: site.id, ShareRequest(provider: "cloudflared"))
        XCTAssertEqual(pinned.provider, "cloudflared")
        try await control.setDefaultProvider("ngrok")
        let cleared = try await control.request(instanceID: site.id, ShareRequest(clearProvider: true))
        XCTAssertNil(cleared.provider)
        let envelope = try await persistence.load()
        XCTAssertEqual(envelope.effectiveProvider(for: envelope.sites[0].share), "ngrok")
        try await control.setDefaultProvider("cloudflared")
        let followed = try await persistence.load()
        XCTAssertEqual(followed.effectiveProvider(for: followed.sites[0].share), "cloudflared")
    }

    func testClearProviderWinsOverProvider() async throws {
        let site = try await seed("my-site")
        let control = makeControl()
        _ = try await control.request(instanceID: site.id, ShareRequest(provider: "cloudflared"))
        let saved = try await control.request(instanceID: site.id,
                                              ShareRequest(provider: "ngrok", clearProvider: true))
        XCTAssertNil(saved.provider)
    }

    func testWaitThrowsCancelledWhenShareIsStopped() async throws {
        let site = try await seed("my-site")
        let control = makeControl()
        let settings = try await control.request(instanceID: site.id, ShareRequest())
        let stopper = Task {
            try await Task.sleep(for: .milliseconds(300))
            try await control.stop(instanceID: site.id)
        }
        do {
            _ = try await control.waitForStatus(instanceID: site.id, requestID: settings.requestID,
                                                timeout: .seconds(10))
            XCTFail("expected cancelled")
        } catch ShareError.cancelled {
        }
        try await stopper.value
    }

    func testRequestFailsFastWhenTheProxyCannotShare() async throws {
        let site = try await seed("my-site")
        let control = makeControl()
        try FileManager.default.removeItem(at: statusFile)
        do {
            _ = try await control.request(instanceID: site.id, ShareRequest())
            XCTFail("expected proxyTooOld")
        } catch ShareError.proxyTooOld {
        }
        let stored = try await persistence.load().sites[0].share
        XCTAssertNil(stored)
        XCTAssertTrue(ShareError.proxyTooOld.description.contains("doesn't support sharing"))
    }

    func testValidateChecksWithoutWriting() async throws {
        let site = try await seed("my-site")
        let control = makeControl()
        try await control.validate(instanceID: site.id, ShareRequest(provider: "cloudflared", addAllow: ["/hook"]))
        let stored = try await persistence.load().sites[0].share
        XCTAssertNil(stored)

        let invalid: [ShareRequest] = [
            ShareRequest(provider: "no-such-provider"),
            ShareRequest(hostname: .some("not a host")),
            ShareRequest(addAllow: ["hook"]),
        ]
        for request in invalid {
            do {
                try await control.validate(instanceID: site.id, request)
                XCTFail("expected a validation error")
            } catch is ShareError {
            }
        }
        let subdomain = try await seed("network", port: 8882, networkType: .subdomain)
        do {
            try await control.validate(instanceID: subdomain.id, ShareRequest())
            XCTFail("expected subdomainMultisite")
        } catch ShareError.subdomainMultisite {
        }
        do {
            try await makeControl(running: false).validate(instanceID: site.id, ShareRequest())
            XCTFail("expected proxyNotRunning")
        } catch ShareError.proxyNotRunning {
        }
    }

    func testListOmitsStatusesWhileNoProxyRuns() async throws {
        let site = try await seed("my-site")
        _ = try await makeControl().request(instanceID: site.id, ShareRequest())
        ProxyControl.writeShares([ShareStatus(instanceID: site.id, slug: "my-site", state: .live,
                                              provider: "ngrok")], file: statusFile)
        let rows = try await makeControl(running: false).list()
        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows[0].status)
    }

    func testListedState() {
        let live = ShareStatus(instanceID: UUID(), slug: "my-site", state: .live, provider: "ngrok")
        let down = ShareControl.listedState(active: true, status: nil, proxyRunning: false)
        XCTAssertEqual(down.state, "down")
        XCTAssertEqual(down.error, ShareControl.noProxyMessage)
        XCTAssertTrue(ShareControl.noProxyMessage.contains("No proxy host is running"))
        XCTAssertEqual(ShareControl.listedState(active: true, status: nil, proxyRunning: true).state, "starting")
        XCTAssertEqual(ShareControl.listedState(active: true, status: live, proxyRunning: true).state, "live")
        XCTAssertEqual(ShareControl.listedState(active: false, status: nil, proxyRunning: false).state, "inactive")
    }

    func testWaitReturnsADownPublishedBeforeTheShareWasCleared() async throws {
        let site = try await seed("my-site")
        let control = makeControl()
        let settings = try await control.request(instanceID: site.id, ShareRequest())
        ProxyControl.writeShares([ShareStatus(instanceID: site.id, slug: "my-site", state: .down, provider: "ngrok",
                                              error: "The site isn't running.", requestID: settings.requestID)],
                                 file: statusFile)
        try await control.stop(instanceID: site.id)

        let status = try await control.waitForStatus(instanceID: site.id, requestID: settings.requestID,
                                                     timeout: .seconds(2))
        XCTAssertEqual(status.state, .down)
        XCTAssertEqual(status.error, "The site isn't running.")
    }

    func testWaitThrowsInstanceNotFoundWhenTheInstanceIsDeleted() async throws {
        let site = try await seed("my-site")
        let control = makeControl()
        let settings = try await control.request(instanceID: site.id, ShareRequest())
        try await persistence.mutate { env in env.sites.removeAll() }
        do {
            _ = try await control.waitForStatus(instanceID: site.id, requestID: settings.requestID, timeout: .seconds(5))
            XCTFail("expected instanceNotFound")
        } catch ShareError.instanceNotFound(let id) {
            XCTAssertEqual(id, site.id)
        }
    }

    func testWaitThrowsCancelledWhenTheShareIsRemoved() async throws {
        let site = try await seed("my-site")
        let control = makeControl()
        let settings = try await control.request(instanceID: site.id, ShareRequest())
        try await persistence.mutate { env in env.sites[0].share = nil }
        do {
            _ = try await control.waitForStatus(instanceID: site.id, requestID: settings.requestID, timeout: .seconds(5))
            XCTFail("expected cancelled")
        } catch ShareError.cancelled {
        }
    }

    func testShareThatEndedDownDoesNotHoldItsHostname() async throws {
        let requestID = UUID()
        let other = try await seed("other-site", share: ShareSettings(hostname: "share.example.com", username: "share",
                                                                      password: "x", active: true, requestID: requestID))
        let site = try await seed("my-site", port: 8882)
        ProxyControl.writeShares([ShareStatus(instanceID: other.id, slug: "other-site", state: .down, provider: "ngrok",
                                              hostname: "share.example.com", error: "The share provider exited.",
                                              requestID: requestID)], file: statusFile)

        let saved = try await makeControl().request(instanceID: site.id, ShareRequest(hostname: .some("share.example.com")))

        XCTAssertEqual(saved.hostname, "share.example.com")
        XCTAssertTrue(saved.active)
    }

    func testEndedShareIsListedDownWithItsError() {
        let down = ShareStatus(instanceID: UUID(), slug: "my-site", state: .down, provider: "ngrok",
                               error: "The share provider exited.")
        let listed = ShareControl.listedState(active: false, status: down, proxyRunning: true)
        XCTAssertEqual(listed.state, "down")
        XCTAssertEqual(listed.error, "The share provider exited.")
        XCTAssertEqual(ShareControl.listedState(active: false, status: down, proxyRunning: false).state, "inactive")
    }

    func testStoreIsReadableOnlyByTheUser() async throws {
        let site = try await seed("my-site")
        _ = try await makeControl().request(instanceID: site.id, ShareRequest())
        let attributes = try FileManager.default.attributesOfItem(atPath: tempRoot.appendingPathComponent("sites.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    // MARK: - Helpers

    /// A running proxy host keeps its status file present, so one is created here.
    private func makeControl(running: Bool = true) -> ShareControl {
        if running && !FileManager.default.fileExists(atPath: statusFile.path) {
            ProxyControl.writeShares([], file: statusFile)
        }
        return ShareControl(persistence: persistence, statusFile: statusFile, proxyRunning: { running },
                            customDirectory: tempRoot.appendingPathComponent("share-providers"))
    }

    @discardableResult
    private func seed(_ slug: String, port: Int = 8881, networkType: NetworkType = .none,
                      share: ShareSettings? = nil) async throws -> Site {
        let site = Site(name: slug, slug: slug, path: tempRoot.appendingPathComponent(slug, isDirectory: true),
                        port: port, imageTag: SiteRecipe.defaultWordPressImage, networkType: networkType, share: share)
        try await persistence.mutate { env in env.sites.append(site) }
        return site
    }
}
