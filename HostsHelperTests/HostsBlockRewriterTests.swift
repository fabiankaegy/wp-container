import XCTest
import Security

/// Exercises the helper's security boundary (`HostsBlockRewriter`) hard: valid
/// rewrites, marker-block isolation, preservation of unrelated content, and a
/// battery of hostile inputs that MUST be rejected. Also spot-checks that the
/// shared client code-signing requirement parses into a valid `SecRequirement`.
final class HostsBlockRewriterTests: XCTestCase {

    private let base = """
    ##
    # Host Database
    ##
    127.0.0.1\tlocalhost
    255.255.255.255\tbroadcasthost
    ::1             localhost
    """

    // MARK: - Happy path

    func testWritesFreshBlockPreservingExistingContent() throws {
        let out = try HostsBlockRewriter.rewrite(base, entries: [
            "127.0.0.1\tmysite.local",
            "127.0.0.1 shop.example.dev",
        ])
        // Original lines are all preserved, byte-for-byte.
        XCTAssertTrue(out.contains("127.0.0.1\tlocalhost"))
        XCTAssertTrue(out.contains("255.255.255.255\tbroadcasthost"))
        XCTAssertTrue(out.contains("::1             localhost"))
        // Managed block present with normalized tab-separated entries.
        XCTAssertTrue(out.contains("# wp-container begin\n127.0.0.1\tmysite.local\n127.0.0.1\tshop.example.dev\n# wp-container end"))
        XCTAssertTrue(out.hasSuffix("\n"))
    }

    func testRewriteReplacesPreviousBlockNotDuplicates() throws {
        let first = try HostsBlockRewriter.rewrite(base, entries: ["127.0.0.1\ta.local"])
        let second = try HostsBlockRewriter.rewrite(first, entries: ["127.0.0.1\tb.local"])
        XCTAssertFalse(second.contains("a.local"))
        XCTAssertTrue(second.contains("b.local"))
        // Exactly one begin marker.
        XCTAssertEqual(second.components(separatedBy: "# wp-container begin").count - 1, 1)
    }

    func testDeduplicatesPreservingOrder() throws {
        let out = try HostsBlockRewriter.rewrite("", entries: [
            "127.0.0.1\tb.local",
            "127.0.0.1\ta.local",
            "127.0.0.1\tb.local",
        ])
        let block = out.components(separatedBy: "\n").filter { $0.hasPrefix("127.0.0.1") }
        XCTAssertEqual(block, ["127.0.0.1\tb.local", "127.0.0.1\ta.local"])
    }

    func testEmptyEntriesRemovesBlockEntirely() throws {
        let withBlock = try HostsBlockRewriter.rewrite(base, entries: ["127.0.0.1\tx.local"])
        let cleared = try HostsBlockRewriter.rewrite(withBlock, entries: [])
        XCTAssertFalse(cleared.contains("# wp-container"))
        XCTAssertFalse(cleared.contains("x.local"))
        XCTAssertTrue(cleared.contains("broadcasthost"))
    }

    func testRemoveBlockLeavesOtherContentIntact() {
        let withBlock = (try? HostsBlockRewriter.rewrite(base, entries: ["127.0.0.1\ty.local"])) ?? ""
        let removed = HostsBlockRewriter.removeBlock(withBlock)
        XCTAssertFalse(removed.contains("# wp-container"))
        XCTAssertTrue(removed.contains("127.0.0.1\tlocalhost"))
        XCTAssertTrue(removed.contains("broadcasthost"))
    }

