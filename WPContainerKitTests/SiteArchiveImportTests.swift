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

    func testInspectRejectsManifestWithoutDatabase() async throws {
        try write(try makeManifest().encoded(), to: "wpc-site.json")
        try write("<?php // index\n", to: "wordpress/index.php")
        let archive = try await makeZip()

        await assertInspectThrows(archive, .notAWPCExport)
    }

    func testInspectRejectsManifestWithoutWordPressFolder() async throws {
        try write(try makeManifest().encoded(), to: "wpc-site.json")
        try write("-- example dump\n", to: "database.sql")
        let archive = try await makeZip()

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

    func testExtractDropsDanglingSymlinkChain() async throws {
        try write(try makeManifest().encoded(), to: "wpc-site.json")
        try write("-- example dump\n", to: "database.sql")
        try write("<?php // index\n", to: "wordpress/index.php")
        let fm = FileManager.default
        let wordpressSource = source.appendingPathComponent("wordpress")
        try fm.createSymbolicLink(atPath: wordpressSource.appendingPathComponent("b").path, withDestinationPath: ".")
        try fm.createSymbolicLink(atPath: wordpressSource.appendingPathComponent("c").path,
                                  withDestinationPath: Self.danglingChainTarget)
        let archive = try await makeZip()
        let folder = tempRoot.appendingPathComponent("extracted", isDirectory: true)

        try await SiteArchiveService.extract(archive: archive, into: folder)

        let wordpress = folder.appendingPathComponent("wordpress")
        XCTAssertNil(try? fm.destinationOfSymbolicLink(atPath: wordpress.appendingPathComponent("c").path))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: wordpress.appendingPathComponent("b").path), ".")
        XCTAssertTrue(fm.fileExists(atPath: wordpress.appendingPathComponent("index.php").path))
    }

    func testExtractDropsTopLevelDatabaseSymlink() async throws {
        try write(try makeManifest().encoded(), to: "wpc-site.json")
        try write("<?php // index\n", to: "wordpress/index.php")
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("database.sql").path,
                                                   withDestinationPath: "/etc/hosts")
        let archive = try await makeZip()
        let folder = tempRoot.appendingPathComponent("extracted", isDirectory: true)

        try await SiteArchiveService.extract(archive: archive, into: folder)

        let database = folder.appendingPathComponent("database.sql")
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: database.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: database.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("wordpress/index.php").path))
    }

    func testExtractMatchesSymlinkNamesLiterally() async throws {
        try write(try makeManifest().encoded(), to: "wpc-site.json")
        try write("-- example dump\n", to: "database.sql")
        try write("<?php // index\n", to: "wordpress/index.php")
        try write("<?php // lib\n", to: "wordpress/lib.php")
        let fm = FileManager.default
        let wordpressSource = source.appendingPathComponent("wordpress")
        try fm.createSymbolicLink(atPath: wordpressSource.appendingPathComponent("l*").path, withDestinationPath: "/etc")
        try fm.createSymbolicLink(atPath: wordpressSource.appendingPathComponent("[in] ?").path,
                                  withDestinationPath: "index.php")
        let archive = try await makeZip()
        let folder = tempRoot.appendingPathComponent("extracted", isDirectory: true)

        try await SiteArchiveService.extract(archive: archive, into: folder)

        let wordpress = folder.appendingPathComponent("wordpress")
        XCTAssertNil(try? fm.destinationOfSymbolicLink(atPath: wordpress.appendingPathComponent("l*").path))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: wordpress.appendingPathComponent("[in] ?").path), "index.php")
        XCTAssertTrue(fm.fileExists(atPath: wordpress.appendingPathComponent("lib.php").path))
    }

    func testExtractRefusesEntriesStoredUnderASymlink() async throws {
        let fm = FileManager.default
        try write(try makeManifest().encoded(), to: "wpc-site.json")
        try write("-- example dump\n", to: "database.sql")
        try write("<?php // index\n", to: "wordpress/index.php")
        let target = tempRoot.appendingPathComponent("target", isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: source.appendingPathComponent("wordpress/plugins").path,
                                  withDestinationPath: target.path)
        let archive = try await makeZip()
        let payload = tempRoot.appendingPathComponent("payload", isDirectory: true)
        try fm.createDirectory(at: payload.appendingPathComponent("wordpress/plugins"), withIntermediateDirectories: true)
        try "<?php // x\n".write(to: payload.appendingPathComponent("wordpress/plugins/x.php"), atomically: true, encoding: .utf8)
        let appended = try await ProcessRunner.run(
            executable: "/usr/bin/zip", args: ["-r", "-y", "-q", "-X", archive.path, "wordpress/plugins"], cwd: payload)
        XCTAssertTrue(appended.succeeded, appended.stderr)
        let folder = tempRoot.appendingPathComponent("extracted", isDirectory: true)

        do {
            try await SiteArchiveService.extract(archive: archive, into: folder)
            XCTFail("expected .unsafeEntry")
        } catch let error as SiteArchiveError {
            guard case .unsafeEntry(let name) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(name.hasPrefix("wordpress/plugins/"), name)
        }
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: target.path).isEmpty)
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

    // MARK: - importSite rollback

    func testImportRollsBackWhenWordPressFolderIsASymlink() async throws {
        // Extraction refuses `wordpress/…` entries stored under a top-level `wordpress` link.
        let fm = FileManager.default
        try write(try makeManifest().encoded(), to: "wpc-site.json")
        try write("-- example dump\n", to: "database.sql")
        let target = tempRoot.appendingPathComponent("target", isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: source.appendingPathComponent("wordpress").path, withDestinationPath: target.path)
        let archive = try await makeZip()
        let payload = tempRoot.appendingPathComponent("payload", isDirectory: true)
        try fm.createDirectory(at: payload.appendingPathComponent("wordpress"), withIntermediateDirectories: true)
        try "<?php // index\n".write(to: payload.appendingPathComponent("wordpress/index.php"), atomically: true, encoding: .utf8)
        let appended = try await ProcessRunner.run(
            executable: "/usr/bin/zip", args: ["-r", "-y", "-q", "-X", archive.path, "wordpress"], cwd: payload)
        XCTAssertTrue(appended.succeeded, appended.stderr)

        let persistence = StorePersistence(fileURL: tempRoot.appendingPathComponent("sites.json"))
        let existingGroup = SiteGroup(name: "Clients")
        _ = try await persistence.mutate { $0.groups.append(existingGroup) }
        let phases = PhaseRecorder()
        let options = SiteImportOptions(name: Self.rollbackSiteName, parentFolder: sitesFolder, groupName: "clients")

        let error = await importError(archive, persistence: persistence, options: options, phases: phases)

        XCTAssertNotNil(error)
        XCTAssertTrue(phases.phases.contains(.rollingBack), "\(phases.phases)")
        let envelope = try await persistence.load()
        XCTAssertTrue(envelope.sites.isEmpty)
        XCTAssertEqual(envelope.groups.map(\.id), [existingGroup.id])
        XCTAssertFalse(fm.fileExists(atPath: sitesFolder.appendingPathComponent(Self.rollbackSlug).path))
        XCTAssertEqual(try importWorkFolders(), [])
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    func testImportRollbackRemovesSiteFolderAndGroupItCreated() async throws {
        let archive = try await makeArchive(customDomain: "")
        let persistence = StorePersistence(fileURL: tempRoot.appendingPathComponent("sites.json"))
        let phases = PhaseRecorder()
        // A folder planted at the site's `wordpress/` path makes the move out of the work folder fail.
        let obstacle = sitesFolder.appendingPathComponent("\(Self.rollbackSlug)/wordpress", isDirectory: true)
        let options = SiteImportOptions(name: Self.rollbackSiteName, parentFolder: sitesFolder, groupName: "Imported")

        let error = await importError(archive, persistence: persistence, options: options, phases: phases) { phase in
            if phase == .extracting {
                try? FileManager.default.createDirectory(at: obstacle, withIntermediateDirectories: true)
            }
        }

        XCTAssertNotNil(error)
        XCTAssertTrue(phases.phases.contains(.rollingBack), "\(phases.phases)")
        let envelope = try await persistence.load()
        XCTAssertTrue(envelope.sites.isEmpty)
        XCTAssertTrue(envelope.groups.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sitesFolder.appendingPathComponent(Self.rollbackSlug).path))
        XCTAssertEqual(try importWorkFolders(), [])
    }

    // MARK: - Helpers

    /// A name whose slug no real site is likely to use, since rollback touches the shared certificate.
    private static let rollbackSiteName = "WPC Rollback Fixture"
    private static let rollbackSlug = "wpc-rollback-fixture"

    /// Twelve hops into `b -> .` and twelve back up, ending at a path that does not exist.
    private static let danglingChainTarget =
        (Array(repeating: "b", count: 12) + Array(repeating: "..", count: 12) + ["nonexist", "dir"]).joined(separator: "/")

    private var sitesFolder: URL { tempRoot.appendingPathComponent("sites", isDirectory: true) }

    /// Records import phases from the progress callback.
    private final class PhaseRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [SiteImportPhase] = []

        var phases: [SiteImportPhase] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }

        func record(_ phase: SiteImportPhase) {
            lock.lock()
            recorded.append(phase)
            lock.unlock()
        }
    }

    /// Runs an import against a container CLI that cannot launch and returns its error.
    private func importError(
        _ archive: URL,
        persistence: StorePersistence,
        options: SiteImportOptions,
        phases: PhaseRecorder,
        onPhase: @escaping @Sendable (SiteImportPhase) -> Void = { _ in }
    ) async -> Error? {
        let cli = ContainerCLI(binaryPath: "/nonexistent/container")
        let service = SiteArchiveService(cli: cli, lifecycle: SiteLifecycle(cli: cli), persistence: persistence)
        do {
            _ = try await service.importSite(archive: archive, options: options) { phase in
                phases.record(phase)
                onPhase(phase)
            }
            return nil
        } catch {
            return error
        }
    }

    /// Names of `.wpc-import-*` folders left in `sitesFolder`.
    private func importWorkFolders() throws -> [String] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: sitesFolder.path) else { return [] }
        return try fm.contentsOfDirectory(atPath: sitesFolder.path).filter { $0.hasPrefix(".wpc-import-") }
    }

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
