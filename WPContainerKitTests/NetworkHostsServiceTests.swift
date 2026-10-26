import XCTest
@testable import WPContainerKit

/// Covers multisite subsite hosts: which hostnames are read from `wp site
/// list`, and how they reach the hosts block, proxy routes, certificate SANs
/// and in-container loopback hosts.
final class NetworkHostsServiceTests: XCTestCase {

    private func site(slug: String = "net", port: Int = 8900, domain: String? = "net.test",
                      networkType: NetworkType = .subdomain, networkHosts: [String] = []) -> Site {
        Site(name: slug, slug: slug, path: URL(fileURLWithPath: "/tmp/\(slug)"), port: port,
             imageTag: "wordpress:latest", customDomain: domain, networkType: networkType,
             networkHosts: networkHosts)
    }

    // MARK: - Reading `wp site list`

    func testSubdomainAndMappedSubsitesAreReadExcludingTheSiteItself() {
        let json = """
        [{"blog_id":1,"url":"https://net.test/"},
         {"blog_id":2,"url":"https://Blog.net.test/"},
         {"blog_id":3,"url":"https://other.test/"},
         {"blog_id":4,"url":"https://blog.net.test/"}]
        """
        XCTAssertEqual(NetworkHostsService.hosts(fromSiteList: json, for: site()),
                       ["blog.net.test", "other.test"])
    }

    func testSubdirectorySubsitesAddNoHosts() {
        let urls = ["https://net.test/", "https://net.test/shop/"]
        XCTAssertEqual(NetworkHostsService.hosts(fromURLs: urls, for: site(networkType: .subdirectory)), [])
    }

    func testPortAndAddressURLsAreSkipped() {
        let urls = ["http://localhost:8900/", "http://127.0.0.1:8900/sub/", "http://[::1]:8900/"]
        XCTAssertEqual(NetworkHostsService.hosts(fromURLs: urls, for: site(domain: nil)), [])
    }

    func testLocalhostSubsitesAreReadForASiteWithoutCustomDomain() {
        let urls = ["https://net.localhost/", "https://blog.net.localhost/"]
        XCTAssertEqual(NetworkHostsService.hosts(fromURLs: urls, for: site(domain: nil)), ["blog.net.localhost"])
    }

    func testMalformedOutputReadsAsUnknown() {
        XCTAssertNil(NetworkHostsService.hosts(fromSiteList: "Error: not a multisite", for: site()))
    }

    // MARK: - Hosts block

    func testHostsFileDomainsLeaveOutLocalhostNames() {
        let s = site(networkHosts: ["blog.net.test", "blog.net.localhost", "other.test"])
        XCTAssertEqual(s.hostsFileDomains, ["net.test", "blog.net.test", "other.test"])
    }

    func testHostsBlockDomainsCoverEverySiteOnce() {
        let a = site(networkHosts: ["blog.net.test"])
        let b = site(slug: "plain", port: 8901, domain: "plain.test", networkType: .none)
        let c = site(slug: "bare", port: 8902, domain: nil, networkType: .none)
        XCTAssertEqual(HostsFileService.domains(for: [a, b, c, a]), ["net.test", "blog.net.test", "plain.test"])
    }

    func testNewSubsiteIsMissingFromAnExistingBlock() {
        let contents = HostsFileService.rewrite("127.0.0.1\tlocalhost\n", domains: ["net.test"])
        let s = site(networkHosts: ["blog.net.test"])
        XCTAssertEqual(HostsFileService.missingDomains(s.hostsFileDomains, in: contents), ["blog.net.test"])
    }

    func testSingleSiteDomainListedOnlyOutsideTheBlockIsMissing() {
        let contents = """
        127.0.0.1\tlocalhost

        # wp-container begin
        127.0.0.1\tnet.test
        ::1\tnet.test
        # wp-container end

        ## Other Tool - Start ##
        127.0.0.1 plain.test #Other Tool
        ::1 plain.test #Other Tool
        ## Other Tool - End ##
        """
        let plain = site(slug: "plain", port: 8901, domain: "plain.test", networkType: .none)
        XCTAssertEqual(HostsFileService.missingDomains(plain.hostsFileDomains, in: contents), ["plain.test"])
    }

    func testSingleSiteWithoutCustomDomainNeedsNoEntry() {
        let bare = site(slug: "bare", port: 8902, domain: nil, networkType: .none)
        XCTAssertEqual(HostsFileService.missingDomains(bare.hostsFileDomains, in: ""), [])
    }

    // MARK: - Proxy, certificate and loopback

    func testMappedSubsiteRoutesToItsNetwork() {
        let envelope = StoreEnvelope(sites: [site(networkHosts: ["other.test"])], envs: [])
        XCTAssertEqual(HTTPSProxy.routes(from: envelope)["other.test"]?.port, 8900)
    }

    func testSubsiteHostNeverTakesOverAnotherSitesDomain() {
        let network = site(networkHosts: ["plain.test"])
        let plain = site(slug: "plain", port: 8901, domain: "plain.test", networkType: .none)
        let envelope = StoreEnvelope(sites: [network, plain], envs: [])
        XCTAssertEqual(HTTPSProxy.routes(from: envelope)["plain.test"]?.port, 8901)
    }

    func testSubsiteHostsReachCertificateAndLoopbackHosts() {
        let s = site(networkHosts: ["blog.net.test", "other.test"])
        XCTAssertTrue(s.proxyHosts.contains("other.test"))
        XCTAssertEqual(s.loopbackHosts, ["net.localhost", "net.test", "blog.net.test", "other.test"])
    }

    func testStoresWithoutNetworkHostsDecodeEmpty() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"net","slug":"net","path":"file:///tmp/net","port":8900,
         "imageTag":"wordpress:latest","createdAt":0}
        """
        let decoded = try JSONDecoder().decode(Site.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.networkHosts, [])
    }
}
