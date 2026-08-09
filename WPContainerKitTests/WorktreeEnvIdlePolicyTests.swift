import XCTest
@testable import WPContainerKit

/// Integration of `IdlePolicy` with the concrete `WorktreeEnv` model: the
/// resolved timeout, the creation-grace window keyed off `createdAt`, and that
/// existing `sites.json` records (predating this change) still decode.
final class WorktreeEnvIdlePolicyTests: XCTestCase {

    private func makeEnv(createdAt: Date, idleStopMinutes: Int? = nil) -> WorktreeEnv {
        WorktreeEnv(
            parentSiteID: UUID(),
            parentSlug: "demo",
            envSlug: "demo-wt-test",
            repoRelPath: "wp-content/plugins/demo",
            branch: "test",
            worktreePath: URL(fileURLWithPath: "/tmp/wt"),
            envPath: URL(fileURLWithPath: "/tmp/env"),
            port: 9000,
            imageTag: "wpc-wordpress:latest",
            createdAt: createdAt,
            idleStopMinutes: idleStopMinutes
        )
    }

    func testFreshEnvGetsTheDefaultTimeoutButIsWithinGrace() {
        let env = makeEnv(createdAt: Date())
        XCTAssertEqual(env.effectiveIdleStopMinutes, IdlePolicy.defaultEnvMinutes)
        XCTAssertTrue(IdlePolicy.isWithinCreationGrace(createdAt: env.createdAt, now: Date()))
    }

    func testDayOldEnvIsPastTheGraceWindow() {
        let env = makeEnv(createdAt: Date().addingTimeInterval(-60 * 60 * 24))
        XCTAssertFalse(IdlePolicy.isWithinCreationGrace(createdAt: env.createdAt, now: Date()))
        // Past grace, the ordinary 3h default timeout is what applies.
        XCTAssertEqual(env.effectiveIdleStopMinutes, IdlePolicy.defaultEnvMinutes)
    }

    func testExplicitOverrideSurvivesRegardlessOfAge() {
        // A fresh env with an explicit 15-minute override: the grace window
        // only suspends the DEFAULT clock's enforcement in the sweep, it never
        // changes what `effectiveIdleStopMinutes` reports for an explicit value.
        let env = makeEnv(createdAt: Date(), idleStopMinutes: 15)
        XCTAssertEqual(env.effectiveIdleStopMinutes, 15)
    }

    func testExplicitOffSurvives() {
        let env = makeEnv(createdAt: Date().addingTimeInterval(-60 * 60 * 24), idleStopMinutes: 0)
        XCTAssertEqual(env.effectiveIdleStopMinutes, 0)
    }

    // MARK: - Decode compatibility (sites.json must keep loading)

    /// Shaped like a record written before issue #16 (idle-stop) and #17
    /// (shared DB) ever existed: no `idleStopMinutes`, `lastActivityAt`,
    /// `mailpitEnabled`/`mailpitPort`, `cpuLimit`/`memoryLimitMB`,
    /// `sharedDatabase`/`databaseSchema` keys at all. `createdAt` has always
    /// been required, so it's present. Must decode without throwing, and the
    /// newer fields must resolve to their documented "not set" defaults.
    func testDecodesLegacyRecordMissingEveryNewerOptionalField() throws {
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "parentSiteID": "\(UUID().uuidString)",
          "parentSlug": "demo",
          "envSlug": "demo-wt-legacy",
          "repoRelPath": "wp-content/plugins/demo",
          "branch": "legacy",
          "worktreePath": "file:///tmp/wt",
          "envPath": "file:///tmp/env",
          "port": 9001,
          "imageTag": "wpc-wordpress:latest",
          "createdAt": "2025-01-01T00:00:00Z",
          "provisioned": true
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601 // matches StorePersistence
        let env = try decoder.decode(WorktreeEnv.self, from: Data(json.utf8))

        XCTAssertEqual(env.envSlug, "demo-wt-legacy")
        XCTAssertNil(env.idleStopMinutes)
        XCTAssertNil(env.lastActivityAt)
        XCTAssertFalse(env.mailpitEnabled)
        XCTAssertNil(env.mailpitPort)
        XCTAssertNil(env.cpuLimit)
        XCTAssertFalse(env.sharedDatabase)
        XCTAssertNil(env.databaseSchema)
        // Resolves to the (now 180-minute) built-in default, and — being from
        // 2025 — is long past the creation-grace window.
        XCTAssertEqual(env.effectiveIdleStopMinutes, IdlePolicy.defaultEnvMinutes)
        XCTAssertFalse(IdlePolicy.isWithinCreationGrace(createdAt: env.createdAt, now: Date()))
    }
}
