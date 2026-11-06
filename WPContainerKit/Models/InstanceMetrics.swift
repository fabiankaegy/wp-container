import Foundation

/// One container's cumulative counters from `container stats --no-stream --format json`.
public struct ContainerStat: Decodable, Sendable, Equatable {
    public let id: String
    /// Total CPU time the container has used, in microseconds (cumulative).
    public let cpuUsageUsec: UInt64
    public let memoryUsageBytes: UInt64
    public let memoryLimitBytes: UInt64
    /// Bytes received / sent since the container started (cumulative).
    public let networkRxBytes: UInt64
    public let networkTxBytes: UInt64

    public init(id: String, cpuUsageUsec: UInt64, memoryUsageBytes: UInt64, memoryLimitBytes: UInt64,
                networkRxBytes: UInt64, networkTxBytes: UInt64) {
        self.id = id
        self.cpuUsageUsec = cpuUsageUsec
        self.memoryUsageBytes = memoryUsageBytes
        self.memoryLimitBytes = memoryLimitBytes
        self.networkRxBytes = networkRxBytes
        self.networkTxBytes = networkTxBytes
    }

    /// Decodes the JSON array `container stats` prints, keyed by container name.
    /// Entries missing a counter are skipped rather than failing the whole poll.
    public static func decodeMap(from data: Data) -> [String: ContainerStat] {
        struct Lossy: Decodable {
            let value: ContainerStat?
            init(from decoder: Decoder) throws { value = try? ContainerStat(from: decoder) }
        }
        let rows = (try? JSONDecoder().decode([Lossy].self, from: data)) ?? []
        return Dictionary(rows.compactMap { $0.value }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }
}

/// A point-in-time reading for one site or worktree env, summed over its containers.
public struct InstanceMetricsSample: Sendable, Equatable {
    public let date: Date
    /// CPU use as a percentage of ONE core (so 4 busy cores read 400%), like Activity Monitor.
    public let cpuPercent: Double
    public let memoryBytes: UInt64
    /// Network throughput in bytes per second over the last interval.
    public let rxBytesPerSecond: Double
    public let txBytesPerSecond: Double

    public init(date: Date, cpuPercent: Double, memoryBytes: UInt64, rxBytesPerSecond: Double, txBytesPerSecond: Double) {
        self.date = date
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.rxBytesPerSecond = rxBytesPerSecond
        self.txBytesPerSecond = txBytesPerSecond
    }
}

/// Turns two consecutive `container stats` polls into per-instance samples.
///
/// The CLI reports cumulative counters, so CPU and network become rates by
/// differencing against the previous poll. A container that appeared (or
/// restarted, resetting its counters) between polls contributes its memory but
/// no rate for that interval, instead of a huge or negative spike.
public enum InstanceMetricsSampler {
    public static func sample(containers: [String],
                              previous: [String: ContainerStat],
                              current: [String: ContainerStat],
                              interval: TimeInterval,
                              at date: Date) -> InstanceMetricsSample? {
        let live = containers.compactMap { current[$0] }
        guard !live.isEmpty else { return nil }
        var cpuUsec: UInt64 = 0, rx: UInt64 = 0, tx: UInt64 = 0, memory: UInt64 = 0
        for stat in live {
            memory += stat.memoryUsageBytes
            guard let before = previous[stat.id],
                  stat.cpuUsageUsec >= before.cpuUsageUsec,
                  stat.networkRxBytes >= before.networkRxBytes,
                  stat.networkTxBytes >= before.networkTxBytes else { continue }
            cpuUsec += stat.cpuUsageUsec - before.cpuUsageUsec
            rx += stat.networkRxBytes - before.networkRxBytes
            tx += stat.networkTxBytes - before.networkTxBytes
        }
        let seconds = max(interval, 0.001)
        return InstanceMetricsSample(date: date,
                                     cpuPercent: Double(cpuUsec) / (seconds * 1_000_000) * 100,
                                     memoryBytes: memory,
                                     rxBytesPerSecond: Double(rx) / seconds,
                                     txBytesPerSecond: Double(tx) / seconds)
    }
}

public extension ContainerCLI {
    /// One `container stats` reading for every running container, keyed by name.
    func stats() async throws -> [String: ContainerStat] {
        let out = try await run(["stats", "--no-stream", "--format", "json"])
        return ContainerStat.decodeMap(from: Data(out.utf8))
    }
}

public extension RunnableInstance {
    /// Every container this instance may run: WordPress, its own database (a
    /// shared-database env has none), and each sidecar add-on.
    var metricsContainerNames: [String] {
        [wpContainerName] + (ownsDatabaseContainer ? [dbContainerName] : [])
            + SidecarAddons.all.map { $0.containerName(for: self) }
    }
}
