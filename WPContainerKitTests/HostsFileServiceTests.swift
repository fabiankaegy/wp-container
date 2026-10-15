import XCTest
@testable import WPContainerKit

/// Covers the app-side managed `/etc/hosts` block: IPv4 + IPv6 entries per
/// domain, and upgrading blocks written before the `::1` lines existed.
final class HostsFileServiceTests: XCTestCase {

    private let base = "127.0.0.1\tlocalhost\n::1             localhost\n"

    func testRewriteWritesIPv4AndIPv6PerDomain() {
        let out = HostsFileService.rewrite(base, domains: ["a.local", "b.test", "a.local"])
        XCTAssertTrue(out.hasSuffix("""
        # wp-container begin
        127.0.0.1\ta.local
        ::1\ta.local
        127.0.0.1\tb.test
        ::1\tb.test
        # wp-container end

        """))
        XCTAssertTrue(out.hasPrefix(base))
    }

    func testManagedDomainsListsEachDomainOnce() {
        let out = HostsFileService.rewrite(base, domains: ["a.local", "b.test"])
        XCTAssertEqual(HostsFileService.managedDomains(in: out), ["a.local", "b.test"])
    }

    func testIPv4OnlyBlockIsNotUpToDate() {
        let old = base + "\n# wp-container begin\n127.0.0.1\ta.local\n# wp-container end\n"
        XCTAssertFalse(HostsFileService.isUpToDate(old, domains: ["a.local"]))
        XCTAssertEqual(HostsFileService.managedDomains(in: old), ["a.local"])
    }

    func testFreshBlockIsUpToDate() {
        let out = HostsFileService.rewrite(base, domains: ["a.local", "b.test"])
        XCTAssertTrue(HostsFileService.isUpToDate(out, domains: ["b.test", "a.local"]))
        XCTAssertFalse(HostsFileService.isUpToDate(out, domains: ["a.local"]))
    }

    func testRecoversCorruptedBlockWithIPv6Lines() {
        let corrupted = base + "\n# wp-container begin\n127.0.0.1\tstale.local\n::1\tstale.local\n"
        let out = HostsFileService.rewrite(corrupted, domains: ["fresh.local"])
        XCTAssertFalse(out.contains("stale.local"))
        XCTAssertEqual(HostsFileService.managedDomains(in: out), ["fresh.local"])
    }
}
