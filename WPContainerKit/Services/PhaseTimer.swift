import Foundation

/// Lightweight, opt-in phase timing for lifecycle diagnostics.
///
/// Zero-cost when the `WPC_TIMING` environment variable is unset (the common
/// case): `mark` short-circuits before touching the clock. When set, each
/// `mark` writes `[timing] <label> <phase> +<ms>ms` to stderr, with every
/// timestamp relative to the timer's creation. Because starts are now
/// parallelized, only absolute offsets from t0 are reported (per-mark deltas
/// would be meaningless when phases overlap), which also keeps the type
/// immutable and `Sendable` — safe to share across the concurrent branches of
/// a single start.
struct PhaseTimer: Sendable {
    let label: String
    private let start: ContinuousClock.Instant
    private static let enabled = ProcessInfo.processInfo.environment["WPC_TIMING"] != nil

    init(_ label: String) {
        self.label = label
        self.start = .now
    }

    func mark(_ phase: String) {
        guard Self.enabled else { return }
        let elapsed = ContinuousClock.now - start
        let ms = Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
        FileHandle.standardError.write(Data("[timing] \(label) \(phase) +\(Int(ms))ms\n".utf8))
    }
}
