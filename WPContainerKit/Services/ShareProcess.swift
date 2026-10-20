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
    /// The OS has reaped the process; its pid must not be signalled any more.
    private var reaped = false
    /// The exit has been fully reported (output flushed, `onExit` called).
    private var exited = false
    private var startContinuation: CheckedContinuation<String, Error>?
    private var exitWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var nextWaiterID = 0
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var stderrTail: [String] = []
    private var sources: [DispatchSourceRead] = []
    private let drained = DispatchGroup()

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

    /// Sends SIGTERM, then SIGKILL once `grace` has passed. Returns after the process has exited
    /// and `onExit` has run.
    public func terminate(grace: Duration = .seconds(5)) async {
        let isStarted = lock.withLock { started }
        guard isStarted else { return }
        signalIfRunning(SIGTERM)
        if await waitForExit(within: grace) { return }
        signalIfRunning(SIGKILL)
        _ = await waitForExit(within: .seconds(5))
    }

    private func launch(_ continuation: CheckedContinuation<String, Error>) {
        lock.withLock { startContinuation = continuation }
        if Task.isCancelled {
            settleStart(throwing: { _ in CancellationError() })
            return
        }

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

        let created = [
            makeSource(for: stdout.fileHandleForReading, isStderr: false),
            makeSource(for: stderr.fileHandleForReading, isStderr: true),
        ]
        lock.withLock { sources = created }
        created.forEach { $0.resume() }

        do {
            try process.run()
        } catch {
            created.forEach { $0.cancel() }
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()
            drained.notify(queue: .global()) { [weak self] in
                self?.lock.withLock { self?.exited = true }
            }
            settleStart(throwing: { _ in error })
            return
        }
        lock.withLock {
            processID = process.processIdentifier
            started = true
        }
    }

    /// Reads one pipe on its own serial queue. The cancel handler runs after any in-flight read,
    /// flushes what is left, and closes the pipe, so the pipe is never read after it is closed.
    private func makeSource(for handle: FileHandle, isStderr: Bool) -> DispatchSourceRead {
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        let queue = DispatchQueue(label: "wpc.share-process.\(isStderr ? "stderr" : "stdout")")
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        drained.enter()
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            if self.readAvailable(descriptor, isStderr: isStderr) { source.cancel() }
        }
        source.setCancelHandler { [weak self] in
            _ = self?.readAvailable(descriptor, isStderr: isStderr)
            try? handle.close()
            self?.drained.leave()
        }
        return source
    }

    /// Reads until the pipe would block. Returns true at end of file.
    private func readAvailable(_ descriptor: Int32, isStderr: Bool) -> Bool {
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(descriptor, &chunk, chunk.count)
            if count == 0 { return true }
            if count < 0 { return false }
            consume(Data(chunk[0..<count]), isStderr: isStderr)
        }
    }

    private func consume(_ data: Data, isStderr: Bool) {
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
        let activeSources: [DispatchSourceRead] = lock.withLock {
            reaped = true
            return sources
        }
        activeSources.forEach { $0.cancel() }
        drained.notify(queue: .global()) { [weak self] in
            self?.finishExit(status: status)
        }
    }

    private func finishExit(status: Int32) {
        let rest: [(String, Bool)] = lock.withLock {
            var result: [(String, Bool)] = []
            if !stdoutBuffer.isEmpty { result.append((String(decoding: stdoutBuffer, as: UTF8.self), false)) }
            if !stderrBuffer.isEmpty { result.append((String(decoding: stderrBuffer, as: UTF8.self), true)) }
            stdoutBuffer = Data()
            stderrBuffer = Data()
            sources = []
            return result
        }
        for (line, isStderr) in rest { handle(line: line, isStderr: isStderr) }

        let (tail, handler, continuation): ([String], (@Sendable (Int32, [String]) -> Void)?, CheckedContinuation<String, Error>?) = lock.withLock {
            let continuation = startContinuation
            startContinuation = nil
            return (stderrTail, exitHandler, continuation)
        }
        continuation?.resume(throwing: ShareError.providerExited(status: status, stderrTail: tail))
        handler?(status, tail)

        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            exited = true
            let all = Array(exitWaiters.values)
            exitWaiters = [:]
            return all
        }
        waiters.forEach { $0.resume() }
    }

    private func settleStart(throwing makeError: ([String]) -> Error) {
        let (continuation, tail): (CheckedContinuation<String, Error>?, [String]) = lock.withLock {
            let continuation = startContinuation
            startContinuation = nil
            return (continuation, stderrTail)
        }
        continuation?.resume(throwing: makeError(tail))
    }

    /// Signals the process unless it has already been reaped, so a recycled pid is never hit.
    private func signalIfRunning(_ signal: Int32) {
        lock.withLock {
            if started && !reaped { kill(processID, signal) }
        }
    }

    /// Waits for the exit to be fully reported, or for `duration`; independent of task cancellation.
    private func waitForExit(within duration: Duration) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let id: Int? = lock.withLock {
                if exited { return nil }
                nextWaiterID += 1
                exitWaiters[nextWaiterID] = continuation
                return nextWaiterID
            }
            guard let id else {
                continuation.resume()
                return
            }
            let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak self] in
                let waiter = self?.lock.withLock { self?.exitWaiters.removeValue(forKey: id) }
                waiter?.resume()
            }
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
}
