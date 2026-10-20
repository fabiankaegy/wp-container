import XCTest
@testable import WPContainerKit

private struct StubProvider: ShareProvider {
    let name = "stub"
    let randomURLsAreTemporary = false
    var readyMarker: String?

    func preflight() async throws {}
    func launchSpec(upstream: URL, hostname: String?, instanceSlug: String, tunnelName: String?) throws -> ShareLaunchSpec {
        fatalError("not used")
    }
    func publicURL(fromOutputLine line: String) -> String? {
        line.split(whereSeparator: \.isWhitespace).map(String.init).first { $0.hasPrefix("https://") || $0.hasPrefix("http://") }
    }
    func isReady(outputLine line: String) -> Bool {
        if let readyMarker { return line.contains(readyMarker) }
        return publicURL(fromOutputLine: line) != nil
    }
}

private final class ExitBox: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(Int32, [String])] = []
    func record(_ status: Int32, _ tail: [String]) { lock.withLock { recorded.append((status, tail)) } }
    var all: [(Int32, [String])] { lock.withLock { recorded } }
}

final class ShareProcessTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("share-process-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func script(_ body: String, environment: [String: String] = [:], fixedPublicURL: String? = nil) throws -> ShareLaunchSpec {
        let url = directory.appendingPathComponent("fixture-\(UUID().uuidString).sh")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return ShareLaunchSpec(executable: url, arguments: [], environment: environment, fixedPublicURL: fixedPublicURL)
    }

    private func isGone(_ pid: Int32) -> Bool {
        kill(pid, 0) != 0 && errno == ESRCH
    }

    func testStartReturnsFirstReportedURL() async throws {
        let spec = try script("echo starting\necho https://fixture.example.test\nexec sleep 60")
        let process = ShareProcess(spec: spec, provider: StubProvider())
        let url = try await process.start(readyTimeout: .seconds(10))
        XCTAssertEqual(url, "https://fixture.example.test")
        XCTAssertGreaterThan(process.pid, 0)
        await process.terminate(grace: .seconds(2))
    }

    func testURLOnStderrIsRecognized() async throws {
        let spec = try script("echo https://err.example.test >&2\nexec sleep 60")
        let process = ShareProcess(spec: spec, provider: StubProvider())
        let url = try await process.start(readyTimeout: .seconds(10))
        XCTAssertEqual(url, "https://err.example.test")
        await process.terminate(grace: .seconds(2))
    }

    func testFinalLineWithoutNewlineIsDelivered() async throws {
        let spec = try script("printf 'https://tail.example.test'")
        let process = ShareProcess(spec: spec, provider: StubProvider())
        let url = try await process.start(readyTimeout: .seconds(10))
        XCTAssertEqual(url, "https://tail.example.test")
    }

    func testPartialLinesAcrossReadsAreJoined() async throws {
        let spec = try script("printf 'https://spl'\nsleep 0.3\nprintf 'it.example.test\\n'\nexec sleep 60")
        let process = ShareProcess(spec: spec, provider: StubProvider())
        let url = try await process.start(readyTimeout: .seconds(10))
        XCTAssertEqual(url, "https://split.example.test")
        await process.terminate(grace: .seconds(2))
    }

    func testFixedPublicURLReturnedOnReadiness() async throws {
        let spec = try script("echo connecting\necho READY\nexec sleep 60", fixedPublicURL: "https://fixed.example.test")
        let process = ShareProcess(spec: spec, provider: StubProvider(readyMarker: "READY"))
        let url = try await process.start(readyTimeout: .seconds(10))
        XCTAssertEqual(url, "https://fixed.example.test")
        await process.terminate(grace: .seconds(2))
    }

    func testEnvironmentIsMergedOverInherited() async throws {
        let spec = try script("echo \"https://$WPC_TEST_VAR.example.test/$(test -n \"$HOME\" && echo home)\"\nexec sleep 60", environment: ["WPC_TEST_VAR": "merged"])
        let process = ShareProcess(spec: spec, provider: StubProvider())
        let url = try await process.start(readyTimeout: .seconds(10))
        XCTAssertEqual(url, "https://merged.example.test/home")
        await process.terminate(grace: .seconds(2))
    }

    func testStartTimesOutWithStderrTail() async throws {
        let spec = try script("echo boom >&2\nexec sleep 60")
        let process = ShareProcess(spec: spec, provider: StubProvider())
        do {
            _ = try await process.start(readyTimeout: .seconds(1))
            XCTFail("expected timeout")
        } catch ShareError.providerTimedOut(let tail) {
            XCTAssertEqual(tail, ["boom"])
        }
        await process.terminate(grace: .seconds(2))
        XCTAssertTrue(isGone(process.pid))
    }

    func testEarlyExitIsReported() async throws {
        let spec = try script("echo oops >&2\nexit 3")
        let process = ShareProcess(spec: spec, provider: StubProvider())
        do {
            _ = try await process.start(readyTimeout: .seconds(10))
            XCTFail("expected exit")
        } catch ShareError.providerExited(let status, let tail) {
            XCTAssertEqual(status, 3)
            XCTAssertEqual(tail, ["oops"])
        }
    }

    func testTerminateEscalatesToKill() async throws {
        let spec = try script("trap '' TERM\necho https://stubborn.example.test\nwhile true; do sleep 1; done")
        let process = ShareProcess(spec: spec, provider: StubProvider())
        _ = try await process.start(readyTimeout: .seconds(10))
        let box = ExitBox()
        process.onExit = { status, tail in box.record(status, tail) }
        await process.terminate(grace: .milliseconds(200))
        XCTAssertTrue(isGone(process.pid))
        XCTAssertEqual(box.all.count, 1)
        await process.terminate(grace: .milliseconds(200))
        XCTAssertEqual(box.all.count, 1)
    }

    func testTerminateStopsProcessWithSIGTERM() async throws {
        let spec = try script("echo https://polite.example.test\nexec sleep 60")
        let process = ShareProcess(spec: spec, provider: StubProvider())
        _ = try await process.start(readyTimeout: .seconds(10))
        await process.terminate(grace: .seconds(5))
        XCTAssertTrue(isGone(process.pid))
    }

    func testOnExitFiresAfterLive() async throws {
        let spec = try script("echo https://brief.example.test\necho late >&2\nsleep 0.5\nexit 0")
        let process = ShareProcess(spec: spec, provider: StubProvider())
        let fired = expectation(description: "onExit")
        let box = ExitBox()
        process.onExit = { status, tail in
            box.record(status, tail)
            fired.fulfill()
        }
        _ = try await process.start(readyTimeout: .seconds(10))
        await fulfillment(of: [fired], timeout: 10)
        XCTAssertEqual(box.all.count, 1)
        XCTAssertEqual(box.all.first?.0, 0)
        XCTAssertEqual(box.all.first?.1, ["late"])
    }

    func testStderrTailKeepsLastTwentyLines() async throws {
        let spec = try script("i=1\nwhile [ $i -le 30 ]; do echo line$i >&2; i=$((i+1)); done\nexit 4")
        let process = ShareProcess(spec: spec, provider: StubProvider())
        do {
            _ = try await process.start(readyTimeout: .seconds(10))
            XCTFail("expected exit")
        } catch ShareError.providerExited(_, let tail) {
            XCTAssertEqual(tail.count, 20)
            XCTAssertEqual(tail.first, "line11")
            XCTAssertEqual(tail.last, "line30")
        }
    }
}
