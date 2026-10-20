import XCTest
@testable import WPContainerKit

final class CloudflaredTunnelsTests: XCTestCase {
    private var dir: URL!
    private var log: URL!
    private var registry: URL!
    private let id = UUID()
    private let tunnel = "wpc-my-site"
    private let host = "share.example.com"

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("cf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        log = dir.appendingPathComponent("argv.log")
        registry = dir.appendingPathComponent("share-cloudflare.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Fake cloudflared: logs argv, then replies per subcommand ("create", "route", "delete").
    private func tunnels(_ replies: [String: (code: Int, output: String)] = [:]) throws -> CloudflaredTunnels {
        var cases = ""
        for (sub, reply) in replies {
            cases += "  \(sub)) printf '%s\\n' '\(reply.output)' >&2; exit \(reply.code);;\n"
        }
        let script = """
        #!/bin/sh
        echo "$*" >> '\(log.path)'
        case "$2" in
        \(cases)  *) exit 0;;
        esac
        """
        let exe = dir.appendingPathComponent("cloudflared")
        try script.write(to: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        return CloudflaredTunnels(executable: exe, registryFile: registry)
    }

    private func calls() -> [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    func testEnsureCreatesTunnelAndRoute() async throws {
        let t = try tunnels()
        try await t.ensure(instanceID: id, tunnelName: tunnel, hostname: host)
        XCTAssertEqual(calls(), ["tunnel create wpc-my-site", "tunnel route dns wpc-my-site share.example.com"])
        XCTAssertFalse(calls().joined().contains("--overwrite-dns"))
        XCTAssertEqual(t.records(), [CloudflareTunnelRecord(instanceID: id, tunnelName: tunnel, hostname: host)])
    }

    func testEnsureReusesRecordedTunnel() async throws {
        let t = try tunnels()
        try await t.ensure(instanceID: id, tunnelName: tunnel, hostname: host)
        try? FileManager.default.removeItem(at: log)
        try await t.ensure(instanceID: id, tunnelName: tunnel, hostname: host)
        XCTAssertEqual(calls(), [])
    }

    func testExistingDNSRecordIsRefused() async throws {
        let t = try tunnels(["route": (1, "Failed to add route: code: 1003, reason: Failed to create record. An A, AAAA, or CNAME record with that host already exists.")])
        do {
            try await t.ensure(instanceID: id, tunnelName: tunnel, hostname: host)
            XCTFail("expected dnsRecordExists")
        } catch ShareError.dnsRecordExists(let h) {
            XCTAssertEqual(h, host)
        }
        XCTAssertEqual(t.records().count, 1)
        XCTAssertNil(t.records().first?.hostname)
        XCTAssertFalse(calls().joined().contains("--overwrite-dns"))
    }

    func testMissingCertMeansNotLoggedIn() async throws {
        let t = try tunnels(["create": (1, "ERR Cannot determine default origin certificate path. No file cert.pem in [~/.cloudflared ~/.cloudflare-warp]. Error locating origin cert: client did not specify origincert path")])
        do {
            try await t.ensure(instanceID: id, tunnelName: tunnel, hostname: host)
            XCTFail("expected cloudflaredNotLoggedIn")
        } catch ShareError.cloudflaredNotLoggedIn {
            XCTAssertTrue("\(ShareError.cloudflaredNotLoggedIn)".contains("cloudflared tunnel login"))
        }
        XCTAssertEqual(t.records(), [])
    }

    func testInvalidNamesRunNothing() async throws {
        let t = try tunnels()
        do {
            try await t.ensure(instanceID: id, tunnelName: "-bad", hostname: host)
            XCTFail("expected invalidTunnelName")
        } catch ShareError.invalidTunnelName {}
        do {
            try await t.ensure(instanceID: id, tunnelName: tunnel, hostname: "a b")
            XCTFail("expected invalidShareHostname")
        } catch ShareError.invalidShareHostname {}
        XCTAssertEqual(calls(), [])
    }

    func testCleanupDeletesOnlyRecordedTunnel() async throws {
        let t = try tunnels()
        try await t.ensure(instanceID: id, tunnelName: tunnel, hostname: host)
        try? FileManager.default.removeItem(at: log)
        let stranger = CloudflareTunnelRecord(instanceID: UUID(), tunnelName: "wpc-other", hostname: nil)
        let warnings = await t.cleanup(stranger)
        XCTAssertEqual(calls(), [])
        XCTAssertFalse(warnings.isEmpty)
        _ = await t.cleanup(t.records()[0])
        XCTAssertEqual(calls(), ["tunnel delete -f wpc-my-site"])
        XCTAssertEqual(t.records(), [])
    }

    func testCleanupWarnsAboutDNSRecord() async throws {
        let t = try tunnels()
        try await t.ensure(instanceID: id, tunnelName: tunnel, hostname: host)
        let warnings = await t.cleanup(t.records()[0])
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains(host))
        XCTAssertTrue(warnings[0].contains("CNAME"))
        XCTAssertTrue(warnings[0].contains("Cloudflare dashboard"))
    }

    func testFailedDeleteKeepsRecord() async throws {
        let t = try tunnels()
        try await t.ensure(instanceID: id, tunnelName: tunnel, hostname: host)
        let failing = try tunnels(["delete": (1, "boom")])
        let warnings = await failing.cleanup(failing.records()[0])
        XCTAssertFalse(warnings.isEmpty)
        XCTAssertEqual(failing.records().count, 1)
    }

    func testGenericRouteFailureKeepsRecordWithoutHostname() async throws {
        let t = try tunnels(["route": (1, "some network error")])
        do {
            try await t.ensure(instanceID: id, tunnelName: tunnel, hostname: host)
            XCTFail("expected cloudflaredFailed")
        } catch ShareError.cloudflaredFailed(_, let output) {
            XCTAssertTrue(output.contains("some network error"))
        }
        XCTAssertEqual(t.records(), [CloudflareTunnelRecord(instanceID: id, tunnelName: tunnel, hostname: nil)])
    }

    func testChangedHostnameIsRefusedWithoutRunningCloudflared() async throws {
        let t = try tunnels()
        try await t.ensure(instanceID: id, tunnelName: tunnel, hostname: host)
        try? FileManager.default.removeItem(at: log)
        do {
            try await t.ensure(instanceID: id, tunnelName: tunnel, hostname: "other.example.com")
            XCTFail("expected cloudflaredHostnameChanged")
        } catch ShareError.cloudflaredHostnameChanged(_, let recorded, let requested) {
            XCTAssertEqual(recorded, host)
            XCTAssertEqual(requested, "other.example.com")
        }
        XCTAssertEqual(calls(), [])
        XCTAssertEqual(t.records().first?.hostname, host)
    }

    func testRegistryWriteFailureSurfaces() async throws {
        let locked = dir.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
        let exe = try tunnels()
        _ = exe
        let t = CloudflaredTunnels(executable: dir.appendingPathComponent("cloudflared"),
                                   registryFile: locked.appendingPathComponent("sub/share-cloudflare.json"))
        do {
            try await t.ensure(instanceID: id, tunnelName: tunnel, hostname: host)
            XCTFail("expected cloudflaredRegistryWriteFailed")
        } catch ShareError.cloudflaredRegistryWriteFailed {}
    }

    func testExistingTunnelNameMentionsDeleteCommand() async throws {
        let t = try tunnels(["create": (1, "tunnel with name wpc-my-site already exists")])
        do {
            try await t.ensure(instanceID: id, tunnelName: tunnel, hostname: host)
            XCTFail("expected cloudflaredFailed")
        } catch ShareError.cloudflaredFailed(_, let output) {
            XCTAssertTrue(output.contains("cloudflared tunnel delete wpc-my-site"))
        }
    }

    func testMissingOrCorruptRegistryReadsEmpty() throws {
        let t = try tunnels()
        XCTAssertEqual(t.records(), [])
        try "not json".write(to: registry, atomically: true, encoding: .utf8)
        XCTAssertEqual(t.records(), [])
    }

    func testTunnelNameForSlug() {
        XCTAssertEqual(CloudflaredTunnels.tunnelName(for: "my-site"), "wpc-my-site")
    }
}
