import Foundation

/// Builds a local image from in-memory build-context files with
/// `container build`. Shared by the Xdebug and nginx derived images.
struct DerivedImageBuilder {
    enum BuildError: Error, Sendable, CustomStringConvertible {
        case builderUnavailable(String)
        case buildFailed(image: String, detail: String)

        var description: String {
            switch self {
            case .builderUnavailable(let s):           return "container builder unavailable: \(s)"
            case .buildFailed(let image, let detail):  return "\(image) image build failed: \(detail)"
            }
        }
    }

    let cli: ContainerCLI

    /// Build `files` (build-context path → contents, including `Dockerfile`)
    /// into `tag`. `displayName` names the image in errors ("Xdebug", "nginx").
    func build(tag: String, files: [String: String], displayName: String,
               progress: (@Sendable (String) -> Void)?) async throws {
        try await ensureBuilderRunning(progress: progress)
        let buildDir = try writeBuildContext(files)
        defer { try? FileManager.default.removeItem(at: buildDir) }

        // `container build` is finicky about absolute -f/context combos, so we
        // run it with cwd INSIDE the build dir and relative paths (validated).
        let result = try await ProcessRunner.run(
            executable: cli.binaryPath,
            args: ["build", "-t", tag, "-f", "Dockerfile", "."],
            cwd: buildDir
        )
        guard result.succeeded else {
            throw BuildError.buildFailed(image: displayName,
                                         detail: result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }

    /// The container builder must be running once before any `container build`.
    private func ensureBuilderRunning(progress: (@Sendable (String) -> Void)?) async throws {
        let status = try? await cli.runCapturing(["builder", "status"])
        if let status, status.succeeded,
           (status.stdout + status.stderr).lowercased().contains("running") {
            return
        }
        progress?("Starting the container builder…")
        let start = try await cli.runCapturing(["builder", "start"])
        // `builder start` may report "already running" on a race — tolerate it.
        if !start.succeeded, !(start.stdout + start.stderr).lowercased().contains("running") {
            throw BuildError.builderUnavailable(start.stderr.isEmpty ? start.stdout : start.stderr)
        }
    }

    /// Write the build context into a scratch directory and return its URL.
    private func writeBuildContext(_ files: [String: String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wpc-image-build-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (path, contents) in files {
            try contents.write(to: dir.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        return dir
    }
}
