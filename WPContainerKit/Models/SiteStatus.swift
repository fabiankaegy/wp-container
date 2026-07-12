import Foundation

/// Runtime status of a runnable instance (a site or a worktree environment).
///
/// This is *derived* from the live container state and is therefore never
/// persisted to `sites.json`.
public enum SiteStatus: Equatable, Hashable, Sendable, Codable {
    case stopped
    case starting
    case running
    case stopping
    case error(String)

    /// True while a lifecycle action is in flight — reconciliation must not
    /// clobber these states with poll results.
    public var isTransitional: Bool {
        self == .starting || self == .stopping
    }

    public var isRunning: Bool { self == .running }

    /// Human-readable label for UI / CLI output.
    public var label: String {
        switch self {
        case .stopped:  return "Stopped"
        case .starting: return "Starting"
        case .running:  return "Running"
        case .stopping: return "Stopping"
        case .error:    return "Error"
        }
    }

    /// Stable machine token used in `--json` CLI output.
    public var token: String {
        switch self {
        case .stopped:  return "stopped"
        case .starting: return "starting"
        case .running:  return "running"
        case .stopping: return "stopping"
        case .error:    return "error"
        }
    }

    public var errorMessage: String? {
        if case .error(let m) = self { return m }
        return nil
    }
}
