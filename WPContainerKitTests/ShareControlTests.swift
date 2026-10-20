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
        } catch let error as ShareError {
            XCTAssertTrue(error.description.contains("wp-container proxy serve"))
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
        let other = try await seed("other-site")
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
        let id = UUID()
        let control = makeControl()
        let file = statusFile!
        let writer = Task {
            try await Task.sleep(for: .milliseconds(300))
            ProxyControl.writeShares([ShareStatus(instanceID: id, slug: "my-site", state: .live,
                                                  url: "https://my-site.example.com", provider: "ngrok")], file: file)
        }
        let status = try await control.waitForStatus(instanceID: id, timeout: .seconds(5))
        XCTAssertEqual(status.state, .live)
        try await writer.value
    }

    func testWaitIgnoresStatusFromBeforeTheRequest() async throws {
        let id = UUID()
        let control = makeControl()
        let old = ShareStatus(instanceID: id, slug: "my-site", state: .down, provider: "ngrok",
                              error: "old", updatedAt: Date().addingTimeInterval(-30))
        ProxyControl.writeShares([old], file: statusFile)
        do {
            _ = try await control.waitForStatus(instanceID: id, timeout: .milliseconds(700))
            XCTFail("expected timedOut")
        } catch ShareError.timedOut {
        }
    }

    func testWaitTimesOut() async throws {
        do {
            _ = try await makeControl().waitForStatus(instanceID: UUID(), timeout: .milliseconds(600))
            XCTFail("expected timedOut")
        } catch ShareError.timedOut {
        }
    }

    func testWaitFailsFastWhenProxyDisappears() async throws {
        let control = makeControl(running: false)
        do {
            _ = try await control.waitForStatus(instanceID: UUID(), timeout: .seconds(5))
            XCTFail("expected proxyNotRunning")
        } catch ShareError.proxyNotRunning {
        }
    }

    // MARK: - Helpers

    private func makeControl(running: Bool = true) -> ShareControl {
        ShareControl(persistence: persistence, statusFile: statusFile, proxyRunning: { running })
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
