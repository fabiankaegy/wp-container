import XCTest
@testable import WPContainerKit

/// The owned loopback zone (PLAN.md §2f-ter): the DNS responder's wire format,
/// per-site host selection, routing aliases, the legacy-redirect predicate and
/// zone-addressed hosts entries. Pure logic only — nothing privileged runs.
final class LoopbackZoneTests: XCTestCase {

    // MARK: - DNS responder

    /// A standard query for `name`/`qtype` with RD set and an EDNS OPT record,
    /// like mDNSResponder sends.
    private func query(_ name: String, type qtype: UInt16, id: UInt16 = 0xBEEF) -> [UInt8] {
        var q: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF), 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 1]
        for label in name.split(separator: ".") {
            q.append(UInt8(label.utf8.count))
            q += Array(label.utf8)
        }
        q += [0, UInt8(qtype >> 8), UInt8(qtype & 0xFF), 0, 1]
        q += [0, 0, 41, 0x10, 0, 0, 0, 0, 0, 0, 0] // OPT
        return q
    }

    private func rcode(_ r: [UInt8]) -> UInt8 { r[3] & 0x0F }
    private func answerCount(_ r: [UInt8]) -> Int { Int(r[6]) << 8 | Int(r[7]) }

    func testAnswersARecordForAnyNameInTheZone() throws {
        for name in ["my-blog.wpc.test", "sub.my-blog.wpc.test", "MY-BLOG.WPC.TEST", "wpc.test"] {
            let r = try XCTUnwrap(LoopbackZoneDNS.response(to: query(name, type: 1)))
            XCTAssertEqual(Array(r[0...1]), [0xBE, 0xEF], name)
            XCTAssertEqual(r[2] & 0x80, 0x80, "QR")
            XCTAssertEqual(r[2] & 0x04, 0x04, "AA")
            XCTAssertEqual(r[2] & 0x01, 0x01, "RD echoed")
            XCTAssertEqual(rcode(r), 0)
            XCTAssertEqual(answerCount(r), 1)
            XCTAssertEqual(Array(r.suffix(4)), [127, 0, 0, 77], name)
        }
    }

    func testAnswersAAAAWithTheIPv6Alias() throws {
        let r = try XCTUnwrap(LoopbackZoneDNS.response(to: query("my-blog.wpc.test", type: 28)))
        XCTAssertEqual(answerCount(r), 1)
        var expected = in6_addr()
        inet_pton(AF_INET6, LoopbackZone.ipv6, &expected)
        XCTAssertEqual(Array(r.suffix(16)), withUnsafeBytes(of: &expected) { Array($0) })
    }

    func testOtherTypesInTheZoneAreNoData() throws {
        let r = try XCTUnwrap(LoopbackZoneDNS.response(to: query("my-blog.wpc.test", type: 15))) // MX
        XCTAssertEqual(rcode(r), 0)
        XCTAssertEqual(answerCount(r), 0)
    }

    func testRefusesNamesOutsideTheZone() throws {
        for name in ["example.com", "evilwpc.test", "wpc.test.example.com"] {
            let r = try XCTUnwrap(LoopbackZoneDNS.response(to: query(name, type: 1)))
            XCTAssertEqual(rcode(r), 5, name)
            XCTAssertEqual(answerCount(r), 0, name)
        }
    }

    func testDropsMalformedQueries() {
        XCTAssertNil(LoopbackZoneDNS.response(to: []))
        XCTAssertNil(LoopbackZoneDNS.response(to: Array(query("a.wpc.test", type: 1).prefix(15))))
        var response = query("a.wpc.test", type: 1)
        response[2] |= 0x80 // a response, not a query
        XCTAssertNil(LoopbackZoneDNS.response(to: response))
        var twoQuestions = query("a.wpc.test", type: 1)
        twoQuestions[5] = 2
        XCTAssertNil(LoopbackZoneDNS.response(to: twoQuestions))
    }

    // MARK: - Site hosts

    private func site(_ slug: String, zone: Bool, https: Bool = true, domain: String? = nil,
                      network: NetworkType = .none, mailpit: Bool = false) -> Site {
        Site(name: slug, slug: slug, path: URL(fileURLWithPath: "/tmp/\(slug)"), port: 8881,
             imageTag: "wordpress:6.8", httpsEnabled: https, mailpitEnabled: mailpit,
             mailpitPort: mailpit ? 8025 : nil, customDomain: domain, usesLoopbackZone: zone,
             networkType: network)
    }

    func testDefaultHostFollowsTheSitesZoneFlag() {
        XCTAssertEqual(site("blog", zone: true).defaultHost, "blog.wpc.test")
        XCTAssertEqual(site("blog", zone: true).url.absoluteString, "https://blog.wpc.test")
        XCTAssertEqual(site("blog", zone: false).defaultHost, "blog.localhost")
        XCTAssertEqual(site("blog", zone: false).url.absoluteString, "https://blog.localhost")
        XCTAssertEqual(site("blog", zone: true, network: .subdomain).proxyHosts, ["blog.wpc.test", "*.blog.wpc.test"])
        XCTAssertEqual(site("blog", zone: true, domain: "blog.local").loopbackHosts, ["blog.wpc.test", "blog.local"])
    }

    func testStoresWrittenBeforeTheZoneDecodeAsLegacy() throws {
        let encoded = try JSONEncoder().encode(site("blog", zone: true))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(json["usesLoopbackZone"] as? Bool, true)
        json.removeValue(forKey: "usesLoopbackZone")
        let old = try JSONDecoder().decode(Site.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(old.usesLoopbackZone)
        XCTAssertEqual(old.defaultHost, "blog.localhost")
    }

    // MARK: - Proxy routing

    func testZoneSitesAlsoRouteTheirLegacyAlias() {
        let routes = HTTPSProxy.routes(from: StoreEnvelope(sites: [site("blog", zone: true, mailpit: true)], envs: []))
        XCTAssertEqual(routes["blog.wpc.test"]?.slug, "blog")
        XCTAssertEqual(routes["blog.localhost"]?.slug, "blog")
        XCTAssertEqual(routes["blog-mail.wpc.test"]?.isMailbox, true)
        XCTAssertEqual(routes["blog-mail.localhost"]?.isMailbox, true)
        XCTAssertTrue(HTTPSProxy.sanHosts(from: StoreEnvelope(sites: [site("blog", zone: true, mailpit: true)], envs: []))
            .contains("blog-mail.wpc.test"))
    }

    func testLegacyRedirectOnlyWhileALocalhostURLIsAdvertised() {
        func needs(_ sites: [Site]) -> Bool { HTTPSProxy.needsLegacyLoopback(StoreEnvelope(sites: sites, envs: [])) }
        XCTAssertFalse(needs([]))
        XCTAssertFalse(needs([site("a", zone: true)]))
        XCTAssertTrue(needs([site("a", zone: true), site("b", zone: false)]))
        // Not advertised at a .localhost name: plain-HTTP sites use 127.0.0.1:<port>,
        // custom-domain sites their domain.
        XCTAssertFalse(needs([site("b", zone: false, https: false)]))
        XCTAssertFalse(needs([site("b", zone: false, domain: "b.local")]))
    }

    // MARK: - Hosts entries

    func testZoneHostsEntriesPointAtTheAliases() {
        let out = HostsFileService.rewrite("127.0.0.1\tlocalhost\n", domains: ["a.local"], zone: true)
        XCTAssertTrue(out.hasSuffix("# wp-container begin\n127.0.0.77\ta.local\nfd77:7063::77\ta.local\n# wp-container end\n"))
        XCTAssertTrue(HostsFileService.isUpToDate(out, domains: ["a.local"], zone: true))
        XCTAssertFalse(HostsFileService.isUpToDate(out, domains: ["a.local"], zone: false))
    }

    func testCorruptedBlocksOfEitherFormatAreCleanedUp() {
        for stale in ["127.0.0.1\tstale.local\n::1\tstale.local\n", "127.0.0.77\tstale.local\nfd77:7063::77\tstale.local\n"] {
            let corrupted = "127.0.0.1\tlocalhost\n\n# wp-container begin\n" + stale
            let out = HostsFileService.rewrite(corrupted, domains: ["fresh.local"], zone: true)
            XCTAssertFalse(out.contains("stale.local"))
            XCTAssertEqual(HostsFileService.managedDomains(in: out), ["fresh.local"])
        }
    }

    // MARK: - Migration

    /// The rewrite must hit `blog.localhost` in urls, bare domain columns and
    /// subdomains — but never inside another site's `my-blog.localhost`.
    func testMigrationPatternMatchesOnlyTheSitesOwnHost() throws {
        let (pattern, target) = LoopbackZoneMigrator.replacement(slug: "blog")
        XCTAssertEqual(target, "blog.wpc.test")
        let re = try NSRegularExpression(pattern: pattern)
        func rewrite(_ s: String) -> String {
            re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: target)
        }
        XCTAssertEqual(rewrite("https://blog.localhost/wp-admin"), "https://blog.wpc.test/wp-admin")
        XCTAssertEqual(rewrite("blog.localhost"), "blog.wpc.test")
        XCTAssertEqual(rewrite("shop.blog.localhost"), "shop.blog.wpc.test")
        XCTAssertEqual(rewrite("https://my-blog.localhost"), "https://my-blog.localhost")
        XCTAssertEqual(rewrite("myblog.localhost"), "myblog.localhost")
        XCTAssertEqual(rewrite("blog.localhost.example.com"), "blog.localhost.example.com")
    }
}
