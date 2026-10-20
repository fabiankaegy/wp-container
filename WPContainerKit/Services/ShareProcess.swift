import Foundation

/// Runs one tunnel provider process: reads its output until it reports a public URL, reports
/// its exit, and stops it with SIGTERM followed by SIGKILL.
public final class ShareProcess: @unchecked Sendable {
    /// Called once when the process exits, with its status and the last stderr lines.
    public var onExit: (@Sendable (_ status: Int32, _ stderrTail: [String]) -> Void)? {
        get { lock.withLock { exitHandler } }
        set { lock.withLock { exitHandler = newValue } }
    }

    public var pid: Int32 { lock.withLock { processID } }

    private static let stderrTailLimit = 20

    private let spec: ShareLaunchSpec
    private let provider: any ShareProvider
    private let lock = NSLock()
    private let process = Process()
    private var exitHandler: (@Sendable (Int32, [String]) -> Void)?
    private var processID: Int32 = 0
    private var started = false
    private var exited = false
    private var startContinuation: CheckedContinuation<String, Error>?
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var stderrTail: [String] = []
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?

    public init(spec: ShareLaunchSpec, provider: any ShareProvider) {
        self.spec = spec
        self.provider = provider
    }

    /// Launches the process and returns the public URL: `spec.fixedPublicURL` once the provider
    /// reports readiness, otherwise the first URL it announces.
    public func start(readyTimeout: Duration = .seconds(30)) async throws -> String {
        let timeout = Task { [weak self] in
            try await Task.sleep(for: readyTimeout)
            self?.settleStart(throwing: { tail in ShareError.providerTimedOut(stderrTail: tail) })
        }
        defer { timeout.cancel() }
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                    launch(continuation)
                }
            } onCancel: {
                self.settleStart(throwing: { _ in CancellationError() })
            }
        } catch {
            await terminate(grace: .seconds(2))
            throw error
        }
    }

    /// Sends SIGTERM, then SIGKILL once `grace` has passed. Returns after the process has exited.
    public func terminate(grace: Duration = .seconds(5)) async {
        let target: Int32? = lock.withLock { started && !exited ? processID : nil }
        guard let target else { return }
        kill(target, SIGTERM)
        if await waitForExit(within: grace) { return }
        kill(target, SIGKILL)
        _ = await waitForExit(within: .seconds(5))
    }

    private func launch(_ continuation: CheckedContinuation<String, Error>) {
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = spec.executable
        process.arguments = spec.arguments
        process.environment = ProcessInfo.processInfo.environment.merging(spec.environment) { _, new in new }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        process.terminationHandler = { [weak self] finished in
            self?.handleTermination(status: finished.terminationStatus)
        }

        lock.withLock {
            startContinuation = continuation
            stdoutHandle = stdout.fileHandleForReading
            stderrHandle = stderr.fileHandleForReading
        }
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData, isStderr: false)
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData, isStderr: true)
        }

        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            try? stdout.fileHandleForReading.close()
            try? stderr.fileHandleForReading.close()
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()
            lock.withLock {
                exited = true
                startContinuation = nil
            }
            continuation.resume(throwing: error)
            return
        }
        lock.withLock {
            processID = process.processIdentifier
            started = true
        }
    }

    private func consume(_ data: Data, isStderr: Bool) {
        if data.isEmpty {
            // EOF: stop polling this pipe; the remainder is flushed on termination.
            let handle = lock.withLock { isStderr ? stderrHandle : stdoutHandle }
            handle?.readabilityHandler = nil
            return
        }
        let lines: [String] = lock.withLock {
            var buffer = isStderr ? stderrBuffer : stdoutBuffer
            buffer.append(data)
            let result = Self.extractLines(from: &buffer)
            if isStderr { stderrBuffer = buffer } else { stdoutBuffer = buffer }
            return result
        }
        for line in lines { handle(line: line, isStderr: isStderr) }
    }

    private func handle(line: String, isStderr: Bool) {
        let pending: (continuation: CheckedContinuation<String, Error>, url: String)? = lock.withLock {
            if isStderr {
                stderrTail.append(line)
                if stderrTail.count > Self.stderrTailLimit { stderrTail.removeFirst(stderrTail.count - Self.stderrTailLimit) }
            }
            guard let continuation = startContinuation else { return nil }
            let announced = provider.publicURL(fromOutputLine: line)
            let url: String?
            if let fixed = spec.fixedPublicURL {
                url = provider.isReady(outputLine: line) ? fixed : nil
            } else {
                url = announced
            }
            guard let url else { return nil }
            startContinuation = nil
            return (continuation, url)
        }
        if let pending { pending.continuation.resume(returning: pending.url) }
    }

    private func handleTermination(status: Int32) {
        // Read what the pipes still hold, then release the handles.
        let (out, err) = lock.withLock { (stdoutHandle, stderrHandle) }
        out?.readabilityHandler = nil
        err?.readabilityHandler = nil
        let outRest = out.map(Self.drain) ?? Data()
        let errRest = err.map(Self.drain) ?? Data()
        try? out?.close()
        try? err?.close()

        let lines: [(String, Bool)] = lock.withLock {
            stdoutBuffer.append(outRest)
            stderrBuffer.append(errRest)
            var result = Self.extractLines(from: &stdoutBuffer).map { ($0, false) }
            result += Self.extractLines(from: &stderrBuffer).map { ($0, true) }
            for (buffer, isStderr) in [(stdoutBuffer, false), (stderrBuffer, true)] where !buffer.isEmpty {
                result.append((String(decoding: buffer, as: UTF8.self), isStderr))
            }
            stdoutBuffer = Data()
            stderrBuffer = Data()
            return result
        }
        for (line, isStderr) in lines { handle(line: line, isStderr: isStderr) }

        let (tail, handler, continuation): ([String], (@Sendable (Int32, [String]) -> Void)?, CheckedContinuation<String, Error>?) = lock.withLock {
            exited = true
            let continuation = startContinuation
            startContinuation = nil
            stdoutHandle = nil
            stderrHandle = nil
            return (stderrTail, exitHandler, continuation)
        }
        continuation?.resume(throwing: ShareError.providerExited(status: status, stderrTail: tail))
        handler?(status, tail)
    }

    private func settleStart(throwing makeError: ([String]) -> Error) {
        let (continuation, tail): (CheckedContinuation<String, Error>?, [String]) = lock.withLock {
            let continuation = startContinuation
            startContinuation = nil
            return (continuation, stderrTail)
        }
        continuation?.resume(throwing: makeError(tail))
    }

    private func waitForExit(within duration: Duration) async -> Bool {
        let deadline = ContinuousClock.now + duration
        while ContinuousClock.now < deadline {
            if lock.withLock({ exited }) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return lock.withLock { exited }
    }

    private static func extractLines(from buffer: inout Data) -> [String] {
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var lineData = buffer[buffer.startIndex..<newline]
            if lineData.last == 0x0D { lineData = lineData.dropLast() }
            lines.append(String(decoding: lineData, as: UTF8.self))
            buffer = Data(buffer[buffer.index(after: newline)...])
        }
        return lines
    }

    /// Reads whatever is buffered without waiting on a writer that is still alive (a child of the provider).
    private static func drain(_ handle: FileHandle) -> Data {
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        var result = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(descriptor, &chunk, chunk.count)
            if count <= 0 { break }
            result.append(chunk, count: count)
        }
        return result
    }
}
