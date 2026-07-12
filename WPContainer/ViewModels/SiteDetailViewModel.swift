import Foundation
import Observation
import WPContainerKit

/// Per-detail-pane view model. Owns the live log stream for the selected
/// site/env: which container to tail (wp/db), follow toggle, a capped line
/// buffer, and the stream task lifecycle (started on appear, cancelled on
/// disappear or when inputs change). All log-streaming logic lives here so the
/// `LogsView` stays thin.
@MainActor
@Observable
public final class SiteDetailViewModel {
    public enum LogSource: String, CaseIterable, Identifiable {
        case wp = "WordPress"
        case db = "Database"
        public var id: String { rawValue }
        var symbol: String { self == .wp ? "globe" : "cylinder.split.1x2" }
    }

    public struct LogLine: Identifiable {
        public let id = UUID()
        public let text: String
    }

    private let cli: ContainerCLI
    private static let maxLines = 2000

    public var source: LogSource = .wp { didSet { if oldValue != source { restart() } } }
    public var follow: Bool = true { didSet { if oldValue != follow { restart() } } }
    public private(set) var lines: [LogLine] = []
    public private(set) var isStreaming = false

    @ObservationIgnored private var wpName: String = ""
    @ObservationIgnored private var dbName: String = ""
    @ObservationIgnored private var logTask: Task<Void, Never>?
    @ObservationIgnored private var active = false

    public init(cli: ContainerCLI) {
        self.cli = cli
    }

    /// Point the tailer at a given instance's containers. Called from the view's
    /// `.task` / `.onChange` so switching sites re-targets the stream.
    public func configure(wpContainer: String, dbContainer: String) {
        let changed = wpContainer != wpName
        wpName = wpContainer
        dbName = dbContainer
        if changed {
            lines = []
            if active { restart() }
        }
    }

    public func start() {
        active = true
        restart()
    }

    public func stop() {
        active = false
        logTask?.cancel()
        logTask = nil
        isStreaming = false
    }

    public func clear() { lines = [] }

    private func restart() {
        guard active else { return }
        logTask?.cancel()
        lines = []
        let name = source == .wp ? wpName : dbName
        let follow = self.follow
        guard !name.isEmpty else { isStreaming = false; return }
        isStreaming = true
        let stream = cli.logs(name: name, follow: follow)
        logTask = Task { [weak self] in
            do {
                for try await line in stream {
                    if Task.isCancelled { break }
                    self?.append(line)
                }
            } catch {
                self?.append("— log stream ended: \(error.localizedDescription)")
            }
            self?.isStreaming = false
        }
    }

    private func append(_ text: String) {
        lines.append(LogLine(text: text))
        if lines.count > Self.maxLines {
            lines.removeFirst(lines.count - Self.maxLines)
        }
    }
}
