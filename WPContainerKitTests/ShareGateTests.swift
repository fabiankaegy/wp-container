import XCTest
@testable import WPContainerKit

final class ShareGateTests: XCTestCase {

    private func config(authDisabled: Bool = false, allow: [String] = []) throws -> ShareGateConfig {
        ShareGateConfig(
            publicOrigin: "https://abc.example.com",
            upstreamHost: "my-site.localhost",
            localOrigins: ["http://my-site.localhost", "https://my-site.localhost"],
            username: "share",
            password: "pw",
            authDisabled: authDisabled,
            allow: try allow.map { try ShareException(parsing: $0) }
        )
    }

    private func basic(_ credentials: String) -> String {
        "Authorization: Basic " + Data(credentials.utf8).base64EncodedString()
    }

    func testMissingCredentialsChallenge() throws {
        let decision = ShareGate.authorize(requestLine: "GET / HTTP/1.1", headerLines: ["Host: abc.example.com"], config: try config())
        XCTAssertEqual(decision, .challenge)
        let response = ShareGate.challengeResponse()
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 401"))
        XCTAssertTrue(response.contains("WWW-Authenticate: Basic realm=\"WP Container share\""))
        XCTAssertTrue(response.contains("Connection: close"))
    }

    func testThrottledResponse() {
        let response = ShareGate.throttledResponse()
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 429"))
        XCTAssertTrue(response.contains("Connection: close"))
    }

    func testCorrectCredentialsPass() throws {
        let decision = ShareGate.authorize(requestLine: "GET / HTTP/1.1", headerLines: [basic("share:pw")], config: try config())
        XCTAssertEqual(decision, .pass)
    }

    func testWrongPasswordChallenges() throws {
        let decision = ShareGate.authorize(requestLine: "GET / HTTP/1.1", headerLines: [basic("share:nope")], config: try config())
        XCTAssertEqual(decision, .challenge)
    }

    func testAuthDisabledPasses() throws {
        let decision = ShareGate.authorize(requestLine: "GET / HTTP/1.1", headerLines: [], config: try config(authDisabled: true))
        XCTAssertEqual(decision, .pass)
    }

    func testExceptionSkipsAuth() throws {
        let decision = ShareGate.authorize(requestLine: "POST /?wc-api=wc_stripe HTTP/1.1", headerLines: [], config: try config(allow: ["?wc-api"]))
        XCTAssertEqual(decision, .pass)
    }

    func testRequestRewriteSetsHostAndShareHeaders() throws {
        let out = ShareGate.rewriteRequest(requestLine: "GET / HTTP/1.1", headerLines: ["Host: abc.example.com", "Connection: keep-alive"], config: try config())
        XCTAssertTrue(out.hasPrefix("GET / HTTP/1.1\r\n"))
        XCTAssertTrue(out.hasSuffix("\r\n\r\n"))
        XCTAssertTrue(out.contains("Host: my-site.localhost\r\n"))
        XCTAssertFalse(out.contains("\r\nHost: abc.example.com"))
        XCTAssertTrue(out.contains("X-Forwarded-Host: abc.example.com\r\n"))
        XCTAssertTrue(out.contains("X-Forwarded-Proto: https\r\n"))
        XCTAssertTrue(out.contains("X-WPC-Share-Origin: https://abc.example.com\r\n"))
        XCTAssertTrue(out.contains("Connection: close\r\n"))
        XCTAssertFalse(out.contains("keep-alive"))
    }

    func testRequestRewriteDropsAuthorizationAndForgedShareHeaders() throws {
        let out = ShareGate.rewriteRequest(
            requestLine: "GET / HTTP/1.1",
            headerLines: ["Host: x", basic("share:pw"), "X-WPC-Share-Origin: https://evil", "x-wpc-share-other: 1"],
            config: try config()
        )
        XCTAssertFalse(out.lowercased().contains("authorization:"))
        XCTAssertFalse(out.contains("evil"))
        XCTAssertFalse(out.lowercased().contains("x-wpc-share-other"))
        XCTAssertEqual(out.components(separatedBy: "X-WPC-Share-Origin:").count - 1, 1)
    }

    func testStripShareHeaders() {
        let kept = ShareGate.stripShareHeaders(["Host: a", "X-WPC-Share-Origin: b", "x-wpc-share-y: c", "Accept: */*"])
        XCTAssertEqual(kept, ["Host: a", "Accept: */*"])
    }

    func testResponseHeadersRewriteLocalLocationToPublicOrigin() throws {
        let header = "HTTP/1.1 302 Found\r\nLocation: http://my-site.localhost/wp-admin/\r\nContent-Length: 0\r\n\r\n"
        let out = ShareGate.rewriteResponseHeader(header, config: try config())
        XCTAssertTrue(out.contains("Location: https://abc.example.com/wp-admin/\r\n"))
        XCTAssertTrue(out.hasSuffix("\r\n\r\n"))
    }

    func testResponseHeadersRewriteLinkHeaderAndAddRobots() throws {
        let header = "HTTP/1.1 200 OK\r\nLink: <https://my-site.localhost/wp-json/>; rel=\"https://api.w.org/\"\r\nX-Robots-Tag: all\r\n\r\n"
        let out = ShareGate.rewriteResponseHeader(header, config: try config())
        XCTAssertTrue(out.contains("Link: <https://abc.example.com/wp-json/>; rel=\"https://api.w.org/\"\r\n"))
        XCTAssertEqual(out.components(separatedBy: "X-Robots-Tag: noindex, nofollow").count - 1, 1)
        XCTAssertFalse(out.contains("X-Robots-Tag: all"))
    }

    func testThrottleLocksAfterTenFailures() {
        let throttle = ShareAuthThrottle()
        let start = Date(timeIntervalSince1970: 1_000)
        for i in 0..<9 { throttle.recordFailure(now: start.addingTimeInterval(Double(i))) }
        XCTAssertFalse(throttle.isLocked(now: start.addingTimeInterval(9)))
        throttle.recordFailure(now: start.addingTimeInterval(9))
        XCTAssertTrue(throttle.isLocked(now: start.addingTimeInterval(10)))
        XCTAssertFalse(throttle.isLocked(now: start.addingTimeInterval(40)))
    }

    func testThrottleIgnoresSlowFailures() {
        let throttle = ShareAuthThrottle()
        let start = Date(timeIntervalSince1970: 1_000)
        for i in 0..<20 { throttle.recordFailure(now: start.addingTimeInterval(Double(i) * 7)) }
        XCTAssertFalse(throttle.isLocked(now: start.addingTimeInterval(140)))
    }
}