    func testRecoversFromCorruptedBlockMissingEnd() throws {
        // A begin marker with no end (a prior crash) plus our-format lines: the
        // corrupted run is removed and a clean block re-emitted.
        let corrupted = """
        127.0.0.1\tlocalhost

        # wp-container begin
        127.0.0.1\tstale-a.local
        127.0.0.1\tstale-b.local
        """
        let out = try HostsBlockRewriter.rewrite(corrupted, entries: ["127.0.0.1\tfresh.local"])
        XCTAssertFalse(out.contains("stale-a.local"))
        XCTAssertFalse(out.contains("stale-b.local"))
        XCTAssertTrue(out.contains("127.0.0.1\tfresh.local"))
        XCTAssertEqual(out.components(separatedBy: "# wp-container begin").count - 1, 1)
        XCTAssertEqual(out.components(separatedBy: "# wp-container end").count - 1, 1)
    }

    // MARK: - Hostile inputs (MUST reject the whole operation)

    func testRejectsNonLoopbackAddress() {
        assertRejected(["10.0.0.1\tevil.local"])
        assertRejected(["0.0.0.0\tevil.local"])
        assertRejected(["127.0.0.2\tevil.local"])
        assertRejected(["::1\tevil.local"])
    }

    func testRejectsNewlineInjection() {
        // A second address line smuggled into one entry.
        assertRejected(["127.0.0.1\tok.local\n0.0.0.0\tevil.com"])
        assertRejected(["127.0.0.1\tok.local\n# wp-container end\nmalicious"])
    }

    func testRejectsExtraTokens() {
        assertRejected(["127.0.0.1\tok.local extra.local"])
        assertRejected(["127.0.0.1\tok.local # comment"])
    }

    func testRejectsCommandInjectionCharacters() {
        assertRejected(["127.0.0.1\t$(rm -rf /)"])
        assertRejected(["127.0.0.1\tfoo;bar.local"])
        assertRejected(["127.0.0.1\tfoo bar.local"])
        assertRejected(["127.0.0.1\tfoo/bar.local"])
    }

    func testRejectsInvalidHostnames() {
        assertRejected(["127.0.0.1\tnodot"])            // single label
        assertRejected(["127.0.0.1\t-lead.local"])      // leading dash
        assertRejected(["127.0.0.1\ttrail-.local"])     // trailing dash
        assertRejected(["127.0.0.1\tUPPER.local"])      // uppercase not normalized
        assertRejected(["127.0.0.1\tfoo..local"])       // empty label
        assertRejected(["127.0.0.1\t"])                 // no hostname
        assertRejected(["127.0.0.1"])                   // no hostname at all
        let longLabel = String(repeating: "a", count: 64)
        assertRejected(["127.0.0.1\t\(longLabel).local"])
    }

    func testRejectionIsAtomic() {
        // One bad entry among good ones rejects the ENTIRE write — no partial block.
        assertRejected([
            "127.0.0.1\tgood-one.local",
            "127.0.0.1\tbad host.local",
            "127.0.0.1\tgood-two.local",
        ])
    }

    // MARK: - Requirement parsing

    func testClientCodeRequirementParses() {
        var req: SecRequirement?
        let status = SecRequirementCreateWithString(HostsHelperInfo.clientCodeRequirement as CFString, [], &req)
        XCTAssertEqual(status, errSecSuccess)
        XCTAssertNotNil(req)
    }

    func testSelfDeveloperIDRequirementParses() {
        var req: SecRequirement?
        let status = SecRequirementCreateWithString(HostsHelperInfo.selfDeveloperIDRequirement as CFString, [], &req)
        XCTAssertEqual(status, errSecSuccess)
        XCTAssertNotNil(req)
    }

    func testGarbageRequirementFailsToParse() {
        var req: SecRequirement?
        let status = SecRequirementCreateWithString("this is (not a requirement" as CFString, [], &req)
        XCTAssertNotEqual(status, errSecSuccess)
    }

    // MARK: - Helpers

    private func assertRejected(_ entries: [String], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try HostsBlockRewriter.rewrite(base, entries: entries), file: file, line: line) { error in
            XCTAssertTrue(error is HostsBlockRewriter.ValidationError,
                          "expected ValidationError, got \(error)", file: file, line: line)
        }
    }
}
