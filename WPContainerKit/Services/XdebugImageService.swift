import Foundation

/// Builds (once per base tag) the Xdebug-enabled derived WordPress image used by
/// sites with Xdebug turned on (PLAN.md §2c).
///
/// The recipe is the empirically-validated one from `scripts/validate-addons.sh`:
/// `FROM wordpress:<tag>` → `pecl install xdebug && docker-php-ext-enable xdebug`
/// → a `conf.d/zzz-xdebug-settings.ini` that reads `client_host` from the
/// `${XDEBUG_CLIENT_HOST}` env at PHP parse time (so one image works on every
/// network — the gateway IP is supplied per-container at run time). We do NOT
/// emit a `zend_extension` line ourselves; `docker-php-ext-enable` already did.
public actor XdebugImageService {
    public enum BuildError: Error, Sendable, CustomStringConvertible {
        case builderUnavailable(String)
        case buildFailed(String)

        public var description: String {
            switch self {
            case .builderUnavailable(let s): return "container builder unavailable: \(s)"
            case .buildFailed(let s):        return "Xdebug image build failed: \(s)"
            }
        }
    }

    private let cli: ContainerCLI

    public init(cli: ContainerCLI = ContainerCLI()) {
        self.cli = cli
    }

    /// Bump whenever `dockerfile(baseTag:)` changes: the version is part of the
    /// derived tag, so cached images built from the old recipe stop matching
    /// and `ensureImage` rebuilds instead of reusing a stale layer set.
    static let recipeVersion = 2

    /// The derived image tag for a given base WordPress image tag, e.g.
    /// `wordpress:6.8-php8.2-apache` → `wpc-wordpress-xdebug:v2-6.8-php8.2-apache`.
    public static func derivedTag(forBase baseTag: String) -> String {
        let ref = baseTag.hasPrefix("wordpress:")
            ? String(baseTag.dropFirst("wordpress:".count))
            : baseTag.replacingOccurrences(of: ":", with: "-")
        let safe = ref.isEmpty ? "latest" : ref
        return "wpc-wordpress-xdebug:v\(recipeVersion)-\(safe)"
    }

    /// Ensure the derived image for `baseTag` exists, building it if missing.
    /// Returns the derived image tag. `progress` receives coarse phase messages
    /// for a UI to display (the fresh build takes ~18s; cached ~instant).
    @discardableResult
    public func ensureImage(forBaseTag baseTag: String,
                            progress: (@Sendable (String) -> Void)? = nil) async throws -> String {
        let derived = Self.derivedTag(forBase: baseTag)
        if await cli.localImageExists(derived) {
            progress?("Xdebug image ready.")
            return derived
        }
        // Make sure the base image is present before building FROM it.
        progress?("Pulling base image \(baseTag)…")
        _ = try? await cli.run(["image", "pull", baseTag])

        try await ensureBuilderRunning(progress: progress)

        progress?("Building Xdebug image (first time, ~20s)…")
        let buildDir = try writeBuildContext(baseTag: baseTag)
        defer { try? FileManager.default.removeItem(at: buildDir) }

        // `container build` is finicky about absolute -f/context combos, so we
        // run it with cwd INSIDE the build dir and relative paths (validated).
        let result = try await ProcessRunner.run(
            executable: cli.binaryPath,
            args: ["build", "-t", derived, "-f", "Dockerfile", "."],
            cwd: buildDir
        )
        guard result.succeeded else {
            throw BuildError.buildFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        progress?("Xdebug image ready.")
        return derived
    }

    // MARK: - Internals

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

    /// Write the Dockerfile into a scratch build directory and return its URL.
    private func writeBuildContext(baseTag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wpc-xdebug-build-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Self.dockerfile(baseTag: baseTag).write(
            to: dir.appendingPathComponent("Dockerfile"), atomically: true, encoding: .utf8)
        return dir
    }

    /// The exact validated Dockerfile (see `scripts/validate-addons.sh`).
    ///
    /// `mode=debug` + `start_with_request=trigger` (recipe v2): the old
    /// `debug,develop` + `start_with_request=yes` combo taxed EVERY request —
    /// develop-mode instrumentation plus a connect attempt to the (usually
    /// absent) IDE on each page load. Trigger mode is free until a debug
    /// session is requested via the standard `XDEBUG_SESSION`/`XDEBUG_TRIGGER`
    /// cookie, query arg, or env var (browser "Xdebug helper" extensions set it).
    static func dockerfile(baseTag: String) -> String {
        """
        FROM \(baseTag)

        RUN pecl install xdebug \\
            && docker-php-ext-enable xdebug

        RUN { \\
            echo 'xdebug.mode=debug'; \\
            echo 'xdebug.start_with_request=trigger'; \\
            echo 'xdebug.client_port=9003'; \\
            echo 'xdebug.client_host=${XDEBUG_CLIENT_HOST}'; \\
            echo 'xdebug.log_level=0'; \\
            } > /usr/local/etc/php/conf.d/zzz-xdebug-settings.ini
        """
    }
}
