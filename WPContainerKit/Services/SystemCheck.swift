import Foundation

/// Snapshot of the host's `container` tooling readiness.
public struct SystemCheckResult: Sendable, Equatable {
    public var binaryInstalled: Bool
    public var binaryPath: String?
    public var systemRunning: Bool
    public var rawStatus: String

    public var isReady: Bool { binaryInstalled && systemRunning }

    public init(binaryInstalled: Bool, binaryPath: String?, systemRunning: Bool, rawStatus: String) {
        self.binaryInstalled = binaryInstalled
        self.binaryPath = binaryPath
        self.systemRunning = systemRunning
        self.rawStatus = rawStatus
    }
}

/// Checks whether the `container` binary is present and its system service is
/// running, and can start the service.
public struct SystemCheck: Sendable {
    private let cli: ContainerCLI
    private let preferredBinaryPath: String

    public init(cli: ContainerCLI, binaryPath: String = ContainerCLI.defaultBinaryPath) {
        self.cli = cli
        self.preferredBinaryPath = binaryPath
    }

    public func check() async -> SystemCheckResult {
        let (installed, path) = Self.locateBinary(preferred: preferredBinaryPath)
        guard installed else {
            return SystemCheckResult(binaryInstalled: false, binaryPath: nil,
                                     systemRunning: false, rawStatus: "container binary not found")
        }
        do {
            let out = try await cli.run(["system", "status"])
            let running = out.lowercased().contains("running")
            return SystemCheckResult(binaryInstalled: true, binaryPath: path,
                                     systemRunning: running,
                                     rawStatus: out.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            // A non-zero exit typically means the service is not running.
            let message = (error as? ContainerCLIError)?.description ?? "\(error)"
            return SystemCheckResult(binaryInstalled: true, binaryPath: path,
                                     systemRunning: false, rawStatus: message)
        }
    }

    /// Runs `container system start`.
    public func startSystem() async throws {
        try await cli.run(["system", "start"])
    }

    /// Locate the binary at the preferred path, then PATH, then common locations.
    public static func locateBinary(preferred: String) -> (found: Bool, path: String?) {
        let fm = FileManager.default
        if fm.isExecutableFile(atPath: preferred) { return (true, preferred) }

        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let candidate = "\(dir)/container"
                if fm.isExecutableFile(atPath: candidate) { return (true, candidate) }
            }
        }
        for candidate in ["/usr/local/bin/container", "/opt/homebrew/bin/container"] {
            if fm.isExecutableFile(atPath: candidate) { return (true, candidate) }
        }
        return (false, nil)
    }
}
