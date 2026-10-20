import XCTest
@testable import WPContainerKit

final class ShareProviderTests: XCTestCase {
    private var dir: URL!
    private let upstream = URL(string: "http://127.0.0.1:8123")!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("share-provider-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    @discardableResult
    private func makeScript(_ name: String, body: String, in directory: URL? = nil) throws -> URL {
        let url = (directory ?? dir).appendingPathComponent(name)
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func testNgrokLaunchSpecWithoutHostname() throws {
        try makeScript("ngrok", body: "exit 0")
        let spec = try NgrokProvider(searchPath: [dir]).launchSpec(upstream: upstream, hostname: nil, instanceSlug: "my-site", tunnelName: nil)
        XCTAssertEqual(spec.arguments, ["http", "http://127.0.0.1:8123", "--log", "stdout", "--log-format", "json"])
        XCTAssertNil(spec.fixedPublicURL)
    }

    func testNgrokLaunchSpecWithHostname() throws {
        try makeScript("ngrok", body: "exit 0")
        let spec = try NgrokProvider(searchPath: [dir]).launchSpec(upstream: upstream, hostname: "my.ngrok.app", instanceSlug: "my-site", tunnelName: nil)
        XCTAssertEqual(Array(spec.arguments.suffix(2)), ["--url", "https://my.ngrok.app"])
    }

    func testNgrokParsesStartedTunnelLine() {
        let provider = NgrokProvider(searchPath: [])
        XCTAssertEqual(
            provider.publicURL(fromOutputLine: #"{"lvl":"info","msg":"started tunnel","url":"https://abc.ngrok-free.app"}"#),
            "https://abc.ngrok-free.app"
        )
        XCTAssertNil(provider.publicURL(fromOutputLine: #"{"lvl":"info","msg":"client session established"}"#))
        XCTAssertNil(provider.publicURL(fromOutputLine: "not json"))
    }

    func testNgrokPreflightReportsMissingBinary() async {
        do {
            try await NgrokProvider(searchPath: []).preflight()
            XCTFail("expected error")
        } catch let ShareError.providerMissingBinary(name, install) {
            XCTAssertEqual(name, "ngrok")
            XCTAssertEqual(install, "brew install ngrok")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testNgrokPreflightReportsMissingAuthtoken() async throws {
        let config = dir.appendingPathComponent("ngrok.yml")
        try "version: \"3\"\nagent:\n  web_addr: false\n".write(to: config, atomically: true, encoding: .utf8)
        try makeScript("ngrok", body: "echo \"Valid configuration file at \(config.path)\"")
        let provider = NgrokProvider(searchPath: [dir], environment: [:], configCandidates: [])
        do {
            try await provider.preflight()
            XCTFail("expected error")
        } catch let error as ShareError {
            guard case .ngrokNotAuthenticated = error else { return XCTFail("unexpected \(error)") }
            XCTAssertTrue(error.description.contains("ngrok config add-authtoken <token>"))
        }
    }

    func testNgrokPreflightAcceptsAuthtokenInConfigOrEnvironment() async throws {
        let config = dir.appendingPathComponent("ngrok.yml")
        try "version: \"3\"\nagent:\n  authtoken: fake-token\n".write(to: config, atomically: true, encoding: .utf8)
        try makeScript("ngrok", body: "echo \"Valid configuration file at \(config.path)\"")
        try await NgrokProvider(searchPath: [dir], environment: [:], configCandidates: []).preflight()

        let bare = dir.appendingPathComponent("bare")
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        try makeScript("ngrok", body: "exit 1", in: bare)
        try await NgrokProvider(searchPath: [bare], environment: ["NGROK_AUTHTOKEN": "fake"], configCandidates: []).preflight()
    }

    func testCloudflaredQuickTunnelSpecAndParse() throws {
        try makeScript("cloudflared", body: "exit 0")
        let provider = CloudflaredProvider(searchPath: [dir])
        let spec = try provider.launchSpec(upstream: upstream, hostname: nil, instanceSlug: "my-site", tunnelName: nil)
        XCTAssertEqual(spec.arguments, ["tunnel", "--url", "http://127.0.0.1:8123"])
        XCTAssertNil(spec.fixedPublicURL)
        XCTAssertTrue(provider.randomURLsAreTemporary)
        let line = "2026-01-01T00:00:00Z INF |  https://red-fox-12.trycloudflare.com  |"
        XCTAssertEqual(provider.publicURL(fromOutputLine: line), "https://red-fox-12.trycloudflare.com")
        XCTAssertTrue(provider.isReady(outputLine: line))
        XCTAssertNil(provider.publicURL(fromOutputLine: #"ERR Post "https://api.trycloudflare.com/tunnel": EOF"#))
    }

    func testCloudflaredNamedTunnelSpec() throws {
        try makeScript("cloudflared", body: "exit 0")
        let provider = CloudflaredProvider(searchPath: [dir])
        let spec = try provider.launchSpec(upstream: upstream, hostname: "share.example.com", instanceSlug: "my-site", tunnelName: "wpc-my-site")
        XCTAssertEqual(spec.arguments, ["tunnel", "run", "--url", "http://127.0.0.1:8123", "wpc-my-site"])
        XCTAssertEqual(spec.fixedPublicURL, "https://share.example.com")
        XCTAssertTrue(provider.isReady(outputLine: "INF Registered tunnel connection connIndex=0 location=lis01"))
        XCTAssertFalse(provider.isReady(outputLine: "INF Starting tunnel"))
    }

    func testCloudflaredPreflightReportsMissingBinary() async {
        do {
            try await CloudflaredProvider(searchPath: []).preflight()
            XCTFail("expected error")
        } catch let ShareError.providerMissingBinary(name, install) {
            XCTAssertEqual(name, "cloudflared")
            XCTAssertEqual(install, "brew install cloudflared")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testScriptProviderEnvironment() throws {
        let script = try makeScript("custom", body: "exit 0")
        let provider = ScriptProvider(name: "custom", executable: script)
        let spec = try provider.launchSpec(upstream: upstream, hostname: nil, instanceSlug: "my-site", tunnelName: nil)
        XCTAssertEqual(spec.environment, [
            "WPC_SHARE_UPSTREAM": "http://127.0.0.1:8123",
            "WPC_SHARE_HOSTNAME": "",
            "WPC_SHARE_INSTANCE": "my-site",
        ])
        XCTAssertEqual(provider.publicURL(fromOutputLine: "tunnel up at https://x.example.com/ now"), "https://x.example.com")
        XCTAssertNil(provider.publicURL(fromOutputLine: "starting"))
    }

    func testResolveCustomProviderByName() throws {
        let custom = dir.appendingPathComponent("custom-dir")
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        try makeScript("mytunnel", body: "exit 0", in: custom)
        let provider = try ShareProviders.resolve("mytunnel", searchPath: [], customDirectory: custom)
        XCTAssertEqual(provider.name, "mytunnel")
        XCTAssertTrue(try ShareProviders.resolve("ngrok", searchPath: [], customDirectory: custom) is NgrokProvider)
        XCTAssertTrue(try ShareProviders.resolve("cloudflared", searchPath: [], customDirectory: custom) is CloudflaredProvider)
    }

    func testResolveUnknownProviderFails() throws {
        let custom = dir.appendingPathComponent("custom-dir")
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        let plain = custom.appendingPathComponent("plain")
        try "x".write(to: plain, atomically: true, encoding: .utf8)
        for name in ["nope", "plain", "../x", ""] {
            XCTAssertThrowsError(try ShareProviders.resolve(name, searchPath: [], customDirectory: custom)) { error in
                guard case ShareError.providerNotFound = error else { return XCTFail("unexpected \(error)") }
            }
        }
    }

    func testNgrokRejectsUnsafePublicURLs() {
        let provider = NgrokProvider(searchPath: [])
        let urls = [
            "http://", "https://", "https://u:p@abc.ngrok-free.app", "tcp://0.tcp.ngrok.io:1234",
            "http://abc.ngrok-free.app", "https://abc.ngrok-free.app/path", "https://abc.ngrok-free.app?x=1",
            "https://abc.ngrok-free.app\\r\\nX-Evil: 1", "https://abc.ngrok-free.app\\t",
        ]
        for url in urls {
            let line = #"{"msg":"started tunnel","url":""# + url + #""}"#
            XCTAssertNil(provider.publicURL(fromOutputLine: line), url)
        }
        XCTAssertEqual(
            provider.publicURL(fromOutputLine: #"{"msg":"started tunnel","url":"https://abc.ngrok-free.app/"}"#),
            "https://abc.ngrok-free.app"
        )
    }

    func testCloudflaredRejectsUnsafePublicURLs() {
        let provider = CloudflaredProvider(searchPath: [])
        let lines = [
            "http://", "https://", "https://u:p@red-fox-12.trycloudflare.com", "http://red-fox-12.trycloudflare.com",
            "https://red-fox-12.trycloudflare.com/path", "https://red-fox-12.trycloudflare.com?x=1",
            "https://red-fox-12.trycloudflare.com:8443", "https://evil.example.com", "tcp://red-fox-12.trycloudflare.com",
        ]
        for line in lines {
            XCTAssertNil(provider.publicURL(fromOutputLine: "| \(line) |"), line)
        }
    }

    func testScriptProviderValidatesURLs() {
        let provider = ScriptProvider(name: "custom", executable: dir)
        XCTAssertEqual(provider.publicURL(fromOutputLine: "http://127.0.0.1:8123"), "http://127.0.0.1:8123")
        XCTAssertNil(provider.publicURL(fromOutputLine: "http://"))
        XCTAssertNil(provider.publicURL(fromOutputLine: "https://u:p@example.com"))
        XCTAssertNil(provider.publicURL(fromOutputLine: "https://example.com/path"))
        XCTAssertNil(provider.publicURL(fromOutputLine: "https://example.com?x=1"))
        XCTAssertNil(provider.publicURL(fromOutputLine: "tcp://example.com"))
    }

    func testCloudflaredHostnameWithoutTunnelNameThrows() throws {
        try makeScript("cloudflared", body: "exit 0")
        let provider = CloudflaredProvider(searchPath: [dir])
        XCTAssertThrowsError(try provider.launchSpec(upstream: upstream, hostname: "share.example.com", instanceSlug: "my-site", tunnelName: nil)) { error in
            guard case ShareError.cloudflaredTunnelNameRequired = error else { return XCTFail("unexpected \(error)") }
        }
    }

    func testLaunchSpecRejectsInvalidHostnameAndTunnelName() throws {
        try makeScript("cloudflared", body: "exit 0")
        try makeScript("ngrok", body: "exit 0")
        let cf = CloudflaredProvider(searchPath: [dir])
        let ng = NgrokProvider(searchPath: [dir])
        let badHosts = ["https://share.example.com", "share.example.com:8080", "-a.example.com", "a-.example.com", "a..example.com", "a b.example.com", "", String(repeating: "a", count: 254)]
        for host in badHosts where !host.isEmpty {
            XCTAssertThrowsError(try ng.launchSpec(upstream: upstream, hostname: host, instanceSlug: "s", tunnelName: nil), host) { error in
                guard case ShareError.invalidShareHostname(let value) = error else { return XCTFail("unexpected \(error)") }
                XCTAssertEqual(value, host)
            }
            XCTAssertThrowsError(try cf.launchSpec(upstream: upstream, hostname: host, instanceSlug: "s", tunnelName: "wpc-s"), host)
        }
        for name in ["--evil", "-x", "a b", "a/b", "a\nb"] {
            XCTAssertThrowsError(try cf.launchSpec(upstream: upstream, hostname: "share.example.com", instanceSlug: "s", tunnelName: name), name) { error in
                guard case ShareError.invalidTunnelName(let value) = error else { return XCTFail("unexpected \(error)") }
                XCTAssertEqual(value, name)
            }
        }
    }

    func testCustomDirectoryNeverShadowsBuiltIns() throws {
        let custom = dir.appendingPathComponent("custom-dir")
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        try makeScript("ngrok", body: "exit 0", in: custom)
        try makeScript("cloudflared", body: "exit 0", in: custom)
        XCTAssertTrue(try ShareProviders.resolve("ngrok", searchPath: [], customDirectory: custom) is NgrokProvider)
        XCTAssertTrue(try ShareProviders.resolve("cloudflared", searchPath: [], customDirectory: custom) is CloudflaredProvider)
    }
}
