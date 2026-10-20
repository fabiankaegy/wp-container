import XCTest
@testable import WPContainerKit

final class SiteArchiveHelpersTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wpc-archive-helpers-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    // MARK: - Excludes

    func testDefaultExcludesAreExact() {
        XCTAssertEqual(SiteArchiveService.defaultExcludes,
                       [".git", ".svn", ".DS_Store", "__MACOSX", "node_modules", "bower_components"])
        XCTAssertEqual(SiteArchiveService.alwaysExcluded, [".wpc-export", ".wpc-import"])
    }

    func testZipExcludeArgsCoverRootAndNestedDepth() {
        let args = SiteArchiveService.zipExcludeArgs(["node_modules"], under: "wordpress")
        XCTAssertTrue(args.contains("wordpress/node_modules"))
        XCTAssertTrue(args.contains("wordpress/node_modules/*"))
        XCTAssertTrue(args.contains("*/node_modules"))
        XCTAssertTrue(args.contains("*/node_modules/*"))
        XCTAssertTrue(args.contains("*/.wpc-export/*"))
        XCTAssertTrue(args.contains("*/.wpc-import/*"))
    }

    // MARK: - Entry validation

    func testValidateEntriesAcceptsNormalArchive() throws {
        try SiteArchiveService.validateEntries(["wpc-site.json", "database.sql", "wordpress/", "wordpress/index.php"])
    }

    func testValidateEntriesRejectsTraversalAndStrays() {
        for bad in ["../x", "/etc/passwd", "wordpress/../../x", "extra.txt"] {
            XCTAssertThrowsError(try SiteArchiveService.validateEntries(["wpc-site.json", "database.sql", bad])) {
                XCTAssertEqual($0 as? SiteArchiveError, .unsafeEntry(bad))
            }
        }
    }

    func testValidateEntriesRequiresManifest() {
        XCTAssertThrowsError(try SiteArchiveService.validateEntries(["database.sql", "wordpress/"])) {
            XCTAssertEqual($0 as? SiteArchiveError, .notAWPCExport)
        }
    }

    // MARK: - Slug

    func testResolveSlugSkipsStoreAndDiskClashes() throws {
        try FileManager.default.createDirectory(
            at: tempRoot.appendingPathComponent("shop-2"), withIntermediateDirectories: true)
        let slug = SiteArchiveService.resolveSlug(name: "Shop", existingSlugs: ["shop"], parentFolder: tempRoot)
        XCTAssertEqual(slug, "shop-3")
    }

    // MARK: - Mounts

    func testInlinableMountsMapsUnderDocroot() {
        let result = SiteArchiveService.inlinableMounts([
            Mount(hostPath: "/repo/plugin", containerPath: "/var/www/html/wp-content/plugins/acme"),
            Mount(hostPath: "/repo/conf", containerPath: "/usr/local/etc/php/conf.d/x.ini"),
            Mount(hostPath: "/repo/root", containerPath: "/var/www/html"),
        ])
        XCTAssertEqual(result.inlined, [.init(hostPath: "/repo/plugin", relativePath: "wp-content/plugins/acme")])
        XCTAssertEqual(result.skipped.count, 2)
    }

    // MARK: - File name

    func testDefaultFileName() {
        var parts = DateComponents()
        parts.year = 2026
        parts.month = 3
        parts.day = 4
        parts.hour = 12
        let date = Calendar.current.date(from: parts)!
        XCTAssertEqual(SiteArchiveService.defaultFileName(slug: "shop", date: date), "shop-20260304.zip")
    }
}
