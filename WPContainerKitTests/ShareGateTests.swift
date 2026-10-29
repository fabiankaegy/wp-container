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
        let decision = ShareGate.authorize(requestLine: "POST /?wc-api=wc_stripe HTTP/1.1", headerLines: [], config: try config(allow: ["?wc-api=wc_stripe"]))
        XCTAssertEqual(decision, .exempt)
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

    func testResponseHeadersDropXPingback() throws {
        let header = "HTTP/1.1 200 OK\r\nX-Pingback: http://my-site.localhost/xmlrpc.php\r\nContent-Length: 0\r\n\r\n"
        let out = ShareGate.rewriteResponseHeader(header, config: try config())
        XCTAssertFalse(out.lowercased().contains("x-pingback"))
        XCTAssertTrue(out.contains("Content-Length: 0\r\n"))
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

    private func decide(_ requestLine: String, _ headers: [String] = [], allow: [String] = []) throws -> ShareGateDecision {
        ShareGate.authorize(requestLine: requestLine, headerLines: headers, config: try config(allow: allow))
    }

    func testPathExceptionRefusesRestRouteOverride() throws {
        XCTAssertEqual(try decide("GET /wp-json/wc/?rest_route=/wp/v2/posts HTTP/1.1", allow: ["/wp-json/wc/"]), .challenge)
        XCTAssertEqual(try decide("GET /wp-json/wc/?a=1&rest%5Froute=/wp/v2/posts HTTP/1.1", allow: ["/wp-json/wc/"]), .challenge)
        for key in ["rest.route", "rest%20route", "rest+route", "rest%2Eroute", "%20rest_route", "rest[route", "rest_route[x]", "rest_route%5Bx%5D", "rest_route%00", "rest_route%00x", "rest.route%00junk", "rest_route%00[x]"] {
            XCTAssertEqual(try decide("GET /wp-json/wc/?\(key)=/wp/v2/posts HTTP/1.1", allow: ["/wp-json/wc/"]), .challenge, key)
        }
        XCTAssertEqual(try decide("GET /wp-json/wc/?rest_route HTTP/1.1", allow: ["/wp-json/wc/"]), .challenge)
    }

    func testOtherQueryExceptionRefusesRestRouteOverride() throws {
        XCTAssertEqual(try decide("GET /wp-json/wc/?rest_route=/x&wc-api=hook HTTP/1.1", allow: ["/wp-json/wc/", "?wc-api=hook"]), .challenge)
        for key in ["rest_route", "rest.route", "rest%5Froute", "rest+route"] {
            let line = "GET /?wc-api=1&\(key)=/wp/v2/users HTTP/1.1"
            XCTAssertEqual(try decide(line, allow: ["?wc-api=1"]), .challenge, key)
        }
    }

    func testRestRouteExceptionCoversOnlyTheLiteralKey() throws {
        let allow = ["?rest_route=/stripe/v1/webhook"]
        XCTAssertEqual(try decide("GET /?rest_route=/stripe/v1/webhook HTTP/1.1", allow: allow), .exempt)
        XCTAssertEqual(try decide("GET /?rest_route=/wp/v2/users HTTP/1.1", allow: allow), .challenge)
        XCTAssertEqual(try decide("GET /?rest_route=/stripe/v1/webhook&rest.route=/wp/v2/users HTTP/1.1", allow: allow), .challenge)
        XCTAssertEqual(try decide("GET /?rest_route=/stripe/v1/webhook&rest_route=/wp/v2/users HTTP/1.1", allow: allow), .challenge)
        XCTAssertEqual(try decide("GET /wp-json/x/?rest_route=/stripe/v1/webhook HTTP/1.1", allow: ["/wp-json/x/"]), .challenge)
    }

    func testPathExceptionStillPassesWithoutRestRoute() throws {
        XCTAssertEqual(try decide("GET /wp-json/wc/v3/orders?x=rest_route HTTP/1.1", allow: ["/wp-json/wc/"]), .exempt)
        XCTAssertEqual(try decide("GET /?rest_route=/x HTTP/1.1", allow: ["?rest_route=/x"]), .exempt)
        XCTAssertEqual(try decide("GET /wp-json/wc/?Rest_Route=/x HTTP/1.1", allow: ["/wp-json/wc/"]), .exempt)
    }

    func testResponseHeaderOriginReplacementRespectsBoundaries() throws {
        let cfg = try config()
        let longer = "HTTP/1.1 302 Found\r\nLocation: http://my-site.localhost.example.org/\r\n\r\n"
        XCTAssertTrue(ShareGate.rewriteResponseHeader(longer, config: cfg).contains("Location: http://my-site.localhost.example.org/\r\n"))
        let port = "HTTP/1.1 302 Found\r\nLocation: http://my-site.localhost:8080/x\r\n\r\n"
        XCTAssertTrue(ShareGate.rewriteResponseHeader(port, config: cfg).contains("Location: http://my-site.localhost:8080/x\r\n"))
        let normal = "HTTP/1.1 302 Found\r\nLocation: http://my-site.localhost/a\r\n\r\n"
        XCTAssertTrue(ShareGate.rewriteResponseHeader(normal, config: cfg).contains("Location: https://abc.example.com/a\r\n"))
        let bare = "HTTP/1.1 302 Found\r\nLocation: http://my-site.localhost\r\n\r\n"
        XCTAssertTrue(ShareGate.rewriteResponseHeader(bare, config: cfg).contains("Location: https://abc.example.com\r\n"))
    }

    func testAuthorizeSecurityEdgeCases() throws {
        func header(_ credentials: String) -> [String] { [basic(credentials)] }
        XCTAssertEqual(try decide("GET / HTTP/1.1", ["authorization: basic " + Data("share:pw".utf8).base64EncodedString()]), .pass)
        XCTAssertEqual(try decide("GET / HTTP/1.1", ["Authorization: Basic !!!not-base64"]), .challenge)
        XCTAssertEqual(try decide("GET / HTTP/1.1", header("sharepw")), .challenge)
        XCTAssertEqual(try decide("GET / HTTP/1.1", header("other:pw")), .challenge)

        let colon = ShareGateConfig(publicOrigin: "https://abc.example.com", upstreamHost: "my-site.localhost",
                                    localOrigins: [], username: "share", password: "p:w:x", authDisabled: false, allow: [])
        XCTAssertEqual(ShareGate.authorize(requestLine: "GET / HTTP/1.1", headerLines: header("share:p:w:x"), config: colon), .pass)

        XCTAssertEqual(try decide("GET /wc-webhook/order HTTP/1.1", allow: ["/wc-webhook"]), .exempt)
        XCTAssertEqual(try decide("GET /wp-admin/ HTTP/1.1", allow: ["/wc-webhook"]), .challenge)
        XCTAssertEqual(try decide("GET /wc-webhook/../wp-admin/ HTTP/1.1", allow: ["/wc-webhook"]), .challenge)
        XCTAssertEqual(try decide("GET /?hook=a HTTP/1.1", allow: ["?hook=a"]), .exempt)
        XCTAssertEqual(try decide("GET /?hook=b HTTP/1.1", allow: ["?hook=a"]), .challenge)
    }

    func testValidCredentialsOnAnExceptionPass() throws {
        XCTAssertEqual(try decide("GET /?wc-api=1 HTTP/1.1", [basic("share:pw")], allow: ["?wc-api=1"]), .pass)
        XCTAssertEqual(try decide("GET /?wc-api=1 HTTP/1.1", [basic("share:nope")], allow: ["?wc-api=1"]), .exempt)
        XCTAssertEqual(try decide("GET /?wc-api=1 HTTP/1.1", allow: ["?wc-api=1"]), .exempt)
    }

    func testLoginAndXMLRPCAreNeverExempt() throws {
        let paths = [
            "/wp-login.php", "/xmlrpc.php", "/wp-login.php/", "/xmlrpc.php/x", "/WP-Login.PHP",
            "/%77p-login.php", "/xmlrpc%2Ephp", "//xmlrpc.php", "/sub/wp-login.php", "/wc/../wp-login.php",
            "http://abc.example.com/xmlrpc.php",
        ]
        for path in paths {
            XCTAssertEqual(try decide("POST \(path)?wc-api=1 HTTP/1.1", allow: ["/", "?wc-api=1"]), .challenge, path)
        }
        XCTAssertEqual(try decide("POST /wp-login.php HTTP/1.1", allow: ["/wp-login"]), .challenge)
        XCTAssertEqual(try decide("POST /xmlrpc.php HTTP/1.1", allow: ["/"]), .challenge)
        XCTAssertEqual(try decide("POST /wp-login.php?wc-api=1 HTTP/1.1", [basic("share:pw")], allow: ["?wc-api=1"]), .pass)
        XCTAssertEqual(try decide("GET /wp-login.phpx?wc-api=1 HTTP/1.1", allow: ["/wp-login.phpx?wc-api=1"]), .exempt)
    }

    func testExemptRequestLosesCookiesAndCarriesTheMarker() throws {
        let headers = ["Host: abc.example.com", "Cookie: wordpress_logged_in_x=secret", "Accept: */*",
                       "X-WPC-Share-Exempt: forged"]
        let exempt = ShareGate.rewriteRequest(requestLine: "POST /?wc-api=1 HTTP/1.1", headerLines: headers,
                                              config: try config(), exempt: true)
        XCTAssertFalse(exempt.lowercased().contains("cookie:"), exempt)
        XCTAssertFalse(exempt.contains("forged"), exempt)
        XCTAssertTrue(exempt.contains("\r\nX-WPC-Share-Exempt: 1\r\n"), exempt)
        XCTAssertTrue(exempt.contains("Accept: */*"), exempt)

        let passed = ShareGate.rewriteRequest(requestLine: "GET / HTTP/1.1", headerLines: headers, config: try config())
        XCTAssertTrue(passed.contains("Cookie: wordpress_logged_in_x=secret"), passed)
        XCTAssertFalse(passed.lowercased().contains("x-wpc-share-exempt"), passed)
    }

    func testExemptRequestNamesTheQueryExceptionKeysItMatched() throws {
        let cfg = try config(allow: ["/hooks", "?wc-api=1", "?other=2"])
        let query = ShareGate.rewriteRequest(requestLine: "POST /?wc-api=1&other=2 HTTP/1.1", headerLines: [],
                                             config: cfg, exempt: true)
        XCTAssertTrue(query.contains("\r\nX-WPC-Share-Exempt-Keys: wc-api,other\r\n"), query)

        let path = ShareGate.rewriteRequest(requestLine: "POST /hooks/stripe HTTP/1.1", headerLines: ["X-WPC-Share-Exempt-Keys: p"],
                                            config: cfg, exempt: true)
        XCTAssertTrue(path.contains("\r\nX-WPC-Share-Exempt: 1\r\n"), path)
        XCTAssertFalse(path.contains("Exempt-Keys"), path)
    }

    func testExemptMarkerIsStrippedOnRegularListeners() {
        let rewritten = HTTPSProxy.rewriteHeaders(requestLine: "GET / HTTP/1.1",
                                                  lines: ["Host: my-site.localhost", "X-WPC-Share-Exempt: 1"],
                                                  host: "my-site.localhost", proto: "https")
        XCTAssertFalse(rewritten.lowercased().contains("x-wpc-share-exempt"), rewritten)
    }

    func testShareDecisionLetsValidCredentialsThroughALock() throws {
        let cfg = try config(allow: ["?wc-api=1"])
        let throttle = ShareAuthThrottle()
        let now = Date()
        let bad = [basic("share:nope")]
        let good = [basic("share:pw")]
        func decide(_ line: String, _ headers: [String]) -> ShareGateDecision {
            HTTPSProxy.shareDecision(requestLine: line, headerLines: headers, config: cfg, throttle: throttle, now: now)
        }
        XCTAssertEqual(decide("GET /?wc-api=1 HTTP/1.1", []), .exempt)
        for _ in 0..<10 {
            XCTAssertEqual(decide("GET /?wc-api=1 HTTP/1.1", bad), .exempt)
        }
        XCTAssertTrue(throttle.isLocked(now: now))
        XCTAssertEqual(decide("GET / HTTP/1.1", good), .pass)
        XCTAssertEqual(decide("GET /?wc-api=1 HTTP/1.1", good), .pass)
        XCTAssertEqual(decide("GET / HTTP/1.1", bad), .throttled)
        XCTAssertEqual(decide("GET /?wc-api=1 HTTP/1.1", bad), .exempt)
        XCTAssertEqual(decide("GET / HTTP/1.1", []), .challenge)
    }
}
