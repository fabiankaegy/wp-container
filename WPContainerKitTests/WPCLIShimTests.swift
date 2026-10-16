import XCTest
@testable import WPContainerKit

/// Coverage for the generated wp-cli entry points (per-site shim, global router,
/// interactive Terminal command): each must mount the instance's `php/` folder,
/// pass the sidecar addresses, and stay valid shell.
final class WPCLIShimTests: XCTestCase {

    private let wordpress = URL(fileURLWithPath: "/tmp/Example Sites/example/wordpress", isDirectory: true)

    // MARK: - Per-site shim

    func testShimMountsThePHPFolderBesideWordPress() {
        let script = WPCLIShim.shimScript(slug: "example", wordpressFolder: wordpress, cliImage: "wordpress:cli")
        XCTAssertTrue(script.contains(#"PHP_DIR="/tmp/Example Sites/example/php""#))
        XCTAssertTrue(script.contains(#"-v "$PHP_DIR:\#(SiteRecipe.phpConfContainerPath)""#))
        XCTAssertTrue(script.contains("PHP_INI_SCAN_DIR=\(SiteRecipe.phpDefaultConfDir):\(SiteRecipe.phpConfContainerPath)"))
    }

    func testShimPassesSidecarAddresses() {
        let script = WPCLIShim.shimScript(slug: "example", wordpressFolder: wordpress, cliImage: "wordpress:cli")
        XCTAssertTrue(script.contains(#"MAIL_CONTAINER="wpc-example-mail""#))
        XCTAssertTrue(script.contains(#"ES_CONTAINER="wpc-example-es""#))
        XCTAssertTrue(script.contains(#"-e "WPC_MAILPIT_HOST=$MAIL_IP""#))
        XCTAssertTrue(script.contains(#"-e "EP_HOST=${ES_IP:+http://$ES_IP:9200}""#))
    }

    func testShimForAnInstanceUsesItsContainerNames() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wpc-shim-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let site = Site(name: "Example", slug: "example", path: root, port: 8881,
                        imageTag: SiteRecipe.defaultWordPressImage)

        let url = try WPCLIShim.writeShim(for: site, siteRoot: root, slug: site.slug)
        let script = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(script.contains(#"MAIL_CONTAINER="\#(site.mailContainerName)""#))
        XCTAssertTrue(script.contains(#"ES_CONTAINER="\#(site.esContainerName)""#))
        XCTAssertTrue(script.contains(#"PHP_DIR="\#(site.phpConfFolder.path)""#))
    }

    func testShimIsValidBash() throws {
        let script = WPCLIShim.shimScript(slug: "example", wordpressFolder: wordpress, cliImage: "wordpress:cli")
        try assertParses(script, shell: "/bin/bash")
    }

    // MARK: - Global router

    func testRouterPassesResolvedSidecarsAndPHPFolder() {
        let script = WPCLIShim.routerScript()
        XCTAssertTrue(script.contains(#"d.get("mailContainer", "")"#))
        XCTAssertTrue(script.contains(#"d.get("esContainer", "")"#))
        XCTAssertTrue(script.contains(#"d.get("phpConfPath", "")"#))
        XCTAssertTrue(script.contains(#"-v "$WPC_PHP:\#(SiteRecipe.phpConfContainerPath)""#))
        XCTAssertTrue(script.contains(#"-e "EP_HOST=${ES_IP:+http://$ES_IP:9200}""#))
    }

    func testRouterIsValidBash() throws {
        try assertParses(WPCLIShim.routerScript(), shell: "/bin/bash")
    }

    // MARK: - Terminal command

    func testTerminalCommandMountsPHPFolderAndPassesSidecars() {
        let command = WPCLIShim.interactiveTerminalCommand(slug: "example", wordpressFolder: wordpress)
        XCTAssertTrue(command.contains("-v '/tmp/Example Sites/example/php':\(SiteRecipe.phpConfContainerPath)"))
        XCTAssertTrue(command.contains("'wpc-example-mail'"))
        XCTAssertTrue(command.contains("'wpc-example-es'"))
        XCTAssertTrue(command.contains(#"-e "EP_HOST=${ES_IP:+http://$ES_IP:9200}""#))
    }

    func testTerminalCommandIsValidInBashAndZsh() throws {
        let command = WPCLIShim.interactiveTerminalCommand(slug: "example", wordpressFolder: wordpress)
        try assertParses(command, shell: "/bin/bash")
        try assertParses(command, shell: "/bin/zsh")
    }

    // MARK: - resolve-site

    func testResolverReportsSidecarsAndPHPFolder() throws {
        let root = URL(fileURLWithPath: "/tmp/wpc-resolver-example", isDirectory: true)
        let site = Site(name: "Example", slug: "example", path: root, port: 8881,
                        imageTag: SiteRecipe.defaultWordPressImage)
        let match = try XCTUnwrap(SiteResolver.resolve(path: site.wordpressFolder.path,
                                                       in: StoreEnvelope(sites: [site])))
        XCTAssertEqual(match.mailContainer, site.mailContainerName)
        XCTAssertEqual(match.esContainer, site.esContainerName)
        XCTAssertEqual(match.phpConfPath, site.phpConfFolder.path)
    }

    // MARK: - Helpers

    /// Runs `shell -n` (parse only, nothing executes) over `script`.
    private func assertParses(_ script: String, shell: String,
                              file: StaticString = #filePath, line: UInt = #line) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-n"]
        let input = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardError = errors
        try process.run()
        input.fileHandleForWriting.write(Data(script.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let stderr = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, "\(shell) -n failed: \(stderr)", file: file, line: line)
    }
}
