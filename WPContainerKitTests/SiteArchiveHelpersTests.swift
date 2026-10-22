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

    // MARK: - Leftover sweeps

    func testSweepStaleImportFoldersRemovesOnlyOldWorkFolders() throws {
        let now = Date()
        let old = try makeItem(".wpc-import-OLD", directory: true, age: 7 * 3600, now: now)
        let fresh = try makeItem(".wpc-import-FRESH", directory: true, age: 60, now: now)
        let site = try makeItem("example", directory: true, age: 7 * 3600, now: now)
        let other = try makeItem(".wpc-export", directory: true, age: 7 * 3600, now: now)

        SiteArchiveService.sweepStaleImportFolders(in: tempRoot, now: now)

        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: old.path))
        XCTAssertTrue(fm.fileExists(atPath: fresh.path))
        XCTAssertTrue(fm.fileExists(atPath: site.path))
        XCTAssertTrue(fm.fileExists(atPath: other.path))
    }

    func testSweepStaleImportFoldersToleratesMissingParent() {
        SiteArchiveService.sweepStaleImportFolders(in: tempRoot.appendingPathComponent("absent"), now: Date())
    }

    func testSweepStalePartialArchivesRemovesOnlyOldPartialsOfDestination() throws {
        let now = Date()
        let destination = tempRoot.appendingPathComponent("example.zip")
        let old = try makeItem(".example.zip.partial-OLD.zip", directory: false, age: 7 * 3600, now: now)
        let fresh = try makeItem(".example.zip.partial-FRESH.zip", directory: false, age: 60, now: now)
        let otherSite = try makeItem(".other.zip.partial-OLD.zip", directory: false, age: 7 * 3600, now: now)
        let archive = try makeItem("example.zip", directory: false, age: 7 * 3600, now: now)

        SiteArchiveService.sweepStalePartialArchives(for: destination, now: now)

        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: old.path))
        XCTAssertTrue(fm.fileExists(atPath: fresh.path))
        XCTAssertTrue(fm.fileExists(atPath: otherSite.path))
        XCTAssertTrue(fm.fileExists(atPath: archive.path))
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

    // MARK: - Helpers

    /// Creates a file or folder under `tempRoot` last modified `age` seconds before `now`.
    private func makeItem(_ name: String, directory: Bool, age: TimeInterval, now: Date) throws -> URL {
        let fm = FileManager.default
        let url = tempRoot.appendingPathComponent(name, isDirectory: directory)
        if directory {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            try "x\n".write(to: url.appendingPathComponent("database.sql"), atomically: true, encoding: .utf8)
        } else {
            try "x\n".write(to: url, atomically: true, encoding: .utf8)
        }
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
        return url
    }
}
