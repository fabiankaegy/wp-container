import XCTest
@testable import WPContainerKit

final class ShareStatusReportTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("share-status-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func status(slug: String, state: ShareStatus.State) -> ShareStatus {
        ShareStatus(instanceID: UUID(), slug: slug, state: state,
                    url: state == .live ? "https://\(slug).example.com" : nil,
                    provider: "ngrok", hostname: "\(slug).example.com", temporary: false,
                    listenerPort: 9100, pid: 4242, providerExecutable: "/usr/local/bin/ngrok",
                    error: state == .down ? "tunnel exited" : nil,
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testSharesRoundTrip() {
        let file = dir.appendingPathComponent("proxy-shares.json")
        let written = [status(slug: "my-site", state: .live), status(slug: "other-site", state: .down)]
        ProxyControl.writeShares(written, file: file)
        XCTAssertEqual(ProxyControl.shares(file: file), written)
        ProxyControl.clearShares(file: file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testMissingFileReadsEmpty() {
        let file = dir.appendingPathComponent("missing.json")
        XCTAssertEqual(ProxyControl.shares(file: file), [])
    }

    func testStaleProxyClearsShares() throws {
        let pid = dir.appendingPathComponent("proxy.pid")
        let port = dir.appendingPathComponent("proxy.port")
        let shares = dir.appendingPathComponent("proxy-shares.json")
        // Bind then release an ephemeral port so nothing listens on it.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        let freePort = UInt16(bigEndian: addr.sin_port)
        close(fd)

        try "99999".write(to: pid, atomically: true, encoding: .utf8)
        try String(freePort).write(to: port, atomically: true, encoding: .utf8)
        ProxyControl.writeShares([status(slug: "my-site", state: .live)], file: shares)

        XCTAssertNil(ProxyControl.current(pidFile: pid, portFile: port, sharesFile: shares))
        XCTAssertFalse(FileManager.default.fileExists(atPath: shares.path))
    }
}
