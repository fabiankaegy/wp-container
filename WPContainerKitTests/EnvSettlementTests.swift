import XCTest
@testable import WPContainerKit

/// Settling worktree envs: the staleness and purge clock, which ports a
/// settled env gives back, routing, and the settle/restore store writes.
final class EnvSettlementTests: XCTestCase {

    private var tempRoot: URL!
    private let parentID = UUID()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86_400

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wpc-settle-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    // MARK: - Clock

    func testLastUsedFallsBackToCreation() {
        let created = now.addingTimeInterval(-3 * day)
        XCTAssertEqual(env(createdAt: created).lastUsedAt, created)
        XCTAssertEqual(env(createdAt: created, lastActivityAt: now).lastUsedAt, now)
        // A stamp older than creation (e.g. copied from elsewhere) doesn't count.
        XCTAssertEqual(env(createdAt: created, lastActivityAt: created.addingTimeInterval(-day)).lastUsedAt, created)
    }

    func testStaleAfterSevenDaysUnused() {
        let sixDays = env(createdAt: now.addingTimeInterval(-6.9 * day))
        let sevenDays = env(createdAt: now.addingTimeInterval(-7 * day))
        XCTAssertEqual(EnvSettlement.daysUnused(sixDays, now: now), 6)
        XCTAssertFalse(EnvSettlement.isStale(sixDays, now: now))
        XCTAssertTrue(EnvSettlement.isStale(sevenDays, now: now))
    }

    func testSettledEnvIsNeverStale() {
        let settled = env(createdAt: now.addingTimeInterval(-90 * day), settledAt: now)
        XCTAssertFalse(EnvSettlement.isStale(settled, now: now))
    }

    func testPurgeIsDueAfterTheWindow() {
        let active = env(createdAt: now.addingTimeInterval(-90 * day))
        let recent = env(settledAt: now.addingTimeInterval(-29 * day))
        let old = env(settledAt: now.addingTimeInterval(-30 * day))
        XCTAssertNil(EnvSettlement.purgeDate(active, afterDays: 30))
        XCTAssertFalse(EnvSettlement.isDueForPurge(active, afterDays: 30, now: now))
        XCTAssertFalse(EnvSettlement.isDueForPurge(recent, afterDays: 30, now: now))
        XCTAssertTrue(EnvSettlement.isDueForPurge(old, afterDays: 30, now: now))
        XCTAssertTrue(EnvSettlement.isDueForPurge(recent, afterDays: 14, now: now))
    }

    func testRecordWithoutSettledAtDecodesAsActive() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(env(settledAt: now))) as? [String: Any])
        json.removeValue(forKey: "settledAt")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(WorktreeEnv.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(decoded.isSettled)
    }

    // MARK: - Ports and routes

    func testSettledEnvGivesBackItsPorts() {
        var settled = env(slug: "settled", port: 8890, settledAt: now)
        settled.mailpitEnabled = true
        settled.mailpitPort = 8891
        var active = env(slug: "active", port: 8892)
        active.mailpitEnabled = true
        active.mailpitPort = 8893

        let reserved = PortAllocator.reservedPorts(sites: [], envs: [settled, active])

        XCTAssertEqual(reserved, [8892, 8893])
    }

    func testSettledEnvHasNoRoute() {
        let envelope = StoreEnvelope(sites: [], envs: [env(slug: "settled", port: 8890, settledAt: now),
                                                       env(slug: "active", port: 8892)])
        let routes = HTTPSProxy.routes(from: envelope)
        XCTAssertNil(routes["settled.localhost"])
        XCTAssertNotNil(routes["active.localhost"])
    }

    // MARK: - Store

    func testSettleThenRestoreKeepsAFreePort() async throws {
        let persistence = makePersistence()
        let port = try XCTUnwrap(PortAllocator.firstFreePort(from: 48_881, excluding: []))
        let record = env(slug: "feature", port: port)
        _ = try await persistence.mutate { $0.envs.append(record) }

        let settled = try await persistence.settleEnv(id: record.id, now: now)
        XCTAssertEqual(settled?.settledAt, now)

        let result = try await persistence.restoreEnv(id: record.id)
        let restored = try XCTUnwrap(result)
        XCTAssertFalse(restored.env.isSettled)
        XCTAssertEqual(restored.env.port, port)
        XCTAssertFalse(restored.portChanged)
    }

    func testRestoreMovesOffAPortSomeoneElseTook() async throws {
        let persistence = makePersistence()
        let port = try XCTUnwrap(PortAllocator.firstFreePort(from: 48_881, excluding: []))
        let record = env(slug: "feature", port: port, settledAt: now)
        let squatter = env(slug: "squatter", port: port)
        _ = try await persistence.mutate { $0.envs += [record, squatter] }

        let result = try await persistence.restoreEnv(id: record.id)
        let restored = try XCTUnwrap(result)

        XCTAssertNotEqual(restored.env.port, port)
        XCTAssertTrue(restored.portChanged)
        XCTAssertFalse(restored.env.isSettled)
    }

    // MARK: - Helpers

    private func env(slug: String = "feature", port: Int = 8890, createdAt: Date? = nil,
                     lastActivityAt: Date? = nil, settledAt: Date? = nil) -> WorktreeEnv {
        WorktreeEnv(parentSiteID: parentID,
                    parentSlug: "my-site",
                    envSlug: slug,
                    repoRelPath: "wp-content",
                    branch: slug,
                    worktreePath: tempRoot.appendingPathComponent("\(slug)/worktree"),
                    envPath: tempRoot.appendingPathComponent(slug),
                    port: port,
                    imageTag: "wordpress:6.8",
                    createdAt: createdAt ?? now.addingTimeInterval(-60 * day),
                    lastActivityAt: lastActivityAt,
                    settledAt: settledAt)
    }

    private func makePersistence() -> StorePersistence {
        StorePersistence(fileURL: tempRoot.appendingPathComponent("sites.json"))
    }
}
