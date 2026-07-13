import Foundation

/// Typed error carrying the failed command's exit code and stderr.
public struct ContainerCLIError: Error, Sendable, CustomStringConvertible {
    public let command: [String]
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public var description: String {
        let detail = stderr.isEmpty ? stdout : stderr
        return "`container \(command.joined(separator: " "))` failed (exit \(exitCode)): \(detail.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
}

/// Actor wrapping every invocation of `/usr/local/bin/container`.
/// All calls are argument-array based — never `sh -c` string interpolation.
public actor ContainerCLI {
    public static let defaultBinaryPath = "/usr/local/bin/container"

    /// Immutable Sendable `let` — safe to read from `nonisolated` context.
    public let binaryPath: String

    public init(binaryPath: String = ContainerCLI.defaultBinaryPath) {
        self.binaryPath = binaryPath
    }

    /// Run and return stdout, throwing `ContainerCLIError` on non-zero exit.
    @discardableResult
    public func run(_ args: [String]) async throws -> String {
        let result = try await ProcessRunner.run(executable: binaryPath, args: args)
        guard result.exitCode == 0 else {
            throw ContainerCLIError(command: args, exitCode: result.exitCode,
                                    stdout: result.stdout, stderr: result.stderr)
        }
        return result.stdout
    }

    /// Run and return the full result without throwing on non-zero exit.
    public func runCapturing(_ args: [String]) async throws -> CommandResult {
        try await ProcessRunner.run(executable: binaryPath, args: args)
    }

    // MARK: - JSON helpers

    /// `container list [--all] --format json`, defensively decoded.
    public func list(all: Bool = true) async throws -> [ContainerRecord] {
        var args = ["list", "--format", "json"]
        if all { args.append("--all") }
        let out = try await run(args)
        return try ContainerRecord.decodeList(from: Data(out.utf8))
    }

    /// `container inspect <name>`, defensively decoded (returns [] if absent).
    public func inspect(_ name: String) async throws -> [ContainerRecord] {
        let result = try await runCapturing(["inspect", name])
        guard result.succeeded else { return [] }
        return try ContainerRecord.decodeList(from: Data(result.stdout.utf8))
    }

    /// First IP address found by inspecting a container, if any.
    public func ipAddress(of name: String) async throws -> String? {
        try await inspect(name).first?.ipAddress
    }

    /// The network gateway (host address as seen from the container) — used for
    /// Xdebug's `client_host` (PLAN.md §2c). Read fresh each start, never cached.
    public func gatewayAddress(of name: String) async throws -> String? {
        try await inspect(name).first?.gatewayAddress
    }

    // MARK: - Image availability

    /// Whether an image tag can be pulled/resolved. Used to pre-check a chosen
    /// WP×PHP tag before creating a site (PLAN.md §2k). Best-effort: a zero exit
    /// from `image pull` means the tag exists.
    public func imageExists(_ tag: String) async -> Bool {
        // A locally-present image resolves instantly; otherwise this pulls it.
        let result = try? await runCapturing(["image", "pull", tag])
        return result?.exitCode == 0
    }

    /// Whether an image tag is already present in the local image store (no pull).
    /// Used to gate the lazy Xdebug derived-image build (PLAN.md §2c).
    public func localImageExists(_ tag: String) async -> Bool {
        let result = try? await runCapturing(["image", "inspect", tag])
        return result?.exitCode == 0
    }

    // MARK: - Streaming logs

    /// Streaming variant of `container logs [--follow] <name>` yielding one line
    /// per element. Cancelling the consuming task (or the stream terminating)
    /// terminates the child process. `nonisolated` because it only reads the
    /// immutable `binaryPath`.
    public nonisolated func logs(name: String, follow: Bool = true) -> AsyncThrowingStream<String, Error> {
        let executable = binaryPath
        return AsyncThrowingStream { continuation in
            let proc = ProcBox()
            continuation.onTermination = { _ in proc.terminate() }

            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                var args = ["logs"]
                if follow { args.append("--follow") }
                args.append(name)
                process.arguments = args

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                let fd = pipe.fileHandleForReading.fileDescriptor

                do {
                    try process.run()
                } catch {
                    continuation.finish(throwing: error)
                    return
                }
                proc.setPID(process.processIdentifier)

                var buffer = Data()
                let bufferSize = 65_536
                var chunk = [UInt8](repeating: 0, count: bufferSize)
                let newline: UInt8 = 0x0A
                while true {
                    let n = read(fd, &chunk, bufferSize)
                    if n > 0 {
                        buffer.append(chunk, count: n)
                        while let idx = buffer.firstIndex(of: newline) {
                            let lineData = buffer[buffer.startIndex..<idx]
                            continuation.yield(String(decoding: lineData, as: UTF8.self))
                            buffer.removeSubrange(buffer.startIndex...idx)
                        }
                    } else if n == 0 {
                        break
                    } else {
                        if errno == EINTR { continue }
                        break
                    }
                }
                if !buffer.isEmpty {
                    continuation.yield(String(decoding: buffer, as: UTF8.self))
                }
                process.waitUntilExit()
                // The child exited naturally — clear the recorded pid BEFORE
                // finishing so the stream's onTermination handler can't SIGTERM
                // a recycled pid belonging to an unrelated process (#8).
                proc.clearPID()
                _ = pipe
                continuation.finish()
            }
        }
    }
}

/// Sendable holder for a child pid so the stream's `onTermination` handler can
/// signal the process without capturing the non-Sendable `Process`.
final class ProcBox: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t = 0
    func setPID(_ p: pid_t) { lock.lock(); pid = p; lock.unlock() }
    /// Forget the pid once the child has exited naturally, so a later
    /// `terminate()` (stream teardown) can never signal a recycled pid (#8).
    func clearPID() { lock.lock(); pid = 0; lock.unlock() }
    func terminate() {
        lock.lock(); let p = pid; lock.unlock()
        if p > 0 { kill(p, SIGTERM) }
    }
}
