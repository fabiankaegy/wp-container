import XCTest
@testable import WPContainerKit

/// Coverage for the idle-stop policy tuning: env default = 180 minutes (3h),
/// the post-creation grace window, explicit per-instance overrides still
/// winning, and the minute-formatting helper the CLI/UI both rely on.
final class IdlePolicyTests: XCTestCase {

    // MARK: - Defaults

    func testEnvDefaultIsThreeHours() {
        XCTAssertEqual(IdlePolicy.defaultEnvMinutes, 180)
        XCTAssertEqual(IdlePolicy.effectiveMinutes(configured: nil, isEnv: true), 180)
    }

    func testSiteDefaultIsOff() {
        XCTAssertEqual(IdlePolicy.defaultSiteMinutes, 0)
        XCTAssertEqual(IdlePolicy.effectiveMinutes(configured: nil, isEnv: false), 0)
    }

    func testRecommendedMinutesTracksEnvDefaultAndIsSelectable() {
        XCTAssertEqual(IdlePolicy.recommendedMinutes, IdlePolicy.defaultEnvMinutes)
        XCTAssertTrue(IdlePolicy.selectableMinutes.contains(IdlePolicy.defaultEnvMinutes))
        XCTAssertEqual(IdlePolicy.selectableMinutes.first, IdlePolicy.recommendedMinutes)
    }

    // MARK: - Explicit overrides still win

    func testExplicitOverrideWinsOverTheDefault() {
        XCTAssertEqual(IdlePolicy.effectiveMinutes(configured: 15, isEnv: true), 15)
        XCTAssertEqual(IdlePolicy.effectiveMinutes(configured: 45, isEnv: false), 45)
    }

    func testExplicitOffWins() {
        XCTAssertEqual(IdlePolicy.effectiveMinutes(configured: 0, isEnv: true), 0)
    }

    func testNegativeConfiguredIsTreatedAsOffRatherThanImmediate() {
        XCTAssertEqual(IdlePolicy.effectiveMinutes(configured: -5, isEnv: true), 0)
    }

    // MARK: - Creation grace window

    func testFreshEnvIsWithinGrace() {
        let now = Date()
        let createdAt = now.addingTimeInterval(-60 * 60) // 1 hour ago
        XCTAssertTrue(IdlePolicy.isWithinCreationGrace(createdAt: createdAt, now: now))
    }

    func testEnvPastGraceWindowIsNoLongerExempt() {
        let now = Date()
        let createdAt = now.addingTimeInterval(-60 * 60 * 7) // 7 hours ago
        XCTAssertFalse(IdlePolicy.isWithinCreationGrace(createdAt: createdAt, now: now))
    }

    func testGraceWindowBoundaryIsExclusive() {
        let now = Date()
        // Exactly `envCreationGraceMinutes` old: the window has just elapsed.
        let createdAt = now.addingTimeInterval(-Double(IdlePolicy.envCreationGraceMinutes) * 60)
        XCTAssertFalse(IdlePolicy.isWithinCreationGrace(createdAt: createdAt, now: now))
    }

    func testJustInsideGraceWindowIsExempt() {
        let now = Date()
        let createdAt = now.addingTimeInterval(-Double(IdlePolicy.envCreationGraceMinutes) * 60 + 1)
        XCTAssertTrue(IdlePolicy.isWithinCreationGrace(createdAt: createdAt, now: now))
    }

    // MARK: - formatMinutes

    func testFormatMinutesRendersWholeHours() {
        XCTAssertEqual(IdlePolicy.formatMinutes(180), "3 hours")
        XCTAssertEqual(IdlePolicy.formatMinutes(60), "1 hour")
    }

    func testFormatMinutesRendersMinutesWhenNotAWholeHour() {
        XCTAssertEqual(IdlePolicy.formatMinutes(15), "15 min")
        XCTAssertEqual(IdlePolicy.formatMinutes(90), "90 min")
    }
}
