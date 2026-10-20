import Darwin
import Network
import XCTest
@testable import WPContainerKit

/// Share listeners on real loopback sockets: a client talks to the proxy's share
/// listener, which relays to a fake upstream bound on `127.0.0.1`.
final class HTTPSProxyShareTests: XCTestCase {

    private var tempRoot: URL!
    private var proxy: HTTPSProxy!
    private var upstream: FakeUpstream!

    override func setUp() async throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("HTTPSProxyShareTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        proxy = HTTPSProxy(ca: CertificateAuthority(directory: tempRoot.appendingPathComponent("ca")),
                           persistence: StorePersistence(fileURL: tempRoot.appendingPathComponent("sites.json")))
        upstream = try await FakeUpstream.start()
    }

    override func tearDown() async throws {
        proxy.stop()
        upstream.stop()
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func config(publicOrigin: String = "https://abc.example.com") -> ShareGateConfig {
        ShareGateConfig(publicOrigin: publicOrigin,
                        upstreamHost: "my-site.localhost",
                        localOrigins: ["http://my-site.localhost", "https://my-site.localhost"],
                        username: "share",
                        password: "example-password",
                        authDisabled: false,
                        allow: [])
    }

    private var route: HTTPSProxy.Route {
        HTTPSProxy.Route(port: Int(upstream.port), slug: "my-site", containerName: nil)
    }

    private static let credentials = Data("share:example-password".utf8).base64EncodedString()

    // MARK: - Gate

    func testShareListenerChallengesWithoutCredentials() async throws {
        let port = try await proxy.openShareListener(instanceID: UUID(), route: route, config: config())

        let response = try await LoopbackClient.exchange(
            port: port, request: "GET / HTTP/1.1\r\nHost: abc.example.com\r\n\r\n")

        XCTAssertTrue(response.hasPrefix("HTTP/1.1 401"), response)
        XCTAssertTrue(response.contains("WWW-Authenticate: Basic"), response)
        XCTAssertEqual(upstream.connectionCount, 0)
    }

    func testShareListenerRelaysWithRewrittenHeaders() async throws {
        let port = try await proxy.openShareListener(instanceID: UUID(), route: route, config: config())

        _ = try await LoopbackClient.exchange(port: port, request: """
            GET /wp-admin/ HTTP/1.1\r
            Host: abc.example.com\r
            Authorization: Basic \(Self.credentials)\r
            X-WPC-Share-Origin: https://forged.example.com\r
            \r

            """)

        let header = try XCTUnwrap(upstream.lastRequestHeader)
        let lines = header.components(separatedBy: "\r\n")
        XCTAssertTrue(lines.contains("Host: my-site.localhost"), header)
        XCTAssertTrue(lines.contains("X-WPC-Share-Origin: https://abc.example.com"), header)
        XCTAssertFalse(header.contains("forged.example.com"), header)
        XCTAssertFalse(header.lowercased().contains("authorization:"), header)
    }

    func testShareListenerRewritesResponseLocationAndAddsRobots() async throws {
        let port = try await proxy.openShareListener(instanceID: UUID(), route: route, config: config())

        let response = try await LoopbackClient.exchange(port: port, request: """
            GET /wp-admin HTTP/1.1\r
            Host: abc.example.com\r
            Authorization: Basic \(Self.credentials)\r
            \r

            """)

        let lines = response.components(separatedBy: "\r\n")
        XCTAssertTrue(lines.contains("Location: https://abc.example.com/wp-admin/"), response)
        XCTAssertTrue(lines.contains("X-Robots-Tag: noindex, nofollow"), response)
        // The body is the upstream's echo of the request header, relayed intact.
        XCTAssertTrue(response.hasSuffix("Connection: close"), response)
    }

    func testInterimResponseIsForwardedBeforeTheRewrittenFinalHeader() async throws {
        upstream.sendsContinueFirst = true
        let port = try await proxy.openShareListener(instanceID: UUID(), route: route, config: config())

        let response = try await LoopbackClient.exchange(port: port, request: """
            GET /wp-admin HTTP/1.1\r
            Host: abc.example.com\r
            Authorization: Basic \(Self.credentials)\r
            \r

            """)

        XCTAssertTrue(response.hasPrefix("HTTP/1.1 100 Continue\r\n"), response)
        XCTAssertTrue(response.contains("\r\nLocation: https://abc.example.com/wp-admin/\r\n"), response)
    }

    func testUpdatedShareConfigAppliesToNextRequest() async throws {
        let id = UUID()
        let port = try await proxy.openShareListener(instanceID: id, route: route,
                                                     config: config(publicOrigin: "https://pending.example.com"))
        proxy.updateShareConfig(instanceID: id, config: config(publicOrigin: "https://live.example.com"))

        let response = try await LoopbackClient.exchange(port: port, request: """
            GET /wp-admin HTTP/1.1\r
            Host: live.example.com\r
            Authorization: Basic \(Self.credentials)\r
            \r

            """)

        XCTAssertTrue(response.contains("Location: https://live.example.com/wp-admin/"), response)
    }

    func testShareConfigWithLineBreakIsRejected() async {
        do {
            _ = try await proxy.openShareListener(instanceID: UUID(), route: route,
                                                  config: config(publicOrigin: "https://abc.example.com\r\nX-Evil: 1"))
            XCTFail("expected the config to be rejected")
        } catch {}
    }

    func testShareConfigUpdateWithLineBreakIsIgnored() async throws {
        let id = UUID()
        let port = try await proxy.openShareListener(instanceID: id, route: route, config: config())
        proxy.updateShareConfig(instanceID: id, config: config(publicOrigin: "https://abc.example.com\nX-Evil: 1"))

        _ = try await LoopbackClient.exchange(port: port, request: """
            GET / HTTP/1.1\r
            Host: abc.example.com\r
            Authorization: Basic \(Self.credentials)\r
            \r

            """)

        let header = try XCTUnwrap(upstream.lastRequestHeader)
        XCTAssertFalse(header.contains("X-Evil"), header)
        XCTAssertTrue(header.contains("X-WPC-Share-Origin: https://abc.example.com"), header)
    }

    // MARK: - Regular listeners

    func testForgedShareHeaderStrippedOnRegularListener() {
        let rewritten = HTTPSProxy.rewriteHeaders(requestLine: "GET / HTTP/1.1",
                                                  lines: ["Host: my-site.localhost",
                                                          "X-WPC-Share-Origin: https://forged.example.com",
                                                          "x-wpc-share-anything: 1",
                                                          "Accept: */*"],
                                                  host: "my-site.localhost", proto: "https")

        XCTAssertFalse(rewritten.lowercased().contains("x-wpc-share-"), rewritten)
        XCTAssertTrue(rewritten.contains("Accept: */*"), rewritten)
    }

    // MARK: - Lifecycle

    func testClosedShareListenerRefusesConnections() async throws {
        let id = UUID()
        let port = try await proxy.openShareListener(instanceID: id, route: route, config: config())
        XCTAssertTrue(LoopbackClient.accepts(port: port))

        proxy.closeShareListener(instanceID: id)

        let refused = await LoopbackClient.waitUntilRefused(port: port, timeout: 2)
        XCTAssertTrue(refused)
    }

    func testRouteForInstanceUsesUpstreamHost() {
        let site = Site(name: "My Site", slug: "my-site", path: URL(fileURLWithPath: "/tmp/my-site"),
                        port: 8101, imageTag: "wordpress:6.8", httpsEnabled: true)
        let routes = ["my-site.localhost": HTTPSProxy.Route(port: 8101, slug: "my-site")]

        XCTAssertEqual(HTTPSProxy.route(for: site, in: routes)?.slug, "my-site")
    }

    func testRouteForLoopbackInstanceMatchesByPort() {
        let site = Site(name: "My Site", slug: "my-site", path: URL(fileURLWithPath: "/tmp/my-site"),
                        port: 8101, imageTag: "wordpress:6.8")
        let routes = ["my-site.localhost": HTTPSProxy.Route(port: 8101, slug: "my-site"),
                      "my-site-mail.localhost": HTTPSProxy.Route(port: 8102, slug: "my-site", isMailbox: true)]

        let found = HTTPSProxy.route(for: site, in: routes)

        XCTAssertEqual(found?.port, 8101)
        XCTAssertEqual(found?.isMailbox, false)
    }
}

