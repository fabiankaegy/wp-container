import XCTest
@testable import WPContainerKit

/// Reading and unpacking site archives built with the real `/usr/bin/zip`.
final class SiteArchiveImportTests: XCTestCase {

    private var tempRoot: URL!
    private var source: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wpc-archive-import-tests-\(UUID().uuidString)", isDirectory: true)
        source = tempRoot.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    // MARK: - inspect

    func testInspectReadsManifestAndSize() async throws {
        let manifest = try makeManifest().encoded()
        try write(manifest, to: "wpc-site.json")
        try write("-- example dump\n", to: "database.sql")
        try write("<?php // index\n", to: "wordpress/index.php")
        let archive = try await makeZip()

        let info = try await SiteArchiveService.inspect(archive: archive)

        XCTAssertEqual(info.manifest.source.name, "Example")
        XCTAssertEqual(info.manifest.source.slug, "example")
        XCTAssertEqual(info.entryCount, 4)
        let expectedBytes = Int64(manifest.count + "-- example dump\n".utf8.count + "<?php // index\n".utf8.count)
        XCTAssertEqual(info.uncompressedBytes, expectedBytes)
    }

    func testInspectRejectsZipWithoutManifest() async throws {
        try write("{}\n", to: "local-site.json")
        try write("<?php // index\n", to: "app/public/index.php")
        let archive = try await makeZip()

        await assertInspectThrows(archive, .notAWPCExport)
    }

    func testInspectRejectsFutureSchema() async throws {
        var manifest = makeManifest()
        manifest.schemaVersion = 2
        try write(try manifest.encoded(), to: "wpc-site.json")
        try write("-- example dump\n", to: "database.sql")
        try write("<?php // index\n", to: "wordpress/index.php")
        let archive = try await makeZip()

        await assertInspectThrows(archive, .unsupportedSchema(2))
    }

    func testInspectRejectsFutureSchemaWithChangedFields() async throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: makeManifest().encoded()) as? [String: Any])
        object["schemaVersion"] = 2
        object.removeValue(forKey: "source")
        try write(try JSONSerialization.data(withJSONObject: object), to: "wpc-site.json")
        try write("-- example dump\n", to: "database.sql")
        try write("<?php // index\n", to: "wordpress/index.php")
        let archive = try await makeZip()

        await assertInspectThrows(archive, .unsupportedSchema(2))
    }

    func testInspectRejectsNonZip() async throws {
        let archive = tempRoot.appendingPathComponent("x.zip")
        try "not a zip archive\n".write(to: archive, atomically: true, encoding: .utf8)

        await assertInspectThrows(archive, .notAWPCExport)
    }

    // MARK: - extract

    func testExtractDropsSymlinksLeavingTree() async throws {
        try write(try makeManifest().encoded(), to: "wpc-site.json")
        try write("-- example dump\n", to: "database.sql")
        try write("<?php // index\n", to: "wordpress/index.php")
        let fm = FileManager.default
        try fm.createSymbolicLink(atPath: source.appendingPathComponent("wordpress/out").path, withDestinationPath: "/etc")
        try fm.createSymbolicLink(atPath: source.appendingPathComponent("wordpress/in").path, withDestinationPath: "index.php")
        let archive = try await makeZip()
        let folder = tempRoot.appendingPathComponent("extracted", isDirectory: true)

        try await SiteArchiveService.extract(archive: archive, into: folder)

        let wordpress = folder.appendingPathComponent("wordpress")
        XCTAssertNil(try? fm.destinationOfSymbolicLink(atPath: wordpress.appendingPathComponent("out").path))
        XCTAssertFalse(fm.fileExists(atPath: wordpress.appendingPathComponent("out").path))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: wordpress.appendingPathComponent("in").path), "index.php")
        XCTAssertTrue(fm.fileExists(atPath: wordpress.appendingPathComponent("index.php").path))
        XCTAssertTrue(fm.fileExists(atPath: folder.appendingPathComponent("database.sql").path))
        XCTAssertTrue(fm.fileExists(atPath: folder.appendingPathComponent("wpc-site.json").path))
    }

    // MARK: - importSite (checks that run before any container work)

    func testImportRejectsArchiveDomainThatDoesNotNormalize() async throws {
        let archive = try await makeArchive(customDomain: "not a domain!")
        let persistence = StorePersistence(fileURL: tempRoot.appendingPathComponent("sites.json"))

        await assertImportThrows(archive, persistence: persistence, .invalidDomain("not a domain!"))
        let sites = try await persistence.load().sites
        XCTAssertTrue(sites.isEmpty)
    }

    func testImportReportsDomainInUseFromLockedStoreWrite() async throws {
        let archive = try await makeArchive(customDomain: "Example.TEST")
        let persistence = StorePersistence(fileURL: tempRoot.appendingPathComponent("sites.json"))
        let existing = Site(name: "Other", slug: "other", path: tempRoot.appendingPathComponent("sites/other"),
                            port: 8200, imageTag: "wordpress:latest", customDomain: "example.test")
        _ = try await persistence.mutate { $0.sites.append(existing) }

        await assertImportThrows(archive, persistence: persistence, .domainInUse("example.test"))
        let slugs = try await persistence.load().sites.map(\.slug)
        XCTAssertEqual(slugs, ["other"])
    }

    // MARK: - Helpers

    private func write(_ text: String, to relativePath: String) throws {
        try write(Data(text.utf8), to: relativePath)
    }

    private func write(_ data: Data, to relativePath: String) throws {
        let url = source.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    /// Zips the contents of `source` (symlinks stored as links) into `archive.zip`.
    private func makeZip() async throws -> URL {
        let archive = tempRoot.appendingPathComponent("archive.zip")
        let result = try await ProcessRunner.run(
            executable: "/usr/bin/zip", args: ["-r", "-y", "-q", "-X", archive.path, "."], cwd: source)
        XCTAssertTrue(result.succeeded, result.stderr)
        return archive
    }

    private func makeManifest() -> SiteArchiveManifest {
        let site = Site(name: "Example", slug: "example", path: tempRoot.appendingPathComponent("site"),
                        port: 8100, imageTag: "wordpress:latest")
        return SiteArchiveManifest(
            source: .init(name: "Example", slug: "example", url: "http://example.test", localURL: "http://127.0.0.1:8100"),
            settings: SiteArchiveSettings(site: site))
    }

    /// A complete archive whose settings carry `customDomain`.
    private func makeArchive(customDomain: String) async throws -> URL {
        var manifest = makeManifest()
        manifest.settings.customDomain = customDomain
        try write(try manifest.encoded(), to: "wpc-site.json")
        try write("-- example dump\n", to: "database.sql")
        try write("<?php // index\n", to: "wordpress/index.php")
        return try await makeZip()
    }

    private func assertImportThrows(_ archive: URL, persistence: StorePersistence, _ expected: SiteArchiveError,
                                    file: StaticString = #filePath, line: UInt = #line) async {
        let cli = ContainerCLI(binaryPath: "/nonexistent/container")
        let service = SiteArchiveService(cli: cli, lifecycle: SiteLifecycle(cli: cli), persistence: persistence)
        let options = SiteImportOptions(parentFolder: tempRoot.appendingPathComponent("sites", isDirectory: true))
        do {
            _ = try await service.importSite(archive: archive, options: options, progress: { _ in })
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? SiteArchiveError, expected, "\(error)", file: file, line: line)
        }
    }

    private func assertInspectThrows(_ archive: URL, _ expected: SiteArchiveError,
                                     file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await SiteArchiveService.inspect(archive: archive)
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? SiteArchiveError, expected, "\(error)", file: file, line: line)
        }
    }
}
