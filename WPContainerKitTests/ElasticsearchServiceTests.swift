import XCTest
@testable import WPContainerKit

/// Coverage for how ElasticPress finds the Elasticsearch sidecar: the managed
/// prepend handler that defines `EP_HOST`, and the `EP_HOST` env var passed to
/// one-shot wp-cli containers.
final class ElasticsearchServiceTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wpc-es-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    // MARK: - URLs

    func testElasticsearchURLUsesPort9200() {
        XCTAssertEqual(SiteRecipe.elasticsearchURL(esHost: "10.0.0.5"), "http://10.0.0.5:9200")
    }

    func testHealthURLBuildsOnTheBaseURL() {
        XCTAssertEqual(SiteRecipe.elasticsearchHealthURL(esHost: "10.0.0.5"),
                       "http://10.0.0.5:9200/_cluster/health")
    }

    // MARK: - wp-cli env

    func testWPProxyArgsPassEPHostWhenGiven() {
        let args = SiteRecipe.wpProxyArgs(makeSite(), dbHost: "10.0.0.2", wpArgs: ["elasticpress", "sync"],
                                          elasticsearchURL: "http://10.0.0.5:9200")
        XCTAssertTrue(containsPair(args, "-e", "EP_HOST=http://10.0.0.5:9200"))
    }

    func testWPProxyArgsOmitEPHostByDefault() {
        let args = SiteRecipe.wpProxyArgs(makeSite(), dbHost: "10.0.0.2", wpArgs: ["option", "get", "home"])
        XCTAssertFalse(args.contains { $0.hasPrefix("EP_HOST=") })
    }

    func testEPHostComesBeforeTheImage() throws {
        let site = makeSite()
        let args = SiteRecipe.wpProxyArgs(site, dbHost: "10.0.0.2", wpArgs: ["elasticpress", "sync"],
                                          elasticsearchURL: "http://10.0.0.5:9200")
        let envIndex = try XCTUnwrap(args.firstIndex(of: "EP_HOST=http://10.0.0.5:9200"))
        let imageIndex = try XCTUnwrap(args.firstIndex(of: SiteRecipe.cliImage(for: site)))
        XCTAssertLessThan(envIndex, imageIndex, "container run options must precede the image")
    }

    // MARK: - Prepend handler

    func testHandlerKeepsAProjectDefinedEPHost() {
        XCTAssertTrue(ElasticsearchService.handlerContents.contains("if ( ! defined( 'EP_HOST' ) )"))
        XCTAssertTrue(ElasticsearchService.handlerContents.contains("getenv( 'EP_HOST' )"))
    }

    func testWriteThenRemoveHandler() throws {
        let php = tempRoot.appendingPathComponent("php", isDirectory: true)
        try ElasticsearchService.writeHandler(phpConfFolder: php)
        XCTAssertTrue(ElasticsearchService.isHandlerPresent(phpConfFolder: php))

        ElasticsearchService.removeHandler(phpConfFolder: php)
        XCTAssertFalse(FileManager.default.fileExists(atPath: handlerURL(php).path))
    }

    func testRemoveLeavesAUserFileWithTheSameName() throws {
        let php = tempRoot.appendingPathComponent("php", isDirectory: true)
        let url = handlerURL(php)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "<?php // user file".write(to: url, atomically: true, encoding: .utf8)

        ElasticsearchService.removeHandler(phpConfFolder: php)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Helpers

    private func makeSite() -> Site {
        Site(name: "Example", slug: "example", path: tempRoot.appendingPathComponent("example", isDirectory: true),
             port: 8881, imageTag: SiteRecipe.defaultWordPressImage, elasticsearchEnabled: true)
    }

    private func handlerURL(_ php: URL) -> URL {
        PrependService.handlerURL(phpConfFolder: php, name: ElasticsearchService.handlerFileName)
    }

    private func containsPair(_ args: [String], _ flag: String, _ value: String) -> Bool {
        zip(args, args.dropFirst()).contains { $0 == flag && $1 == value }
    }
}
