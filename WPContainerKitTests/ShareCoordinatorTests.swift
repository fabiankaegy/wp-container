import Darwin
import XCTest
@testable import WPContainerKit

/// The coordinator against a fake listener host, a fake launcher, fake providers,
/// a temporary store, and temporary status, pid and tunnel registry files.
final class ShareCoordinatorTests: XCTestCase {

    private var tempRoot: URL!
    private var persistence: StorePersistence!
    private var host: FakeShareListenerHost!
    private var launcher: FakeShareLauncher!
    private var statusFile: URL!
    private var pidsFile: URL!
    private var registryFile: URL!
    private var cloudflaredLog: URL!
    private var cloudflared: URL!
    private var spawned: [Process] = []
    private var spawnedPIDs: [Int32] = []

    override func setUp() async throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShareCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        persistence = StorePersistence(fileURL: tempRoot.appendingPathComponent("sites.json"))
        host = FakeShareListenerHost()
        launcher = FakeShareLauncher()
        statusFile = tempRoot.appendingPathComponent("proxy-shares.json")
        pidsFile = tempRoot.appendingPathComponent("share-pids.json")
        registryFile = tempRoot.appendingPathComponent("share-cloudflare.json")
        cloudflaredLog = tempRoot.appendingPathComponent("cloudflared.log")
        cloudflared = tempRoot.appendingPathComponent("cloudflared")
        let script = """
        #!/bin/sh
        echo "$*" >> '\(cloudflaredLog.path)'
        exit 0
        """
        try script.write(to: cloudflared, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cloudflared.path)
    }

    override func tearDown() async throws {
        for process in spawned where process.isRunning { process.terminate() }
        for pid in spawnedPIDs { kill(pid, SIGKILL) }
        try? FileManager.default.removeItem(at: tempRoot)
    }

    // MARK: - Tests

    func testActiveShareOpensListenerStartsProviderAndPublishesLive() async throws {
        let site = makeSite("my-site", share: activeShare(provider: "fixture"))
        try await save([site])
        let coordinator = makeCoordinator()

        try await reconcile(coordinator, running: ["my-site"])

        let status = try XCTUnwrap(statuses().first)
        XCTAssertEqual(statuses().count, 1)
        XCTAssertEqual(status.state, .live)
        XCTAssertEqual(status.url, "https://my-site.example.com")
        XCTAssertEqual(status.provider, "fixture")
        XCTAssertEqual(status.slug, "my-site")
        XCTAssertEqual(status.hostname, "my-site.example.com")
        XCTAssertFalse(status.temporary)
        let port = try XCTUnwrap(host.port(of: site.id))
        XCTAssertEqual(status.listenerPort, port)
        XCTAssertEqual(status.pid, launcher.handles.first?.pid)

        let config = try XCTUnwrap(host.config(of: site.id))
        XCTAssertEqual(config.publicOrigin, "https://my-site.example.com")
        XCTAssertEqual(config.upstreamHost, site.shareUpstreamHost)
        XCTAssertEqual(config.localOrigins, site.shareLocalOrigins)
        XCTAssertEqual(config.username, "share")
        XCTAssertEqual(config.password, "secret-one")
        XCTAssertEqual(launcher.launches.first?.upstream, "http://127.0.0.1:\(port)")

        let originFile = site.phpConfFolder.appendingPathComponent(SharePHPService.originFileName)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: originFile)) as? [String: Any])
        XCTAssertEqual(json["origin"] as? String, "https://my-site.example.com")
        XCTAssertEqual(pidRecords().map(\.pid), [launcher.handles[0].pid])
    }

    func testStoppedInstanceClearsDesiredShareAndStopsProvider() async throws {
        var share = activeShare(provider: "fixture")
        share.authDisabled = true
        let site = makeSite("my-site", share: share)
        try await save([site])
        let coordinator = makeCoordinator()
        try await reconcile(coordinator, running: ["my-site"])
        XCTAssertEqual(statuses().first?.state, .live)

        try await reconcile(coordinator, running: [])
        XCTAssertFalse(launcher.handles[0].terminated)
        XCTAssertEqual(statuses().first?.state, .live)
        try await reconcile(coordinator, running: [])

        XCTAssertTrue(launcher.handles[0].terminated)
        XCTAssertTrue(host.closed.contains(site.id))
        let stored = try await persistence.load().sites.first?.share
        XCTAssertEqual(stored?.active, false)
        XCTAssertEqual(stored?.authDisabled, false)
        XCTAssertEqual(stored?.password, "secret-one")
        XCTAssertEqual(statuses(), [])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: site.phpConfFolder.appendingPathComponent(SharePHPService.originFileName).path))
        XCTAssertEqual(pidRecords(), [])
    }

    func testStoppedInstanceKeepsAShareRequestedMeanwhile() async throws {
        let site = makeSite("my-site", share: activeShare(provider: "fixture"))
        try await save([site])
        let coordinator = makeCoordinator()
        let decided = try await persistence.load()

        let request = UUID()
        try await setShare(site.id) { $0.requestID = request }
        await coordinator.reconcile(envelope: decided, routes: HTTPSProxy.routes(from: decided), running: [])
        await coordinator.waitUntilIdle()

        let stored = try await persistence.load().sites.first?.share
        XCTAssertEqual(stored?.active, true)
        XCTAssertEqual(stored?.requestID, request)
    }

    func testInactiveShareTearsDown() async throws {
        var share = activeShare(provider: "fixture")
        share.allow = [try ShareException(parsing: "/wp-json/example/webhook")]
        let site = makeSite("my-site", share: share)
        try await save([site])
        let coordinator = makeCoordinator()
        try await reconcile(coordinator, running: ["my-site"])

        try await setShare(site.id) { $0.active = false }
        try await reconcile(coordinator, running: ["my-site"])

        XCTAssertTrue(launcher.handles[0].terminated)
        XCTAssertTrue(host.closed.contains(site.id))
        XCTAssertEqual(statuses(), [])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: site.phpConfFolder.appendingPathComponent(SharePHPService.originFileName).path))
        let stored = try await persistence.load().sites.first?.share
        XCTAssertEqual(stored?.active, false)
        XCTAssertEqual(stored?.password, "secret-one")
        XCTAssertEqual(stored?.allow.map(\.description), ["/wp-json/example/webhook"])
    }

    func testProviderExitMarksDownWithoutRestart() async throws {
        let request = UUID()
        var share = activeShare(provider: "fixture")
        share.authDisabled = true
        share.requestID = request
        let site = makeSite("my-site", share: share)
        try await save([site])
        let coordinator = makeCoordinator()
        try await reconcile(coordinator, running: ["my-site"])

        launcher.handles[0].exit(status: 1, stderrTail: ["err"])
        let down = try await waitForStatus { $0.first?.state == .down }

        XCTAssertTrue(try XCTUnwrap(down.first?.error).contains("err"))
        XCTAssertEqual(down.first?.requestID, request)
        XCTAssertTrue(host.closed.contains(site.id))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: site.phpConfFolder.appendingPathComponent(SharePHPService.originFileName).path))
        let stored = try await waitForStoredShare(site.id) { !$0.active }
        XCTAssertFalse(stored.authDisabled)
        XCTAssertEqual(stored.requestID, request)

        try await setShare(site.id) { $0.allow = [try! ShareException(parsing: "?example-callback=1")] }
        try await reconcile(coordinator, running: ["my-site"])
        try await reconcile(coordinator, running: ["my-site"])
        XCTAssertEqual(launcher.launches.count, 1)
        XCTAssertEqual(statuses().first?.state, .down)
        XCTAssertEqual(statuses().first?.requestID, request)

        try await setShare(site.id) {
            $0.active = true
            $0.requestID = UUID()
        }
        try await reconcile(coordinator, running: ["my-site"])
        XCTAssertEqual(launcher.launches.count, 2)
        XCTAssertEqual(statuses().first?.state, .live)
    }

    func testProviderExitIsNotReopenedByTheNextHost() async throws {
        var share = activeShare(provider: "fixture")
        share.authDisabled = true
        let site = makeSite("my-site", share: share)
        try await save([site])
        let first = makeCoordinator()
        try await reconcile(first, running: ["my-site"])
        launcher.handles[0].exit(status: 1, stderrTail: ["err"])
        _ = try await waitForStoredShare(site.id) { !$0.active }

        launcher = FakeShareLauncher()
        try await reconcile(makeCoordinator(), running: ["my-site"])

        XCTAssertEqual(launcher.launches.count, 0)
        let stored = try await persistence.load().sites.first?.share
        XCTAssertEqual(stored?.active, false)
        XCTAssertEqual(stored?.authDisabled, false)
    }

    func testFailedStartEndsTheShareAndIsNotReopenedByTheNextHost() async throws {
        let request = UUID()
        var share = activeShare(provider: "broken")
        share.authDisabled = true
        share.requestID = request
        let site = makeSite("my-site", share: share)
        try await save([site])
        let coordinator = makeCoordinator()

        try await reconcile(coordinator, running: ["my-site"])

        let stored = try await persistence.load().sites.first?.share
        XCTAssertEqual(stored?.active, false)
        XCTAssertEqual(stored?.authDisabled, false)
        try await reconcile(coordinator, running: ["my-site"])
        XCTAssertEqual(statuses().first?.state, .down)
        XCTAssertEqual(statuses().first?.requestID, request)

        try await setShare(site.id) { $0.provider = "fixture" }
        try await reconcile(makeCoordinator(), running: ["my-site"])
        XCTAssertEqual(launcher.launches.count, 0)
    }

    func testClashLoserEndsAndDoesNotWinTheHostnameOnTheNextHost() async throws {
        let request = UUID()
        var loserShare = activeShare(provider: "fixture", hostname: "share.example.com")
        loserShare.authDisabled = true
        loserShare.requestID = request
        let first = makeSite("site-one", port: 8881, share: activeShare(provider: "fixture", hostname: "share.example.com"))
        let second = makeSite("site-two", port: 8882, share: loserShare)
        launcher.urls = ["site-one": "https://share.example.com", "site-two": "https://share.example.com"]
        try await save([first, second])
        let coordinator = makeCoordinator()
        try await reconcile(coordinator, running: ["site-one", "site-two"])

        let loser = try XCTUnwrap(statuses().first { $0.slug == "site-two" })
        XCTAssertEqual(loser.state, .down)
        XCTAssertEqual(loser.requestID, request)
        let stored = try await persistence.load().sites.first { $0.id == second.id }?.share
        XCTAssertEqual(stored?.active, false)
        XCTAssertEqual(stored?.authDisabled, false)

        try await setShare(first.id) { $0.active = false }
        launcher = FakeShareLauncher()
        launcher.urls = ["site-one": "https://share.example.com", "site-two": "https://share.example.com"]
        try await reconcile(makeCoordinator(), running: ["site-one", "site-two"])
        XCTAssertEqual(launcher.launches.count, 0)
    }

    func testActiveShareWithoutAProxyRouteIsReportedDown() async throws {
        let request = UUID()
        var share = activeShare(provider: "fixture")
        share.requestID = request
        let site = makeSite("my-site", share: share)
        try await save([site])
        let coordinator = makeCoordinator()

        let envelope = try await persistence.load()
        await coordinator.reconcile(envelope: envelope, routes: [:], running: ["my-site"])
        await coordinator.waitUntilIdle()

        let status = try XCTUnwrap(statuses().first)
        XCTAssertEqual(status.state, .down)
        XCTAssertEqual(status.error, "The proxy has no route for this site yet.")
        XCTAssertEqual(status.requestID, request)
        XCTAssertEqual(launcher.launches.count, 0)
        let stored = try await persistence.load().sites.first?.share
        XCTAssertEqual(stored?.active, false)
    }

    func testFixedHostnameClashIsRefused() async throws {
        let first = makeSite("site-one", port: 8881, share: activeShare(provider: "fixture", hostname: "share.example.com"))
        let second = makeSite("site-two", port: 8882, share: activeShare(provider: "fixture", hostname: "share.example.com"))
        launcher.urls = ["site-one": "https://share.example.com", "site-two": "https://share.example.com"]
        try await save([first, second])
        let coordinator = makeCoordinator()

        try await reconcile(coordinator, running: ["site-one", "site-two"])

        let one = try XCTUnwrap(statuses().first { $0.slug == "site-one" })
        let two = try XCTUnwrap(statuses().first { $0.slug == "site-two" })
        XCTAssertEqual(one.state, .live)
        XCTAssertEqual(two.state, .down)
        let error = try XCTUnwrap(two.error)
        XCTAssertTrue(error.contains("site-one"), error)
        XCTAssertTrue(error.contains("wp-container share stop site-one"), error)
        XCTAssertEqual(launcher.launches.map(\.slug), ["site-one"])
        XCTAssertNil(host.port(of: second.id))
    }

    func testRerequestedShareRetriesAfterAClash() async throws {
        let first = makeSite("site-one", port: 8881, share: activeShare(provider: "fixture", hostname: "share.example.com"))
        let second = makeSite("site-two", port: 8882, share: activeShare(provider: "fixture", hostname: "share.example.com"))
        launcher.urls = ["site-one": "https://share.example.com", "site-two": "https://share.example.com"]
        try await save([first, second])
        let coordinator = makeCoordinator()
        try await reconcile(coordinator, running: ["site-one", "site-two"])
        XCTAssertEqual(statuses().first { $0.slug == "site-two" }?.state, .down)

        try await setShare(first.id) { $0.active = false }
        try await reconcile(coordinator, running: ["site-one", "site-two"])
        XCTAssertEqual(statuses().first { $0.slug == "site-two" }?.state, .down)

        try await setShare(second.id) {
            $0.active = true
            $0.requestID = UUID()
        }
        try await reconcile(coordinator, running: ["site-one", "site-two"])

        XCTAssertEqual(statuses().first { $0.slug == "site-two" }?.state, .live)
        XCTAssertEqual(launcher.launches.map(\.slug), ["site-one", "site-two"])
    }

    func testNgrokAssignedDomainCountsForClash() async throws {
        let first = makeSite("site-one", port: 8881, share: activeShare(provider: "ngrok"))
        let second = makeSite("site-two", port: 8882, share: inactiveShare(provider: "ngrok", hostname: nil))
        launcher.urls = ["site-one": "https://abc.ngrok-free.app", "site-two": "https://abc.ngrok-free.app"]
        try await save([first, second])
        let coordinator = makeCoordinator()

        try await reconcile(coordinator, running: ["site-one"])
        let one = try XCTUnwrap(statuses().first)
        XCTAssertEqual(one.state, .live)
        XCTAssertEqual(one.hostname, "abc.ngrok-free.app")
        XCTAssertFalse(one.temporary)

        try await setShare(second.id) { $0.active = true }
        try await reconcile(coordinator, running: ["site-one", "site-two"])

        let two = try XCTUnwrap(statuses().first { $0.slug == "site-two" })
        XCTAssertEqual(two.state, .down)
        let error = try XCTUnwrap(two.error)
        XCTAssertTrue(error.contains("wp-container share stop site-one"), error)
        XCTAssertTrue(error.contains("cloudflared"), error)
        XCTAssertTrue(launcher.handles[1].terminated)
        XCTAssertFalse(launcher.handles[0].terminated)
        XCTAssertTrue(host.closed.contains(second.id))
        XCTAssertEqual(statuses().first { $0.slug == "site-one" }?.state, .live)
    }

    func testQuickTunnelIsTemporary() async throws {
        let site = makeSite("my-site", share: activeShare(provider: "cloudflared"))
        launcher.urls = ["my-site": "https://random-words.trycloudflare.com"]
        try await save([site])
        let coordinator = makeCoordinator()

        try await reconcile(coordinator, running: ["my-site"])

        let status = try XCTUnwrap(statuses().first)
        XCTAssertEqual(status.state, .live)
        XCTAssertTrue(status.temporary)
        XCTAssertEqual(launcher.launches.first?.tunnelName, "")
    }

    func testFixedCloudflaredHostnameEnsuresTheNamedTunnel() async throws {
        let site = makeSite("my-site", share: activeShare(provider: "cloudflared", hostname: "share.example.com"))
        launcher.urls = ["my-site": "https://share.example.com"]
        try await save([site])
        let coordinator = makeCoordinator()

        try await reconcile(coordinator, running: ["my-site"])

        XCTAssertEqual(statuses().first?.state, .live)
        XCTAssertFalse(try XCTUnwrap(statuses().first).temporary)
        XCTAssertEqual(launcher.launches.first?.tunnelName, "wpc-my-site")
        XCTAssertEqual(cloudflaredCalls(), ["tunnel create wpc-my-site", "tunnel route dns wpc-my-site share.example.com"])
        XCTAssertEqual(registry(), [CloudflareTunnelRecord(instanceID: site.id, tunnelName: "wpc-my-site",
                                                           hostname: "share.example.com")])
    }

    func testChangedCloudflaredHostnameReplacesTheTunnelBeforeRestarting() async throws {
        let site = makeSite("my-site", share: activeShare(provider: "cloudflared", hostname: "a.example.com"))
        launcher.urls = ["my-site": "https://a.example.com"]
        try await save([site])
        let coordinator = makeCoordinator()
        try await reconcile(coordinator, running: ["my-site"])

        launcher.urls = ["my-site": "https://b.example.com"]
        try await setShare(site.id) { $0.hostname = "b.example.com" }
        try await reconcile(coordinator, running: ["my-site"])

        XCTAssertEqual(statuses().first?.state, .live)
        XCTAssertEqual(statuses().first?.url, "https://b.example.com")
        XCTAssertEqual(Array(cloudflaredCalls().dropFirst(2)), [
            "tunnel delete -f wpc-my-site",
            "tunnel create wpc-my-site",
            "tunnel route dns wpc-my-site b.example.com",
        ])
        XCTAssertEqual(registry(), [CloudflareTunnelRecord(instanceID: site.id, tunnelName: "wpc-my-site",
                                                           hostname: "b.example.com")])
        XCTAssertTrue(try XCTUnwrap(statuses().first?.error).contains("a.example.com"))
    }

    func testClearedHostnameWhileLiveCleansUpTheTunnelOnTheNextTick() async throws {
        let site = makeSite("my-site", share: activeShare(provider: "cloudflared", hostname: "a.example.com"))
        launcher.urls = ["my-site": "https://a.example.com"]
        try await save([site])
        let coordinator = makeCoordinator()
        try await reconcile(coordinator, running: ["my-site"])

        launcher.urls = ["my-site": "https://random-words.trycloudflare.com"]
        try await setShare(site.id) { $0.hostname = nil }
        try await reconcile(coordinator, running: ["my-site"])
        XCTAssertEqual(statuses().first?.url, "https://random-words.trycloudflare.com")
        try await reconcile(coordinator, running: ["my-site"])

        XCTAssertEqual(cloudflaredCalls().last, "tunnel delete -f wpc-my-site")
        XCTAssertEqual(registry(), [])
    }

    func testDeletedInstanceWithALiveTunnelIsCleanedAfterItsProviderStops() async throws {
        let site = makeSite("my-site", share: activeShare(provider: "cloudflared", hostname: "a.example.com"))
        launcher.urls = ["my-site": "https://a.example.com"]
        try await save([site])
        let coordinator = makeCoordinator()
        try await reconcile(coordinator, running: ["my-site"])

        try await save([])
        try await reconcile(coordinator, running: ["my-site"])
        XCTAssertTrue(launcher.handles[0].terminated)
        XCTAssertFalse(cloudflaredCalls().contains("tunnel delete -f wpc-my-site"))

        try await reconcile(coordinator, running: ["my-site"])
        XCTAssertEqual(cloudflaredCalls().last, "tunnel delete -f wpc-my-site")
        XCTAssertEqual(registry(), [])
    }

    func testStoppingShareHoldsItsHostnameUntilReleased() async throws {
        let first = makeSite("site-one", port: 8881, share: activeShare(provider: "fixture", hostname: "share.example.com"))
        let second = makeSite("site-two", port: 8882, share: inactiveShare(provider: "fixture", hostname: "share.example.com"))
        launcher.urls = ["site-one": "https://share.example.com", "site-two": "https://share.example.com"]
        launcher.held = ["site-one"]
        try await save([first, second])
        let coordinator = makeCoordinator()
        let envelope = try await persistence.load()
        await coordinator.reconcile(envelope: envelope, routes: HTTPSProxy.routes(from: envelope), running: ["site-one", "site-two"])
        try await waitUntil { self.launcher.launches.count == 1 }

        try await setShare(first.id) { $0.active = false }
        try await setShare(second.id) { $0.active = true }
        try await reconcile(coordinator, running: ["site-one", "site-two"])
        XCTAssertEqual(launcher.launches.map(\.slug), ["site-one"])
        XCTAssertEqual(statuses(), [])

        try await reconcile(coordinator, running: ["site-one", "site-two"])
        XCTAssertEqual(statuses().first { $0.slug == "site-two" }?.state, .live)
    }

    func testSubdomainRefusalWaitsForAStartingShareToRelease() async throws {
        let site = makeSite("my-site", share: activeShare(provider: "fixture"))
        launcher.held = ["my-site"]
        try await save([site])
        let coordinator = makeCoordinator()
        let envelope = try await persistence.load()
        await coordinator.reconcile(envelope: envelope, routes: HTTPSProxy.routes(from: envelope), running: ["my-site"])
        try await waitUntil { self.launcher.launches.count == 1 }

        try await persistence.mutate { $0.sites[0].networkType = .subdomain }
        try await reconcile(coordinator, running: ["my-site"])
        XCTAssertTrue(host.closed.contains(site.id))
        let pending = try await persistence.load().sites.first?.share
        XCTAssertEqual(pending?.active, true)

        try await reconcile(coordinator, running: ["my-site"])
        XCTAssertEqual(statuses().first?.state, .down)
        let stored = try await persistence.load().sites.first?.share
        XCTAssertEqual(stored?.active, false)
    }

    func testInstanceChangeWhileStartingReachesThePHPOriginFile() async throws {
        let site = makeSite("my-site", share: activeShare(provider: "fixture"))
        launcher.held = ["my-site"]
        try await save([site])
        let coordinator = makeCoordinator()
        var envelope = try await persistence.load()
        await coordinator.reconcile(envelope: envelope, routes: HTTPSProxy.routes(from: envelope), running: ["my-site"])
        try await waitUntil { self.launcher.launches.count == 1 }

        try await persistence.mutate { $0.sites[0].customDomain = "my-site.example.test" }
        envelope = try await persistence.load()
        await coordinator.reconcile(envelope: envelope, routes: HTTPSProxy.routes(from: envelope), running: ["my-site"])
        launcher.held = []
        await coordinator.waitUntilIdle()

        XCTAssertEqual(statuses().first?.state, .live)
        let originFile = site.phpConfFolder.appendingPathComponent(SharePHPService.originFileName)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: originFile)) as? [String: Any])
        XCTAssertTrue(try XCTUnwrap(json["locals"] as? [String]).contains("http://my-site.example.test"))
        XCTAssertTrue(try XCTUnwrap(host.config(of: site.id)).localOrigins.contains("http://my-site.example.test"))
    }

    func testRestartReopensRunningShares() async throws {
        let site = makeSite("my-site", share: activeShare(provider: "fixture"))
        try await save([site])
        let first = makeCoordinator()
        try await reconcile(first, running: ["my-site"])
        XCTAssertEqual(statuses().first?.state, .live)

        host = FakeShareListenerHost()
        launcher = FakeShareLauncher()
        let second = makeCoordinator()
        try await reconcile(second, running: ["my-site"])

        XCTAssertEqual(statuses().first?.state, .live)
        XCTAssertEqual(launcher.launches.count, 1)
        let config = try XCTUnwrap(host.config(of: site.id))
        XCTAssertEqual(config.username, "share")
        XCTAssertEqual(config.password, "secret-one")
    }

    func testReapOrphansKillsRecordedProviderPids() async throws {
        let orphan = try spawnSleep()
        let bystander = try spawnSleep()
        let orphanPath = try XCTUnwrap(ShareCoordinator.executablePath(of: orphan.processIdentifier))
        let records = [
            SharePIDRecord(pid: orphan.processIdentifier, executable: orphanPath,
                           startTime: ShareCoordinator.startTime(of: orphan.processIdentifier), instanceID: UUID()),
            SharePIDRecord(pid: bystander.processIdentifier, executable: "/usr/bin/true",
                           startTime: ShareCoordinator.startTime(of: bystander.processIdentifier), instanceID: UUID()),
        ]
        try JSONEncoder().encode(records).write(to: pidsFile)

        await makeCoordinator().reapOrphans()

        let deadline = Date().addingTimeInterval(5)
        while orphan.isRunning && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertFalse(orphan.isRunning)
        XCTAssertTrue(bystander.isRunning)
        XCTAssertEqual(pidRecords(), [])
    }

    func testReapOrphansLeavesAProcessWhoseStartTimeDiffers() async throws {
        let process = try spawnSleep()
        let path = try XCTUnwrap(ShareCoordinator.executablePath(of: process.processIdentifier))
        let start = try XCTUnwrap(ShareCoordinator.startTime(of: process.processIdentifier))
        let reused = ProcessStartTime(seconds: start.seconds - 60, microseconds: start.microseconds)
        let records = [SharePIDRecord(pid: process.processIdentifier, executable: path, startTime: reused, instanceID: UUID())]
        try JSONEncoder().encode(records).write(to: pidsFile)

        await makeCoordinator().reapOrphans()

        XCTAssertTrue(process.isRunning)
        XCTAssertEqual(pidRecords(), [])
    }

    func testReapOrphansStopsTheProcessesAnOrphanStarted() async throws {
        let provider = try spawn("/bin/sh", ["-c", "sleep 30; echo done"])
        try await waitUntil { !ProcessIdentity.descendants(of: provider.processIdentifier).isEmpty }
        let child = try XCTUnwrap(ProcessIdentity.descendants(of: provider.processIdentifier).first)
        spawnedPIDs.append(child.pid)
        let path = try XCTUnwrap(ShareCoordinator.executablePath(of: provider.processIdentifier))
        let records = [SharePIDRecord(pid: provider.processIdentifier, executable: path,
                                      startTime: ShareCoordinator.startTime(of: provider.processIdentifier),
                                      instanceID: UUID())]
        try JSONEncoder().encode(records).write(to: pidsFile)

        await makeCoordinator().reapOrphans()

        try await waitUntil { !provider.isRunning && !child.isAlive }
    }

    func testReapOrphansStopsALegacyRecordOnlyWhenLaunchdAdoptedIt() async throws {
        let adopted = try spawnAdoptedSleep()
        let child = try spawnSleep()
        let path = try XCTUnwrap(ShareCoordinator.executablePath(of: child.processIdentifier))
        XCTAssertEqual(ShareCoordinator.parentPID(of: adopted.pid), 1)
        let records = [
            SharePIDRecord(pid: adopted.pid, executable: path, startTime: nil, instanceID: UUID()),
            SharePIDRecord(pid: child.processIdentifier, executable: path, startTime: nil, instanceID: UUID()),
        ]
        try JSONEncoder().encode(records).write(to: pidsFile)

        await makeCoordinator().reapOrphans()

        try await waitUntil { !adopted.isAlive }
        XCTAssertTrue(child.isRunning)
        XCTAssertEqual(pidRecords(), [])
    }

    func testReapOrphansLeavesALegacyRecordWithAnotherExecutable() async throws {
        let adopted = try spawnAdoptedSleep()
        let records = [SharePIDRecord(pid: adopted.pid, executable: "/usr/bin/true", startTime: nil, instanceID: UUID())]
        try JSONEncoder().encode(records).write(to: pidsFile)

        await makeCoordinator().reapOrphans()

        XCTAssertTrue(adopted.isAlive)
    }

    func testReapOrphansReplacesStatusesLeftByACrashedHost() async throws {
        let stale = ShareStatus(instanceID: UUID(), slug: "my-site", state: .live, url: "https://my-site.example.com",
                                provider: "fixture")
        ProxyControl.writeShares([stale], file: statusFile)

        await makeCoordinator().reapOrphans()

        XCTAssertTrue(FileManager.default.fileExists(atPath: statusFile.path))
        XCTAssertEqual(statuses(), [])
    }

    func testReapPublishesAnEmptyStatusFileEveryTime() async throws {
        let coordinator = makeCoordinator()
        await coordinator.reapOrphans()
        XCTAssertEqual(try String(contentsOf: statusFile, encoding: .utf8), "[]")

        await coordinator.stopAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: statusFile.path))
        await coordinator.reapOrphans()
        XCTAssertTrue(FileManager.default.fileExists(atPath: statusFile.path))
    }

    func testReconcileRestoresAMissingStatusFile() async throws {
        try await save([makeSite("my-site", share: nil)])
        let coordinator = makeCoordinator()
        await coordinator.reapOrphans()
        try FileManager.default.removeItem(at: statusFile)

        try await reconcile(coordinator, running: [])

        XCTAssertTrue(FileManager.default.fileExists(atPath: statusFile.path))
    }

    func testShareRequestedOnAStoppedInstanceIsReportedDown() async throws {
        let request = UUID()
        var share = activeShare(provider: "fixture")
        share.requestID = request
        let site = makeSite("my-site", share: share)
        try await save([site])
        let coordinator = makeCoordinator()

        try await reconcile(coordinator, running: [])

        let status = try XCTUnwrap(statuses().first)
        XCTAssertEqual(status.state, .down)
        XCTAssertEqual(status.requestID, request)
        XCTAssertEqual(status.error, "The site isn't running.")
        XCTAssertEqual(launcher.launches.count, 0)
        let stored = try await persistence.load().sites.first?.share
        XCTAssertEqual(stored?.active, false)

        let control = ShareControl(persistence: persistence, statusFile: statusFile, proxyRunning: { true })
        let answered = try await control.waitForStatus(instanceID: site.id, requestID: request, timeout: .seconds(2))
        XCTAssertEqual(answered.state, .down)
    }

    func testSubdomainMultisiteIsRefused() async throws {
        var share = activeShare(provider: "fixture")
        share.authDisabled = true
        let site = makeSite("my-site", share: share, networkType: .subdomain)
        try await save([site])
        let coordinator = makeCoordinator()

        try await reconcile(coordinator, running: ["my-site"])

        let status = try XCTUnwrap(statuses().first)
        XCTAssertEqual(status.state, .down)
        XCTAssertTrue(try XCTUnwrap(status.error).contains("subdomain"))
        let stored = try await persistence.load().sites.first?.share
        XCTAssertEqual(stored?.active, false)
        XCTAssertEqual(stored?.authDisabled, false)
        XCTAssertEqual(launcher.launches.count, 0)
        XCTAssertNil(host.port(of: site.id))

        try await reconcile(coordinator, running: ["my-site"])
        XCTAssertEqual(statuses().first?.state, .down)
    }

    func testScriptReportingWrongHostnameIsRejected() async throws {
        let site = makeSite("my-site", share: activeShare(provider: "fixture", hostname: "a.example.com"))
        launcher.urls = ["my-site": "https://b.example.com"]
        try await save([site])
        let coordinator = makeCoordinator()

        try await reconcile(coordinator, running: ["my-site"])

        let status = try XCTUnwrap(statuses().first)
        XCTAssertEqual(status.state, .down)
        XCTAssertEqual(status.error, ShareError.hostnameMismatch(expected: "a.example.com", got: "b.example.com").description)
        XCTAssertTrue(launcher.handles[0].terminated)
        XCTAssertTrue(host.closed.contains(site.id))
        XCTAssertEqual(pidRecords(), [])
    }

    func testDeletedInstanceCleansUpItsCloudflareTunnel() async throws {
        let gone = CloudflareTunnelRecord(instanceID: UUID(), tunnelName: "wpc-gone", hostname: "gone.example.com")
        try JSONEncoder().encode([gone]).write(to: registryFile)
        try await save([makeSite("my-site", share: nil)])
        let coordinator = makeCoordinator()

        try await reconcile(coordinator, running: ["my-site"])
        try await reconcile(coordinator, running: ["my-site"])

        XCTAssertEqual(cloudflaredCalls(), ["tunnel delete -f wpc-gone"])
        XCTAssertEqual(registry(), [])
    }

    func testClearedHostnameCleansUpTunnel() async throws {
        let cleared = makeSite("site-one", port: 8881, share: inactiveShare(provider: "cloudflared", hostname: nil))
        let changed = makeSite("site-two", port: 8882, share: inactiveShare(provider: "cloudflared", hostname: "new.example.com"))
        let kept = makeSite("site-three", port: 8883, share: inactiveShare(provider: "cloudflared", hostname: "kept.example.com"))
        let records = [
            CloudflareTunnelRecord(instanceID: cleared.id, tunnelName: "wpc-site-one", hostname: "one.example.com"),
            CloudflareTunnelRecord(instanceID: changed.id, tunnelName: "wpc-site-two", hostname: "old.example.com"),
            CloudflareTunnelRecord(instanceID: kept.id, tunnelName: "wpc-site-three", hostname: "kept.example.com"),
        ]
        try JSONEncoder().encode(records).write(to: registryFile)
        try await save([cleared, changed, kept])
        let coordinator = makeCoordinator()

        try await reconcile(coordinator, running: [])

        XCTAssertEqual(Set(cloudflaredCalls()), ["tunnel delete -f wpc-site-one", "tunnel delete -f wpc-site-two"])
        XCTAssertEqual(registry(), [records[2]])
    }

    func testProviderChangeKeepsTheTunnel() async throws {
        // site-two follows the store default, ngrok.
        let envelope = StoreEnvelope(sites: [
            makeSite("site-one", port: 8881, share: inactiveShare(provider: "ngrok", hostname: "one.example.com")),
            makeSite("site-two", port: 8882, share: inactiveShare(provider: nil, hostname: "two.example.com")),
        ])
        let records = [
            CloudflareTunnelRecord(instanceID: envelope.sites[0].id, tunnelName: "wpc-site-one", hostname: "one.example.com"),
            CloudflareTunnelRecord(instanceID: envelope.sites[1].id, tunnelName: "wpc-site-two", hostname: "two.example.com"),
        ]
        try JSONEncoder().encode(records).write(to: registryFile)
        try await persistence.save(envelope)
        let coordinator = makeCoordinator()

        try await reconcile(coordinator, running: [])
        try await reconcile(coordinator, running: [])

        XCTAssertEqual(cloudflaredCalls(), [])
        XCTAssertEqual(registry(), records)
    }

    func testReturningToAnEarlierHostnameOverwritesItsOwnDNSRecord() async throws {
        let site = makeSite("my-site", share: activeShare(provider: "cloudflared", hostname: "a.example.com"))
        launcher.urls = ["my-site": "https://a.example.com"]
        try await save([site])
        let coordinator = makeCoordinator()
        try await reconcile(coordinator, running: ["my-site"])
        launcher.urls = ["my-site": "https://b.example.com"]
        try await setShare(site.id) { $0.hostname = "b.example.com" }
        try await reconcile(coordinator, running: ["my-site"])

        launcher.urls = ["my-site": "https://a.example.com"]
        try await setShare(site.id) { $0.hostname = "a.example.com" }
        try await reconcile(coordinator, running: ["my-site"])

        XCTAssertEqual(statuses().first?.state, .live)
        XCTAssertEqual(cloudflaredCalls().last, "tunnel route dns --overwrite-dns wpc-my-site a.example.com")
    }

    func testGateSettingsChangeUpdatesTheLiveListener() async throws {
        let site = makeSite("my-site", share: activeShare(provider: "fixture"))
        try await save([site])
        let coordinator = makeCoordinator()
        try await reconcile(coordinator, running: ["my-site"])

        try await setShare(site.id) { $0.password = "secret-two" }
        try await reconcile(coordinator, running: ["my-site"])

        XCTAssertEqual(launcher.launches.count, 1)
        XCTAssertEqual(host.config(of: site.id)?.password, "secret-two")
        XCTAssertEqual(host.config(of: site.id)?.publicOrigin, "https://my-site.example.com")
        XCTAssertEqual(statuses().first?.state, .live)
    }

    func testGateChangeRepublishesWithTheNewRequestID() async throws {
        let first = UUID()
        let second = UUID()
        var share = activeShare(provider: "fixture")
        share.requestID = first
        let site = makeSite("my-site", share: share)
        try await save([site])
        let coordinator = makeCoordinator()
        try await reconcile(coordinator, running: ["my-site"])
        XCTAssertEqual(statuses().first?.requestID, first)

        try await setShare(site.id) { $0.requestID = second }
        try await reconcile(coordinator, running: ["my-site"])

        XCTAssertEqual(launcher.launches.count, 1)
        XCTAssertEqual(statuses().first?.state, .live)
        XCTAssertEqual(statuses().first?.requestID, second)
    }

    func testHostnameChangeRestartsTheProvider() async throws {
        let site = makeSite("my-site", share: activeShare(provider: "fixture", hostname: "a.example.com"))
        launcher.urls = ["my-site": "https://a.example.com"]
        try await save([site])
        let coordinator = makeCoordinator()
        try await reconcile(coordinator, running: ["my-site"])

        launcher.urls = ["my-site": "https://b.example.com"]
        try await setShare(site.id) { $0.hostname = "b.example.com" }
        try await reconcile(coordinator, running: ["my-site"])

        XCTAssertTrue(launcher.handles[0].terminated)
        XCTAssertEqual(launcher.launches.count, 2)
        XCTAssertEqual(statuses().first?.url, "https://b.example.com")
        XCTAssertEqual(statuses().first?.state, .live)
    }

    func testDroppedListenerIsReopened() async throws {
        let site = makeSite("my-site", share: activeShare(provider: "fixture"))
        try await save([site])
        let coordinator = makeCoordinator()
        try await reconcile(coordinator, running: ["my-site"])

        host.drop(site.id)
        try await reconcile(coordinator, running: ["my-site"])

        XCTAssertTrue(launcher.handles[0].terminated)
        XCTAssertEqual(launcher.launches.count, 2)
        XCTAssertEqual(host.openCount, 2)
        XCTAssertEqual(statuses().first?.state, .live)
    }

    func testPreflightFailureIsReportedDown() async throws {
        let site = makeSite("my-site", share: activeShare(provider: "broken"))
        try await save([site])
        let coordinator = makeCoordinator()

        try await reconcile(coordinator, running: ["my-site"])

        let status = try XCTUnwrap(statuses().first)
        XCTAssertEqual(status.state, .down)
        XCTAssertEqual(status.error, ShareError.providerMissingBinary(name: "broken", install: "brew install broken").description)
        XCTAssertEqual(launcher.launches.count, 0)
        XCTAssertNil(host.port(of: site.id))
    }

    func testDeactivatingWhileStartingCancelsTheLaunch() async throws {
        let site = makeSite("my-site", share: activeShare(provider: "fixture"))
        launcher.held = ["my-site"]
        try await save([site])
        let coordinator = makeCoordinator()

        let envelope = try await persistence.load()
        await coordinator.reconcile(envelope: envelope, routes: HTTPSProxy.routes(from: envelope), running: ["my-site"])
        _ = try await waitForStatus { $0.first?.state == .starting }
        try await waitUntil { self.launcher.launches.count == 1 }

        try await setShare(site.id) { $0.active = false }
        try await reconcile(coordinator, running: ["my-site"])

        XCTAssertEqual(statuses(), [])
        XCTAssertTrue(host.closed.contains(site.id))
        XCTAssertEqual(launcher.handles.count, 0)
        XCTAssertEqual(pidRecords(), [])
    }

    func testProviderIsRecordedAsSoonAsItLaunches() async throws {
        let site = makeSite("my-site", share: activeShare(provider: "fixture"))
        launcher.held = ["my-site"]
        try await save([site])
        let coordinator = makeCoordinator()
        let envelope = try await persistence.load()
        await coordinator.reconcile(envelope: envelope, routes: HTTPSProxy.routes(from: envelope), running: ["my-site"])
        // The launch callback records the pid on the coordinator's actor, after the
        // fake launcher has already counted the launch.
        try await waitUntil { self.launcher.launches.count == 1 && !self.pidRecords().isEmpty }

        XCTAssertEqual(statuses().first?.state, .starting)
        let record = try XCTUnwrap(pidRecords().first)
        XCTAssertEqual(record.instanceID, site.id)
        XCTAssertEqual(record.executable, "/usr/local/bin/fake-fixture")

        launcher.held = []
        await coordinator.waitUntilIdle()
        XCTAssertEqual(pidRecords().map(\.pid), [record.pid])
        XCTAssertEqual(statuses().first?.pid, record.pid)
    }

    func testStopAllTerminatesProvidersAndClearsTheStatusFile() async throws {
        let site = makeSite("my-site", share: activeShare(provider: "fixture"))
        try await save([site])
        let coordinator = makeCoordinator()
        try await reconcile(coordinator, running: ["my-site"])

        await coordinator.stopAll()

        XCTAssertTrue(launcher.handles[0].terminated)
        XCTAssertTrue(host.closed.contains(site.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: statusFile.path))
        XCTAssertEqual(pidRecords(), [])
        let storedActive = try await persistence.load().sites.first?.share?.active
        XCTAssertEqual(storedActive, true)

        try await reconcile(coordinator, running: ["my-site"])
        XCTAssertEqual(launcher.launches.count, 1)
    }

    func testDefaultLauncherReportsAnExitThatPrecedesItsHandler() async throws {
        let script = tempRoot.appendingPathComponent("fixture")
        try "#!/bin/sh\necho \"http://127.0.0.1:9\"\nexit 3\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let provider = ScriptProvider(name: "fixture", executable: script)
        let spec = try provider.launchSpec(upstream: URL(string: "http://127.0.0.1:1")!, hostname: nil,
                                           instanceSlug: "my-site", tunnelName: nil)

        let launched = try await DefaultShareProcessLauncher(readyTimeout: .seconds(5))
            .launch(spec: spec, provider: provider) { _ in }
        XCTAssertEqual(launched.url, "http://127.0.0.1:9")
        let handle = try XCTUnwrap(launched.process as? LaunchedShareProcess)
        let deadline = Date().addingTimeInterval(10)
        while !handle.hasRecordedExit && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(handle.hasRecordedExit, "script never exited")

        let exited = expectation(description: "exit reported")
        launched.process.onExit = { status, _ in
            XCTAssertEqual(status, 3)
            exited.fulfill()
        }
        await fulfillment(of: [exited], timeout: 2)
    }

    func testProxyReportsWhetherAShareListenerIsOpen() async throws {
        let proxy = HTTPSProxy(ca: CertificateAuthority(directory: tempRoot.appendingPathComponent("ca")),
                               persistence: persistence)
        let id = UUID()
        let config = ShareGateConfig(publicOrigin: "https://share.example.com", upstreamHost: "my-site.localhost",
                                     localOrigins: ["http://my-site.localhost"], username: "share",
                                     password: "secret-one", authDisabled: false, allow: [])
        XCTAssertFalse(proxy.isShareListenerOpen(instanceID: id))

        _ = try await proxy.openShareListener(instanceID: id, route: HTTPSProxy.Route(port: 8881), config: config)
        XCTAssertTrue(proxy.isShareListenerOpen(instanceID: id))

        proxy.closeShareListener(instanceID: id)
        XCTAssertFalse(proxy.isShareListenerOpen(instanceID: id))
    }

    // MARK: - Helpers

    private func makeCoordinator() -> ShareCoordinator {
        let providers: [String: FakeShareProvider] = [
            "fixture": FakeShareProvider(name: "fixture", randomURLsAreTemporary: false),
            "ngrok": FakeShareProvider(name: "ngrok", randomURLsAreTemporary: false),
            "cloudflared": FakeShareProvider(name: "cloudflared", randomURLsAreTemporary: true),
            "broken": FakeShareProvider(name: "broken", randomURLsAreTemporary: false,
                                        preflightError: .providerMissingBinary(name: "broken", install: "brew install broken")),
        ]
        let executable = cloudflared!
        let registry = registryFile!
        return ShareCoordinator(
            host: host,
            persistence: persistence,
            launcher: launcher,
            providers: { name in
                guard let provider = providers[name] else { throw ShareError.providerNotFound(name) }
                return provider
            },
            statusFile: statusFile,
            pidsFile: pidsFile,
            tunnels: { CloudflaredTunnels(executable: executable, registryFile: registry) }
        )
    }

    private func makeSite(_ slug: String, port: Int = 8881, share: ShareSettings?,
                          networkType: NetworkType = .none) -> Site {
        Site(name: slug, slug: slug, path: tempRoot.appendingPathComponent(slug, isDirectory: true),
             port: port, imageTag: SiteRecipe.defaultWordPressImage, networkType: networkType, share: share)
    }

    private func activeShare(provider: String, hostname: String? = nil) -> ShareSettings {
        ShareSettings(provider: provider, hostname: hostname, username: "share", password: "secret-one", active: true)
    }

    private func inactiveShare(provider: String?, hostname: String?) -> ShareSettings {
        ShareSettings(provider: provider, hostname: hostname, username: "share", password: "secret-one")
    }

    private func save(_ sites: [Site]) async throws {
        try await persistence.save(StoreEnvelope(sites: sites))
    }

    private func setShare(_ id: UUID, _ change: @escaping @Sendable (inout ShareSettings) -> Void) async throws {
        try await persistence.mutate { envelope in
            guard let i = envelope.sites.firstIndex(where: { $0.id == id }), var share = envelope.sites[i].share else { return }
            change(&share)
            envelope.sites[i].share = share
        }
    }

    private func reconcile(_ coordinator: ShareCoordinator, running: Set<String>) async throws {
        let envelope = try await persistence.load()
        await coordinator.reconcile(envelope: envelope, routes: HTTPSProxy.routes(from: envelope), running: running)
        await coordinator.waitUntilIdle()
    }

    private func statuses() -> [ShareStatus] {
        ProxyControl.shares(file: statusFile)
    }

    private func pidRecords() -> [SharePIDRecord] {
        guard let data = try? Data(contentsOf: pidsFile) else { return [] }
        return (try? JSONDecoder().decode([SharePIDRecord].self, from: data)) ?? []
    }

    private func registry() -> [CloudflareTunnelRecord] {
        CloudflaredTunnels(executable: cloudflared, registryFile: registryFile).records()
    }

    private func cloudflaredCalls() -> [String] {
        ((try? String(contentsOf: cloudflaredLog, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    private func waitForStatus(_ condition: ([ShareStatus]) -> Bool) async throws -> [ShareStatus] {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let current = statuses()
            if condition(current) { return current }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("status condition not met: \(statuses())")
        return statuses()
    }

    private func waitForStoredShare(_ id: UUID, _ condition: (ShareSettings) -> Bool) async throws -> ShareSettings {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let share = try await persistence.load().sites.first(where: { $0.id == id })?.share, condition(share) {
                return share
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("stored share condition not met")
        let share = try await persistence.load().sites.first { $0.id == id }?.share
        return try XCTUnwrap(share)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition())
    }

    private func spawnSleep() throws -> Process {
        try spawn("/bin/sleep", ["30"])
    }

    private func spawn(_ executable: String, _ arguments: [String]) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
        spawned.append(process)
        return process
    }

    /// A `sleep` whose parent exited, so launchd adopted it.
    private func spawnAdoptedSleep() throws -> ProcessIdentity {
        let output = Pipe()
        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: "/bin/sh")
        parent.arguments = ["-c", "sleep 30 >/dev/null 2>&1 & echo $!"]
        parent.standardOutput = output
        try parent.run()
        parent.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let pid = try XCTUnwrap(Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        spawnedPIDs.append(pid)
        let deadline = Date().addingTimeInterval(5)
        while ShareCoordinator.parentPID(of: pid) != 1 && Date() < deadline { usleep(20_000) }
        return try XCTUnwrap(ProcessIdentity.current(pid))
    }
}

// MARK: - Fakes

private final class FakeShareListenerHost: ShareListenerHost, @unchecked Sendable {
    private let lock = NSLock()
    private var open: [UUID: (port: UInt16, config: ShareGateConfig)] = [:]
    private var nextPort: UInt16 = 40000
    private var _closed: [UUID] = []
    private var _openCount = 0

    var closed: [UUID] { lock.withLock { _closed } }
    var openCount: Int { lock.withLock { _openCount } }

    func port(of id: UUID) -> UInt16? { lock.withLock { open[id]?.port } }
    func config(of id: UUID) -> ShareGateConfig? { lock.withLock { open[id]?.config } }
    func drop(_ id: UUID) { lock.withLock { _ = open.removeValue(forKey: id) } }

    func openShareListener(instanceID: UUID, route: HTTPSProxy.Route, config: ShareGateConfig) async throws -> UInt16 {
        lock.withLock {
            nextPort += 1
            _openCount += 1
            open[instanceID] = (nextPort, config)
            return nextPort
        }
    }

    func updateShareConfig(instanceID: UUID, config: ShareGateConfig) {
        lock.withLock { open[instanceID]?.config = config }
    }

    func closeShareListener(instanceID: UUID) {
        lock.withLock {
            open.removeValue(forKey: instanceID)
            _closed.append(instanceID)
        }
    }

    func isShareListenerOpen(instanceID: UUID) -> Bool {
        lock.withLock { open[instanceID] != nil }
    }
}

private struct FakeShareProvider: ShareProvider {
    let name: String
    let randomURLsAreTemporary: Bool
    var preflightError: ShareError?

    func preflight() async throws {
        if let preflightError { throw preflightError }
    }

    func launchSpec(upstream: URL, hostname: String?, instanceSlug: String, tunnelName: String?) throws -> ShareLaunchSpec {
        ShareLaunchSpec(executable: URL(fileURLWithPath: "/usr/local/bin/fake-\(name)"), arguments: [],
                        environment: ["UPSTREAM": upstream.absoluteString, "SLUG": instanceSlug,
                                      "TUNNEL": tunnelName ?? ""])
    }

    func publicURL(fromOutputLine: String) -> String? { nil }
}

private final class FakeShareLauncher: ShareProcessLauncher, @unchecked Sendable {
    struct Launch {
        let slug: String
        let upstream: String
        let tunnelName: String
    }

    private let lock = NSLock()
    private var _urls: [String: String] = [:]
    private var _held: Set<String> = []
    private var _launches: [Launch] = []
    private var _handles: [FakeShareHandle] = []
    private var nextPID: Int32 = 900_000

    var urls: [String: String] {
        get { lock.withLock { _urls } }
        set { lock.withLock { _urls = newValue } }
    }
    /// Slugs whose launch waits until removed from this set or cancelled.
    var held: Set<String> {
        get { lock.withLock { _held } }
        set { lock.withLock { _held = newValue } }
    }
    var launches: [Launch] { lock.withLock { _launches } }
    var handles: [FakeShareHandle] { lock.withLock { _handles } }

    func launch(spec: ShareLaunchSpec, provider: any ShareProvider,
                launched: @escaping @Sendable (Int32) -> Void) async throws -> (url: String, process: any ShareProcessHandle) {
        let slug = spec.environment["SLUG"] ?? ""
        let (url, isHeld, pid) = lock.withLock { () -> (String, Bool, Int32) in
            _launches.append(Launch(slug: slug, upstream: spec.environment["UPSTREAM"] ?? "",
                                    tunnelName: spec.environment["TUNNEL"] ?? ""))
            nextPID += 1
            return (_urls[slug] ?? "https://\(slug).example.com", _held.contains(slug), nextPID)
        }
        launched(pid)
        if isHeld {
            while held.contains(slug) { try await Task.sleep(for: .milliseconds(10)) }
        }
        let handle = lock.withLock { () -> FakeShareHandle in
            let handle = FakeShareHandle(pid: pid)
            _handles.append(handle)
            return handle
        }
        return (url, handle)
    }
}

private final class FakeShareHandle: ShareProcessHandle, @unchecked Sendable {
    let pid: Int32
    private let lock = NSLock()
    private var handler: (@Sendable (Int32, [String]) -> Void)?
    private var _terminated = false
    private var exited = false

    init(pid: Int32) { self.pid = pid }

    var terminated: Bool { lock.withLock { _terminated } }

    var onExit: (@Sendable (Int32, [String]) -> Void)? {
        get { lock.withLock { handler } }
        set { lock.withLock { handler = newValue } }
    }

    func terminate() async {
        lock.withLock { _terminated = true }
        exit(status: 15, stderrTail: [])
    }

    func exit(status: Int32, stderrTail: [String]) {
        let handler: (@Sendable (Int32, [String]) -> Void)? = lock.withLock {
            guard !exited else { return nil }
            exited = true
            return self.handler
        }
        handler?(status, stderrTail)
    }
}
