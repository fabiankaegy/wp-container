import Foundation
import Observation
import WPContainerKit

/// Rolling CPU / memory / network history for every running site and env,
/// read from `container stats` while the main window is open (the window's
/// `.task` owns the polling loop, so it stops with it). `container stats`
/// itself samples for ~2.4 s, so a reading lands roughly every 3.5 s; nothing
/// is spawned while no site or env is running.
@MainActor
@Observable
final class LiveMetrics {
    /// Newest sample last; at most `capacity` per instance (about 3.5 minutes).
    private(set) var history: [UUID: [InstanceMetricsSample]] = [:]
    /// The latest reading summed over every running instance.
    private(set) var total: InstanceMetricsSample?

    static let capacity = 60
    /// Pause between `container stats` calls.
    static let interval: Duration = .seconds(1)

    @ObservationIgnored private var previous: [String: ContainerStat] = [:]
    @ObservationIgnored private var previousDate: Date?

    func latest(_ id: UUID) -> InstanceMetricsSample? { history[id]?.last }

    /// Polls until the calling task is cancelled. `instances` returns each
    /// running site/env's id and container names, read fresh every tick.
    func run(cli: ContainerCLI, instances: @escaping @MainActor () -> [(id: UUID, containers: [String])]) async {
        while !Task.isCancelled {
            await poll(cli: cli, instances: instances())
            try? await Task.sleep(for: Self.interval)
        }
    }

    private func poll(cli: ContainerCLI, instances: [(id: UUID, containers: [String])]) async {
        guard !instances.isEmpty else {
            history = [:]; total = nil; previous = [:]; previousDate = nil
            return
        }
        guard let current = try? await cli.stats() else { return }
        let now = Date()
        let elapsed = previousDate.map { now.timeIntervalSince($0) } ?? 0
        var next: [UUID: [InstanceMetricsSample]] = [:]
        var cpu = 0.0, memory: UInt64 = 0, rx = 0.0, tx = 0.0
        for instance in instances {
            guard let sample = InstanceMetricsSampler.sample(containers: instance.containers, previous: previous,
                                                             current: current, interval: elapsed, at: now) else { continue }
            next[instance.id] = Array(((history[instance.id] ?? []) + [sample]).suffix(Self.capacity))
            cpu += sample.cpuPercent; memory += sample.memoryBytes
            rx += sample.rxBytesPerSecond; tx += sample.txBytesPerSecond
        }
        history = next
        total = InstanceMetricsSample(date: now, cpuPercent: cpu, memoryBytes: memory, rxBytesPerSecond: rx, txBytesPerSecond: tx)
        previous = current
        previousDate = now
    }
}

extension AppViewModel {
    /// Polls `container stats` for the main window's lifetime.
    func runLiveMetrics() async {
        await metrics.run(cli: cli) { [weak self] in
            guard let self else { return [] }
            let sites = self.sites.filter { $0.status.isRunning }.map { (id: $0.id, containers: $0.metricsContainerNames) }
            let envs = self.envs.filter { $0.status.isRunning }.map { (id: $0.id, containers: $0.metricsContainerNames) }
            return sites + envs
        }
    }
}