// MARK: - Helpers

/// Minimal HTTP upstream on `127.0.0.1`: records each request header and answers
/// a 302 to `http://my-site.localhost/wp-admin/` whose body echoes that header.
private final class FakeUpstream: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-upstream")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var headers: [String] = []
    private var continueFirst = false
    let port: UInt16

    /// Whether a `100 Continue` interim response is sent, in its own write, ahead of the 302.
    var sendsContinueFirst: Bool {
        get { lock.withLock { continueFirst } }
        set { lock.withLock { continueFirst = newValue } }
    }

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        self.port = port
    }

    var connectionCount: Int { lock.withLock { connections.count } }
    var lastRequestHeader: String? { lock.withLock { headers.last } }

    static func start() async throws -> FakeUpstream {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: params)
        let queue = DispatchQueue(label: "fake-upstream.listener")
        let port: UInt16 = try await withCheckedThrowingContinuation { cont in
            let once = OnceFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { cont.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    if once.claim() { cont.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { _ in }
            listener.start(queue: queue)
        }
        let upstream = FakeUpstream(listener: listener, port: port)
        listener.newConnectionHandler = { [weak upstream] connection in upstream?.accept(connection) }
        return upstream
    }

    func stop() {
        listener.cancel()
        lock.withLock { connections }.forEach { $0.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        lock.withLock { connections.append(connection) }
        connection.start(queue: queue)
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let header = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                self.lock.withLock { self.headers.append(header) }
                let body = Data(header.utf8)
                let head = "HTTP/1.1 302 Found\r\nLocation: http://my-site.localhost/wp-admin/\r\n"
                    + "Content-Type: text/plain\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                var response = Data(head.utf8)
                response.append(body)
                if self.sendsContinueFirst {
                    connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .idempotent)
                }
                connection.send(content: response, contentContext: .finalMessage, isComplete: true,
                                completion: .idempotent)
                return
            }
            if isComplete || error != nil { connection.cancel(); return }
            self.read(connection, buffer: buffer)
        }
    }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.withLock {
            if claimed { return false }
            claimed = true
            return true
        }
    }
}

