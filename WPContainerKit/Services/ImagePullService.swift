import Foundation

/// Governs how `ImagePullService.ensure` treats a possibly-missing image tag
/// (issue #18). `.ifMissing` is the default everywhere: a locally-present tag
/// never touches the network.
public enum PullPolicy: Sendable, Equatable {
    /// Pull only when the tag isn't already present in the local image store.
    case ifMissing
    /// Always attempt a pull (registry revalidation), even if present locally.
    case refresh
    /// Never touch the network; the local image must already exist.
    case never
}

/// Thrown by `ImagePullService.ensure` when `.never` is requested and the
/// image isn't locally present — there is genuinely nothing usable and no
/// network is allowed to fix that.
public struct ImageUnavailableError: Error, Sendable, CustomStringConvertible {
    public let tag: String
    public var description: String {
        "Image \"\(tag)\" is not present locally, and --no-pull forbids contacting the registry. " +
        "Start once without --no-pull, or run `container image pull \(tag)` manually."
    }
}

/// Dedupes and gates every `container image pull` invocation across the whole
/// process (issue #18).
///
/// Before this existed, `wp-container start <site>` fanned out to every
/// worktree env CONCURRENTLY, and each env independently pulled the same
/// handful of base image tags — an 11-env site burst ~24 registry requests in
/// one shot, enough to trip Docker Hub's anonymous rate limit (100/hr) and
/// fail both the envs and the parent site's start.
///
/// `SiteLifecycle` owns ONE shared instance of this actor, so every caller —
/// the parent site, every env, `WorktreeEnvService.create` — converges on the
/// same in-flight resolution per distinct tag, and a tag known locally
/// present is never re-pulled under `.ifMissing` (starting an already-cached
/// site needs no network at all).
public actor ImagePullService {
    private let cli: ContainerCLI

    /// One shared task per in-flight tag. Cleared on completion (success OR
    /// failure) so a later call — e.g. a `.refresh` after an `.ifMissing` hit
    /// — always starts a fresh resolution instead of replaying a stale result.
    private var inFlight: [String: Task<String?, Error>] = [:]

    public init(cli: ContainerCLI) {
        self.cli = cli
    }

    /// Ensure `image` is available per `policy`.
    ///
    /// Concurrent callers for the SAME tag share exactly one underlying task —
    /// the second and later callers just await its result instead of pulling
    /// again. Returns a non-nil warning string when a pull failed but a local
    /// image was used as a graceful fallback (429s, transient registry
    /// errors, offline dev) — that path is intentionally non-throwing; it
    /// throws only when there is truly no usable image (see `.never` and the
    /// hard-failure branch of `.ifMissing`/`.refresh`).
    @discardableResult
    public func ensure(_ image: String, policy: PullPolicy) async throws -> String? {
        if let existing = inFlight[image] {
            return try await existing.value
        }
        let cli = self.cli
        let task = Task<String?, Error> {
            try await Self.resolve(image, policy: policy, cli: cli)
        }
        inFlight[image] = task
        defer { inFlight[image] = nil }
        return try await task.value
    }

    // MARK: - Pure policy decision (trivially unit-testable)

    enum PullAction: Equatable {
        /// The tag is already usable; do nothing.
        case skip
        /// Attempt a pull.
        case pull
        /// No pull allowed and nothing local to fall back to — hard failure.
        case failWithoutNetwork
    }

    /// Pure function: given the policy and whether the tag is already present
    /// locally, decide what to do. No I/O — easy to unit test later.
    static func decide(policy: PullPolicy, locallyPresent: Bool) -> PullAction {
        switch policy {
        case .never:     return locallyPresent ? .skip : .failWithoutNetwork
        case .ifMissing:  return locallyPresent ? .skip : .pull
        case .refresh:    return .pull
        }
    }

    // MARK: - I/O

    private static func resolve(_ image: String, policy: PullPolicy, cli: ContainerCLI) async throws -> String? {
        let locallyPresent = await cli.localImageExists(image)
        switch decide(policy: policy, locallyPresent: locallyPresent) {
        case .skip:
            return nil
        case .failWithoutNetwork:
            throw ImageUnavailableError(tag: image)
        case .pull:
            do {
                try await cli.run(SiteRecipe.pullImageArgs(image))
                return nil
            } catch {
                // Graceful degradation (issue #18): a failed pull is a
                // WARNING, not a hard failure, whenever a usable local image
                // exists — covers both a failed `.ifMissing` cold pull that
                // somehow raced a concurrent pull to success, and (more
                // commonly) a `.refresh` revalidation failing against an
                // already-cached tag.
                if await cli.localImageExists(image) {
                    return "could not pull \"\(image)\" (\(shortDescription(error))); using the local copy"
                }
                throw error
            }
        }
    }

    private static func shortDescription(_ error: Error) -> String {
        if let e = error as? ContainerCLIError { return e.description }
        return "\(error)"
    }
}
