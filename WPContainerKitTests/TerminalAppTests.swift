import XCTest
@testable import WPContainerKit

/// Coverage for the terminal-app scripts the Terminal buttons run: version
/// gating, string escaping, and scripts that compile against each app's
/// AppleScript dictionary.
final class TerminalAppTests: XCTestCase {

    private let command = #"cd '/tmp/Example Sites/x'; export PATH='/tmp/x':"$PATH"; echo "a\b"; clear"#

    // MARK: - Version gating

    func testTerminalSupportsEveryVersion() {
        XCTAssertTrue(TerminalApp.terminal.supports(version: nil))
    }

    func testGhosttyNeedsAppleScriptSupport() {
        XCTAssertTrue(TerminalApp.ghostty.supports(version: "1.3.0"))
        XCTAssertTrue(TerminalApp.ghostty.supports(version: "1.10.2"))
        XCTAssertFalse(TerminalApp.ghostty.supports(version: "1.2.3"))
        XCTAssertFalse(TerminalApp.ghostty.supports(version: nil))
    }

    func testITermNeedsVersion3() {
        XCTAssertTrue(TerminalApp.iterm.supports(version: "3.5.14"))
        XCTAssertFalse(TerminalApp.iterm.supports(version: "2.1.4"))
    }

    // MARK: - Scripts

    func testStringLiteralRoundTripsThroughAppleScript() throws {
        let output = try osascript("return " + TerminalApp.appleScriptString(command))
        XCTAssertEqual(output.trimmingCharacters(in: .newlines), command)
    }

    func testTerminalScriptRunsTheCommand() throws {
        let script = TerminalApp.terminal.openScript(running: command)
        XCTAssertTrue(script.contains("do script \(TerminalApp.appleScriptString(command))"))
        try assertCompiles(script)
    }

    func testGhosttyScriptTypesTheCommandIntoANewWindow() throws {
        let script = TerminalApp.ghostty.openScript(running: command)
        XCTAssertTrue(script.contains("set initial input of cfg to \(TerminalApp.appleScriptString(command)) & linefeed"))
        XCTAssertTrue(script.contains("new window with configuration cfg"))
        let ghostty = URL(fileURLWithPath: "/Applications/Ghostty.app")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: ghostty.path), "Ghostty is not installed")
        try assertCompiles(script)
    }

    func testITermScriptWritesTheCommandToANewWindow() throws {
        let script = TerminalApp.iterm.openScript(running: command)
        XCTAssertTrue(script.contains(#"tell application id "com.googlecode.iterm2""#))
        XCTAssertTrue(script.contains("create window with default profile"))
        XCTAssertTrue(script.contains("write text \(TerminalApp.appleScriptString(command))"))
        let iterm = URL(fileURLWithPath: "/Applications/iTerm.app")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: iterm.path), "iTerm2 is not installed")
        try assertCompiles(script)
    }

    // MARK: - Helpers

    /// Compiles `script` without running it, which resolves the target app's
    /// AppleScript terms.
    private func assertCompiles(_ script: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("wpc-terminal-\(UUID().uuidString).scpt")
        defer { try? FileManager.default.removeItem(at: output) }
        let result = try execute("/usr/bin/osacompile", ["-o", output.path, "-e", script])
        XCTAssertEqual(result.status, 0, "osacompile failed: \(result.stderr)", file: file, line: line)
    }

    private func osascript(_ script: String) throws -> String {
        let result = try execute("/usr/bin/osascript", ["-e", script])
        XCTAssertEqual(result.status, 0, result.stderr)
        return result.stdout
    }

    private func execute(_ executable: String, _ args: [String]) throws -> (stdout: String, stderr: String, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(data: stdout, encoding: .utf8) ?? "", String(data: stderr, encoding: .utf8) ?? "", process.terminationStatus)
    }
}
