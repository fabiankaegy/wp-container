import XCTest
@testable import WPContainerKit

/// Packaging a site folder into an archive with the real `/usr/bin/zip`.
final class SiteArchivePackageTests: XCTestCase {

    private var tempRoot: URL!
    private var wordpress: URL!
    private var staging: URL!
    private var outputFolder: URL!

    override func setUpWithError() throws {
        let fm = FileManager.default
        tempRoot = fm.temporaryDirectory
            .appendingPathComponent("wpc-archive-package-tests-\(UUID().uuidString)", isDirectory: true)
        wordpress = tempRoot.appendingPathComponent("site/wordpress", isDirectory: true)
        staging = tempRoot.appendingPathComponent("site/.wpc-export", isDirectory: true)
        outputFolder = tempRoot.appendingPathComponent("out", isDirectory: true)
        for folder in [wordpress!, staging!, outputFolder!] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try write("<?php // index\n", to: "index.php")
        try write("<?php\n$wp_version = '6.8';\n", to: "wp-includes/version.php")
        try write("module.exports = 1;\n", to: "wp-content/plugins/a/node_modules/x.js")
        try write("<?php // plugin a\n", to: "wp-content/plugins/a/a.php")
        try write("ref: refs/heads/main\n", to: ".git/HEAD")
        try "-- example dump\n".write(to: staging.appendingPathComponent("database.sql"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    // MARK: - package

    func testPackageWritesThreeTopLevelEntriesAndHonorsExcludes() async throws {
        let destination = outputFolder.appendingPathComponent("example.zip")
        let warnings = try await SiteArchiveService.package(
            wordpressFolder: wordpress, stagingFolder: staging, destination: destination,
            manifest: makeManifest(), excludes: SiteArchiveService.defaultExcludes,
            mounts: [], overwrite: false)

        XCTAssertTrue(warnings.isEmpty)
        let entries = try await zipEntries(destination)
        XCTAssertTrue(entries.contains("wpc-site.json"))
        XCTAssertTrue(entries.contains("database.sql"))
        XCTAssertTrue(entries.contains("wordpress/index.php"))
        XCTAssertTrue(entries.contains("wordpress/wp-content/plugins/a/a.php"))
        XCTAssertFalse(entries.contains { $0.contains("node_modules") }, "\(entries)")
        XCTAssertFalse(entries.contains { $0.contains(".git/") }, "\(entries)")
        let topLevel = Set(entries.compactMap { $0.split(separator: "/").first.map(String.init) })
        XCTAssertEqual(topLevel, ["wpc-site.json", "database.sql", "wordpress"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.appendingPathComponent("wpc-site.json").path))
    }

    func testPackageInlinesMountAtRelativePath() async throws {
        let host = tempRoot.appendingPathComponent("host/acme", isDirectory: true)
        try FileManager.default.createDirectory(at: host.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        try "<?php // acme\n".write(to: host.appendingPathComponent("acme.php"), atomically: true, encoding: .utf8)
        try "x\n".write(to: host.appendingPathComponent("node_modules/y.js"), atomically: true, encoding: .utf8)
        let destination = outputFolder.appendingPathComponent("example.zip")
        let mounts = [SiteArchiveService.InlinedMount(hostPath: host.path, relativePath: "wp-content/plugins/acme")]

        let warnings = try await SiteArchiveService.package(
            wordpressFolder: wordpress, stagingFolder: staging, destination: destination,
            manifest: makeManifest(), excludes: SiteArchiveService.defaultExcludes,
            mounts: mounts, overwrite: false)

        XCTAssertTrue(warnings.isEmpty)
        let entries = try await zipEntries(destination)
        XCTAssertTrue(entries.contains("wordpress/wp-content/plugins/acme/acme.php"), "\(entries)")
        XCTAssertTrue(entries.contains("wordpress/index.php"))
        XCTAssertFalse(entries.contains { $0.contains("node_modules") }, "\(entries)")
    }

    func testPackageSkipsMountsWithUnsafeRelativePaths() async throws {
        let host = tempRoot.appendingPathComponent("host/evil", isDirectory: true)
        try FileManager.default.createDirectory(at: host, withIntermediateDirectories: true)
        try "x\n".write(to: host.appendingPathComponent("evil.php"), atomically: true, encoding: .utf8)
        let destination = outputFolder.appendingPathComponent("example.zip")
        let mounts = ["", "/abs", "../escape", "wp-content/../../escape"].map {
            SiteArchiveService.InlinedMount(hostPath: host.path, relativePath: $0)
        }

        let warnings = try await SiteArchiveService.package(
            wordpressFolder: wordpress, stagingFolder: staging, destination: destination,
            manifest: makeManifest(), excludes: [], mounts: mounts, overwrite: false)

        XCTAssertEqual(warnings.count, 4)
        let entries = try await zipEntries(destination)
        XCTAssertFalse(entries.contains { $0.contains("evil.php") }, "\(entries)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempRoot.appendingPathComponent("site/escape").path))
    }

    func testRefusesExistingDestinationWithoutOverwrite() async throws {
        let destination = outputFolder.appendingPathComponent("example.zip")
        try "existing".write(to: destination, atomically: true, encoding: .utf8)

        do {
            _ = try await SiteArchiveService.package(
                wordpressFolder: wordpress, stagingFolder: staging, destination: destination,
                manifest: makeManifest(), excludes: [], mounts: [], overwrite: false)
            XCTFail("expected outputExists")
        } catch let error as SiteArchiveError {
            XCTAssertEqual(error, .outputExists(destination.path))
        }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "existing")
    }

    func testRefusesDirectoryDestinationEvenWithOverwrite() async throws {
        let destination = outputFolder.appendingPathComponent("existing-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let keep = destination.appendingPathComponent("keep.txt")
        try "keep".write(to: keep, atomically: true, encoding: .utf8)

        do {
            _ = try await SiteArchiveService.package(
                wordpressFolder: wordpress, stagingFolder: staging, destination: destination,
                manifest: makeManifest(), excludes: [], mounts: [], overwrite: true)
            XCTFail("expected outputExists")
        } catch let error as SiteArchiveError {
            XCTAssertEqual(error, .outputExists(destination.path))
        }
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(try String(contentsOf: keep, encoding: .utf8), "keep")
    }

    func testOverwriteReplacesExistingDestination() async throws {
        let destination = outputFolder.appendingPathComponent("example.zip")
        try "existing".write(to: destination, atomically: true, encoding: .utf8)

        _ = try await SiteArchiveService.package(
            wordpressFolder: wordpress, stagingFolder: staging, destination: destination,
            manifest: makeManifest(), excludes: [], mounts: [], overwrite: true)

        let entries = try await zipEntries(destination)
        XCTAssertTrue(entries.contains("wpc-site.json"))
    }

    func testFailedPackagingLeavesNoTempFiles() async throws {
        // A missing parent fails to launch zip; an existing parent makes zip exit non-zero.
        let emptyParent = tempRoot.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyParent, withIntermediateDirectories: true)
        let missingFolders = [
            tempRoot.appendingPathComponent("absent/wordpress", isDirectory: true),
            emptyParent.appendingPathComponent("wordpress", isDirectory: true),
        ]
        let destination = outputFolder.appendingPathComponent("example.zip")

        for missing in missingFolders {
            do {
                _ = try await SiteArchiveService.package(
                    wordpressFolder: missing, stagingFolder: staging, destination: destination,
                    manifest: makeManifest(), excludes: [], mounts: [], overwrite: false)
                XCTFail("expected toolFailed for \(missing.path)")
            } catch SiteArchiveError.toolFailed {
                // expected
            }
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: outputFolder.path)
            XCTAssertTrue(leftovers.isEmpty, "\(leftovers)")
        }
    }

    // MARK: - externalSymlinks

    func testExternalSymlinksAreReported() throws {
        let fm = FileManager.default
        let outside = tempRoot.appendingPathComponent("outside", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try "x\n".write(to: outside.appendingPathComponent("inner.txt"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(atPath: wordpress.appendingPathComponent("wp-content/plugins/linked").path,
                                  withDestinationPath: "/tmp/elsewhere")
        try fm.createSymbolicLink(atPath: wordpress.appendingPathComponent("wp-content/plugins/outside").path,
                                  withDestinationPath: outside.path)
        try fm.createSymbolicLink(atPath: wordpress.appendingPathComponent("wp-content/plugins/up").path,
                                  withDestinationPath: "../../../outside")
        try fm.createSymbolicLink(atPath: wordpress.appendingPathComponent("wp-content/index-link.php").path,
                                  withDestinationPath: "../index.php")
        try fm.createSymbolicLink(atPath: wordpress.appendingPathComponent("abs-index.php").path,
                                  withDestinationPath: wordpress.appendingPathComponent("index.php").path)

        let links = SiteArchiveService.externalSymlinks(in: wordpress).sorted()

        XCTAssertEqual(links, ["wp-content/plugins/linked", "wp-content/plugins/outside", "wp-content/plugins/up"])
    }

    // MARK: - wordpressVersion

    func testWordPressVersionParsed() {
        XCTAssertEqual(SiteArchiveService.wordpressVersion(in: wordpress), "6.8")
        XCTAssertNil(SiteArchiveService.wordpressVersion(in: tempRoot.appendingPathComponent("absent")))
    }

    // MARK: - Helpers

    private func write(_ text: String, to relativePath: String) throws {
        let url = wordpress.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeManifest() -> SiteArchiveManifest {
        let site = Site(name: "Example", slug: "example", path: tempRoot.appendingPathComponent("site"),
                        port: 8100, imageTag: "wordpress:latest")
        return SiteArchiveManifest(
            source: .init(name: "Example", slug: "example", url: "http://example.test", localURL: "http://127.0.0.1:8100"),
            settings: SiteArchiveSettings(site: site))
    }

    private func zipEntries(_ archive: URL) async throws -> [String] {
        let result = try await ProcessRunner.run(executable: "/usr/bin/zipinfo", args: ["-1", archive.path])
        XCTAssertTrue(result.succeeded, result.stderr)
        return result.stdout.split(separator: "\n").map(String.init)
    }
}
