import XCTest
@testable import WPContainerKit

final class PHPConfServiceTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wpc-php-conf-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testManagedDefaultsRaiseTheMemoryLimit() throws {
        let site = makeSite()
        try PHPConfService.ensure(for: site)

        let contents = try String(contentsOf: PHPConfService.managedIniURL(phpConfFolder: site.phpConfFolder), encoding: .utf8)
        XCTAssertTrue(contents.contains("\nmemory_limit = 256M"))
    }

    func testRefreshesAnOutdatedManagedFile() throws {
        let site = makeSite()
        let url = PHPConfService.managedIniURL(phpConfFolder: site.phpConfFolder)
        try FileManager.default.createDirectory(at: site.phpConfFolder, withIntermediateDirectories: true)
        try "\(PHPConfService.marker)\nupload_max_filesize = 50M\n".write(to: url, atomically: true, encoding: .utf8)

        try PHPConfService.ensure(for: site)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), PHPConfService.managedIniContents)
    }

    func testLeavesAUserOwnedFileAlone() throws {
        let site = makeSite()
        let url = PHPConfService.managedIniURL(phpConfFolder: site.phpConfFolder)
        try FileManager.default.createDirectory(at: site.phpConfFolder, withIntermediateDirectories: true)
        try "memory_limit = 512M\n".write(to: url, atomically: true, encoding: .utf8)

        try PHPConfService.ensure(for: site)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "memory_limit = 512M\n")
    }

    func testOneShotWPCLIContainersLoadTheManagedDefaults() throws {
        let site = makeSite()
        try PHPConfService.ensure(for: site)
        let mount = "\(site.phpConfFolder.path):\(SiteRecipe.phpConfContainerPath)"

        let commands = [
            SiteRecipe.wpCoreInstallArgs(site, dbHost: "10.0.0.2"),
            SiteRecipe.wpSetURLsArgs(site, dbHost: "10.0.0.2", url: "http://127.0.0.1:8881"),
            SiteRecipe.wpDBExportArgs(site, dbHost: "10.0.0.2"),
            SiteRecipe.wpOptionGetArgs(site, dbHost: "10.0.0.2", option: "home"),
        ]
        for args in commands {
            let imageIndex = try XCTUnwrap(args.firstIndex(of: SiteRecipe.cliImage(for: site)))
            let mountIndex = try XCTUnwrap(args.firstIndex(of: mount), "\(args)")
            XCTAssertLessThan(mountIndex, imageIndex)
        }
    }

    private func makeSite() -> Site {
        Site(name: "Example", slug: "example", path: tempRoot.appendingPathComponent("example", isDirectory: true),
             port: 8881, imageTag: SiteRecipe.defaultWordPressImage)
    }
}
