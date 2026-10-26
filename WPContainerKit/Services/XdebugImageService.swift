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
        // Make sure the base image is present before building FROM it. A
        // locally built base (the nginx image) is never pulled.
        if !(await cli.localImageExists(baseTag)) {
            progress?("Pulling base image \(baseTag)…")
            _ = try? await cli.run(["image", "pull", baseTag])
        }

        progress?("Building Xdebug image (first time, ~20s)…")
        try await DerivedImageBuilder(cli: cli).build(
            tag: derived, files: ["Dockerfile": Self.dockerfile(baseTag: baseTag)],
            displayName: "Xdebug", progress: progress)
        progress?("Xdebug image ready.")
        return derived
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