/// Blocking POSIX client for `127.0.0.1`, run off the cooperative pool.
private enum LoopbackClient {
    enum ClientError: Error { case connect(Int32), io(Int32) }

    /// Sends `request`, half-closes, and reads until the peer closes (5s cap).
    static func exchange(port: UInt16, request: String) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                do { cont.resume(returning: try exchangeBlocking(port: port, request: request)) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    static func accepts(port: UInt16) -> Bool {
        let fd = connectSocket(port: port)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    static func waitUntilRefused(port: UInt16, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !accepts(port: port) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    private static func connectSocket(port: UInt16) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { close(fd); return -1 }
        return fd
    }

    private static func exchangeBlocking(port: UInt16, request: String) throws -> String {
        let fd = connectSocket(port: port)
        guard fd >= 0 else { throw ClientError.connect(errno) }
        defer { close(fd) }
        let bytes = Array(request.utf8)
        var sent = 0
        while sent < bytes.count {
            let n = bytes[sent...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            guard n > 0 else { throw ClientError.io(errno) }
            sent += n
        }
        var received = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n == 0 { break }
            guard n > 0 else { throw ClientError.io(errno) }
            received.append(contentsOf: chunk[0..<n])
        }
        return String(decoding: received, as: UTF8.self)
    }
}
