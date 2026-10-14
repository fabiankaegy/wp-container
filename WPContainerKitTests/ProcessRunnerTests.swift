import XCTest
@testable import WPContainerKit

/// Regression coverage for `ProcessRunner` under heavy parallelism: stopping a
/// site with dozens of branch envs fans out far more concurrent runs than GCD's
/// thread soft limit, which used to deadlock the runner for good.
final class ProcessRunnerTests: XCTestCase {

    func testManyConcurrentRunsComplete() {
        let count = 200
        let done = expectation(description: "\(count) concurrent runs finish")
        Task.detached {
            let outputs = await withTaskGroup(of: String.self) { group in
                for i in 0..<count {
                    group.addTask {
                        let result = try? await ProcessRunner.run(executable: "/bin/sh",
                                                                  args: ["-c", "sleep 0.2; echo \(i); echo err >&2"])
                        return result?.stdout ?? ""
                    }
                }
                var collected: [String] = []
                for await output in group { collected.append(output) }
                return collected
            }
            XCTAssertEqual(outputs.count, count)
            XCTAssertTrue(outputs.allSatisfy { !$0.isEmpty }, "every run captured its stdout")
            done.fulfill()
        }
        // Healthy: well under a second of wall time per batch. The old runner
        // never finished at all.
        wait(for: [done], timeout: 60)
    }

    func testCapturesStdoutStderrAndExitCode() async throws {
        let result = try await ProcessRunner.run(executable: "/bin/sh",
                                                 args: ["-c", "echo out; echo err >&2; exit 3"])
        XCTAssertEqual(result.stdout, "out\n")
        XCTAssertEqual(result.stderr, "err\n")
        XCTAssertEqual(result.exitCode, 3)
    }
}
