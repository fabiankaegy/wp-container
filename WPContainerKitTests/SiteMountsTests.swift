import XCTest
@testable import WPContainerKit

/// Coverage for site mounts: container path normalization, host folder checks,
/// the `host:container` form `create --mount` takes, and add/remove ordering.
final class SiteMountsTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("site-mounts-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("example-plugin"), withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("file.txt"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - Container paths

    func testContainerPathAcceptsRelativeAndAbsolutePaths() throws {
        XCTAssertEqual(try SiteMounts.containerPath("wp-content/plugins/example"), "/var/www/html/wp-content/plugins/example")
        XCTAssertEqual(try SiteMounts.containerPath("./wp-content//plugins/example/"), "/var/www/html/wp-content/plugins/example")
        XCTAssertEqual(try SiteMounts.containerPath("/var/www/html/wp-content/themes/example"), "/var/www/html/wp-content/themes/example")
    }

    func testContainerPathRejectsPathsOutsideTheWordPressFolder() {
        for raw in ["", ".", "/var/www/html", "/var/www/html/", "/etc/example", "wp-content/../../etc", "wp-content/a:b"] {
            XCTAssertThrowsError(try SiteMounts.containerPath(raw), raw) { error in
                XCTAssertEqual(error as? SiteMounts.Failure, .invalidPath(raw))
            }
        }
    }

    // MARK: - Host folders

    func testMountResolvesRelativeHostFolders() throws {
        let mount = try SiteMounts.mount(hostPath: "example-plugin", containerPath: "wp-content/plugins/example", relativeTo: folder)
        XCTAssertEqual(mount, Mount(hostPath: folder.appendingPathComponent("example-plugin").path,
                                    containerPath: "/var/www/html/wp-content/plugins/example"))
    }

    func testMountRejectsMissingFoldersAndFiles() {
        XCTAssertThrowsError(try SiteMounts.mount(hostPath: "missing", containerPath: "wp-content/plugins/x", relativeTo: folder)) { error in
            XCTAssertEqual(error as? SiteMounts.Failure, .hostFolderMissing("missing"))
        }
        XCTAssertThrowsError(try SiteMounts.mount(hostPath: "file.txt", containerPath: "wp-content/plugins/x", relativeTo: folder)) { error in
            XCTAssertEqual(error as? SiteMounts.Failure, .hostFolderMissing("file.txt"))
        }
    }

    func testParseSplitsHostAndContainerPath() throws {
        let mount = try SiteMounts.parse("\(folder.path)/example-plugin:wp-content/plugins/example", relativeTo: folder)
        XCTAssertEqual(mount.containerPath, "/var/www/html/wp-content/plugins/example")
        XCTAssertThrowsError(try SiteMounts.parse("\(folder.path)/example-plugin", relativeTo: folder))
        XCTAssertThrowsError(try SiteMounts.parse("a:b:c", relativeTo: folder))
    }

    // MARK: - Adding and removing

    func testAddingOrdersShallowestFirstAndRefusesDuplicates() throws {
        let inner = Mount(hostPath: "/host/inner", containerPath: "/var/www/html/wp-content/plugins/example")
        let outer = Mount(hostPath: "/host/outer", containerPath: "/var/www/html/wp-content")
        let mounts = try SiteMounts.adding(outer, to: [inner])
        XCTAssertEqual(mounts, [outer, inner])
        XCTAssertThrowsError(try SiteMounts.adding(Mount(hostPath: "/host/other", containerPath: outer.containerPath), to: mounts)) { error in
            XCTAssertEqual(error as? SiteMounts.Failure, .alreadyMounted(outer.containerPath))
        }
    }

    func testRemovingByRelativeOrAbsolutePath() throws {
        let plugin = Mount(hostPath: "/host/plugin", containerPath: "/var/www/html/wp-content/plugins/example")
        let theme = Mount(hostPath: "/host/theme", containerPath: "/var/www/html/wp-content/themes/example")
        XCTAssertEqual(try SiteMounts.removing(containerPath: "wp-content/plugins/example", from: [plugin, theme]), [theme])
        XCTAssertEqual(try SiteMounts.removing(containerPath: theme.containerPath, from: [plugin, theme]), [plugin])
        XCTAssertThrowsError(try SiteMounts.removing(containerPath: "wp-content/mu-plugins", from: [plugin])) { error in
            XCTAssertEqual(error as? SiteMounts.Failure, .notMounted("/var/www/html/wp-content/mu-plugins"))
        }
    }

    func testRemovesOnlyAnEmptyMountpoint() throws {
        let plugins = folder.appendingPathComponent("wordpress/wp-content/plugins", isDirectory: true)
        try FileManager.default.createDirectory(at: plugins.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plugins.appendingPathComponent("kept"), withIntermediateDirectories: true)
        try Data().write(to: plugins.appendingPathComponent("kept/plugin.php"))
        let wordpress = folder.appendingPathComponent("wordpress", isDirectory: true)

        SiteMounts.removeEmptyMountpoint("/var/www/html/wp-content/plugins/empty", in: wordpress)
        SiteMounts.removeEmptyMountpoint("/var/www/html/wp-content/plugins/kept", in: wordpress)

        XCTAssertFalse(FileManager.default.fileExists(atPath: plugins.appendingPathComponent("empty").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: plugins.appendingPathComponent("kept/plugin.php").path))
    }
}
