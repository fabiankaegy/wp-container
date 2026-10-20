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

    func testEarlyHandlerRefusesPostRestRouteOnExemptRequests() {
        let php = SharePHPService.earlyContents
        XCTAssertTrue(php.contains("$is_exempt = isset( $_SERVER['HTTP_X_WPC_SHARE_EXEMPT'] );"))
        XCTAssertTrue(php.contains("if ( $is_exempt && isset( $_POST['rest_route'] ) ) {"))
        XCTAssertTrue(php.contains("http_response_code( 401 );"))
    }

    func testSaveHandlerSwapsTheSubmittedDomainBackBeforeComparing() throws {
        let php = SharePHPService.saveContents
        let swap = php.range(of: "$submitted = wpc_share_swap_back_domain( $submitted );")
        let compare = php.range(of: "$submitted !== $current")
        XCTAssertNotNil(swap)
        XCTAssertNotNil(compare)
        if let swap, let compare { XCTAssertLessThan(swap.lowerBound, compare.lowerBound) }
    }

    /// Runs the early handler under the host `php` with the CLI guard removed, so
    /// the share-origin and exemption checks run against stubbed request globals.
    func testEarlyHandlerSmokeRunRefusesExemptRestRoute() throws {
        let candidates = [
            "/opt/homebrew/bin/php", "/usr/local/bin/php", "/usr/bin/php",
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Herd/bin/php").path,
        ]
        guard let php = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("php is not installed")
        }
        let site = makeSite()
        try SharePHPService.activate(for: site, publicOrigin: "https://example-share.example.com")
        let handler = PrependService.handlerURL(phpConfFolder: site.phpConfFolder, name: SharePHPService.earlyHandlerName)
        let stubbed = SharePHPService.earlyContents.replacingOccurrences(of: "'cli' === PHP_SAPI", with: "false")
        try stubbed.write(to: handler, atomically: true, encoding: .utf8)

        func run(exempt: Bool, origin: String = "https://example-share.example.com") throws -> String {
            let exemptLine = exempt ? "$_SERVER['HTTP_X_WPC_SHARE_EXEMPT'] = '1';" : ""
            let driver = """
                <?php
                $_SERVER['HTTP_X_WPC_SHARE_ORIGIN'] = '\(origin)';
                \(exemptLine)
                $_POST['rest_route'] = '/wp/v2/users';
                require '\(handler.path)';
                echo "REACHED";
                """
            let script = tempRoot.appendingPathComponent("driver-\(UUID().uuidString).php")
            try driver.write(to: script, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: php)
            process.arguments = ["-n", script.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }

        let refused = try run(exempt: true)
        XCTAssertTrue(refused.contains("Authentication required."), refused)
        XCTAssertFalse(refused.contains("REACHED"), refused)
        XCTAssertTrue(try run(exempt: false).contains("REACHED"))
        XCTAssertTrue(try run(exempt: true, origin: "https://forged.example.com").contains("REACHED"))
    }

    private func makeSite() -> Site {
        Site(name: "Example", slug: "my-site", path: tempRoot.appendingPathComponent("my-site", isDirectory: true),
             port: 8881, imageTag: SiteRecipe.defaultWordPressImage)
    }
}
