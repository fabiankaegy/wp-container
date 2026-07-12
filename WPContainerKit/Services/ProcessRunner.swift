import Foundation

/// Result of running an external process.
public struct CommandResult: Sendable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public var succeeded: Bool { exitCode == 0 }

    public init(stdout: String, stderr: String, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

/// Thread-safe mutable box for shuttling captured output off background queues.
final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    func set(_ data: Data) { lock.lock(); storage = data; lock.unlock() }
    var data: Data { lock.lock(); defer { lock.unlock() }; return storage }
}

/// Low-level `Process` launcher shared by `ContainerCLI`, `GitService`, and the
/// CoW clone step. Argument-array based (never a shell string).
///
/// stdout and stderr are drained on *separate* background threads to avoid the
/// classic pipe-buffer deadlock on large output, and the whole blocking dance
/// runs off the calling actor via a continuation so no cooperative thread is
/// blocked.
public enum ProcessRunner {
    public static func run(
        executable: String,
        args: [String],
        cwd: URL? = nil,
        environment: [String: String]? = nil
    ) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CommandResult, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = args
                if let cwd { process.currentDirectoryURL = cwd }
                if let environment { process.environment = environment }

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                do {
                    try process.run()
                } catch {
                    cont.resume(throwing: error)
                    return
                }

                let outBox = DataBox()
                let errBox = DataBox()
                let outFD = outPipe.fileHandleForReading.fileDescriptor
                let errFD = errPipe.fileHandleForReading.fileDescriptor

                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    outBox.set(drain(fd: outFD))
                    group.leave()
                }
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    errBox.set(drain(fd: errFD))
                    group.leave()
                }
                group.wait()
                process.waitUntilExit()
                // Keep the pipes alive until draining completes.
                _ = outPipe
                _ = errPipe

                cont.resume(returning: CommandResult(
                    stdout: String(decoding: outBox.data, as: UTF8.self),
                    stderr: String(decoding: errBox.data, as: UTF8.self),
                    exitCode: process.terminationStatus
                ))
            }
        }
    }

    /// Blocking read of a file descriptor to EOF, tolerant of EINTR.
    static func drain(fd: Int32) -> Data {
        var data = Data()
        let bufferSize = 65_536
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while true {
            let n = read(fd, &buffer, bufferSize)
            if n > 0 {
                data.append(buffer, count: n)
            } else if n == 0 {
                break // EOF
            } else {
                if errno == EINTR { continue }
                break
            }
        }
        return data
    }
}
