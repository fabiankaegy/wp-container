import XCTest
@testable import WPContainerKit

/// Coverage for importing into a worktree env: the scan that refuses dumps
/// which switch databases (they could write into the parent's schema on a
/// shared server), and the error that explains the fix.
final class DatabaseImportEnvTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wpc-import-env-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    // MARK: - Database switches

    func testFindsUseStatements() throws {
        let dump = try write("-- MySQL dump\n/*!40101 SET NAMES utf8 */;\nUSE `example_db`;\nCREATE TABLE `wp_posts` (id int);\n")
        XCTAssertEqual(DatabaseImportService.databaseSwitch(inDumpFile: dump), "USE `example_db`;")
    }

    func testFindsCreateAndDropDatabase() throws {
        let create = try write("CREATE DATABASE /*!32312 IF NOT EXISTS*/ `example_db`;\n")
        XCTAssertNotNil(DatabaseImportService.databaseSwitch(inDumpFile: create))
        let drop = try write("  drop schema if exists `example_db`;\n")
        XCTAssertNotNil(DatabaseImportService.databaseSwitch(inDumpFile: drop))
    }

    func testIgnoresTheWordInsideData() throws {
        let dump = try write("INSERT INTO `wp_posts` VALUES (1,'USE `other`; CREATE DATABASE x');\n-- use the force\n")
        XCTAssertNil(DatabaseImportService.databaseSwitch(inDumpFile: dump))
    }

    func testFindsASwitchAfterAVeryLongLine() throws {
        let longInsert = "INSERT INTO `wp_options` VALUES " + String(repeating: "(1,'example'),", count: 600_000) + "(2,'x');\n"
        let dump = try write(longInsert + "USE `example_db`;\n")
        XCTAssertEqual(DatabaseImportService.databaseSwitch(inDumpFile: dump), "USE `example_db`;")
    }

    func testFindsASwitchOnTheLastLineWithoutANewline() throws {
        let dump = try write("CREATE TABLE `wp_posts` (id int);\nUSE example_db;")
        XCTAssertEqual(DatabaseImportService.databaseSwitch(inDumpFile: dump), "USE example_db;")
    }

    func testCleanWpDbExportPasses() throws {
        let dump = try write("""
        -- MariaDB dump
        /*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
        DROP TABLE IF EXISTS `wp_options`;
        CREATE TABLE `wp_options` (`option_id` bigint(20));
        INSERT INTO `wp_options` VALUES (1,'home','https://example.com','yes');

        """)
        XCTAssertNil(DatabaseImportService.databaseSwitch(inDumpFile: dump))
    }

    func testErrorExplainsTheFix() {
        let message = DatabaseImportError.dumpSwitchesDatabase(statement: "USE `example_db`;").description
        XCTAssertTrue(message.contains("USE `example_db`;"))
        XCTAssertTrue(message.contains("without --databases"))
    }

    // MARK: - SQL errors

    func testFindsTheClientErrorLine() {
        let output = "--------------\nINSERT INTO x VALUES (1)\n--------------\n\n"
            + "ERROR 1146 (42S02) at line 2 in file: 'dump.sql': Table 'db.x' doesn't exist\n"
        XCTAssertEqual(DatabaseImportService.sqlError(in: output),
                       "ERROR 1146 (42S02) at line 2 in file: 'dump.sql': Table 'db.x' doesn't exist")
    }

    func testCleanImportOutputHasNoError() {
        XCTAssertNil(DatabaseImportService.sqlError(in: "Success: Imported from 'dump.sql'.\n"))
        XCTAssertNil(DatabaseImportService.sqlError(in: "Warning: ERROR handling is fine\n"))
    }

    // MARK: - Helpers

    private func write(_ contents: String) throws -> URL {
        let url = tempRoot.appendingPathComponent("\(UUID().uuidString).sql")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
