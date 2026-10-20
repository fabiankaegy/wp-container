import XCTest
@testable import WPContainerKit

/// Coverage for the managed PHP that rewrites origins for share visitors: the
/// handler files, their markers, and the origin file they read.
final class SharePHPServiceTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wpc-share-php-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testActivateWritesHandlersAndOriginFile() throws {
        let site = makeSite()
        try SharePHPService.activate(for: site, publicOrigin: "https://example-share.example.com")

        let folder = site.phpConfFolder
        XCTAssertTrue(PrependService.isHandlerPresent(
            phpConfFolder: folder, name: SharePHPService.earlyHandlerName, marker: SharePHPService.earlyMarker))
        XCTAssertTrue(PrependService.isHandlerPresent(
            phpConfFolder: folder, name: SharePHPService.saveHandlerName, marker: SharePHPService.saveMarker))
        XCTAssertEqual(SharePHPService.earlyHandlerName, "early/wpc-share.php")
        XCTAssertEqual(SharePHPService.saveHandlerName, "wpc-share-save.php")

        let data = try Data(contentsOf: folder.appendingPathComponent(SharePHPService.originFileName))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["origin"] as? String, "https://example-share.example.com")
        XCTAssertEqual(json["local"] as? String, site.sharePrimaryOrigin)
        XCTAssertEqual(json["locals"] as? [String], site.shareLocalOrigins)
    }

    func testActivateIsIdempotentAndUpdatesTheOrigin() throws {
        let site = makeSite()
        try SharePHPService.activate(for: site, publicOrigin: "https://one.example.com")
        try SharePHPService.activate(for: site, publicOrigin: "https://two.example.com")
        let data = try Data(contentsOf: site.phpConfFolder.appendingPathComponent(SharePHPService.originFileName))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["origin"] as? String, "https://two.example.com")
    }

    func testDeactivateRemovesOriginFileAndMarkedHandlers() throws {
        let site = makeSite()
        try SharePHPService.activate(for: site, publicOrigin: "https://example-share.example.com")
        SharePHPService.deactivate(for: site)

        let folder = site.phpConfFolder
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: folder.appendingPathComponent(SharePHPService.originFileName).path))
        XCTAssertFalse(fm.fileExists(atPath: PrependService.handlerURL(
            phpConfFolder: folder, name: SharePHPService.earlyHandlerName).path))
        XCTAssertFalse(fm.fileExists(atPath: PrependService.handlerURL(
            phpConfFolder: folder, name: SharePHPService.saveHandlerName).path))
    }

    func testDeactivateLeavesUnmarkedFiles() throws {
        let site = makeSite()
        let folder = site.phpConfFolder
        for name in [SharePHPService.earlyHandlerName, SharePHPService.saveHandlerName] {
            try PrependService.writeHandler(phpConfFolder: folder, name: name, contents: "<?php // user file")
        }
        SharePHPService.deactivate(for: site)
        for name in [SharePHPService.earlyHandlerName, SharePHPService.saveHandlerName] {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: PrependService.handlerURL(phpConfFolder: folder, name: name).path), name)
        }
    }

    func testDeactivateWithNothingActiveIsANoOp() {
        SharePHPService.deactivate(for: makeSite())
    }

    private func makeSite() -> Site {
        Site(name: "Example", slug: "my-site", path: tempRoot.appendingPathComponent("my-site", isDirectory: true),
             port: 8881, imageTag: SiteRecipe.defaultWordPressImage)
    }
}
