import XCTest
@testable import WPContainerKit

/// Decoding `container stats` output and turning cumulative counters into rates.
final class InstanceMetricsTests: XCTestCase {

    private let json = """
    [{"blockReadBytes":1,"blockWriteBytes":2,"cpuUsageUsec":40000000,"id":"wpc-demo-wp","memoryLimitBytes":1073741824,
      "memoryUsageBytes":300000000,"networkRxBytes":5000,"networkTxBytes":9000,"numProcesses":8},
     {"cpuUsageUsec":2000000,"id":"wpc-demo-db","memoryLimitBytes":1073741824,"memoryUsageBytes":200000000,
      "networkRxBytes":100,"networkTxBytes":200},
     {"id":"broken-row"}]
    """

    func testDecodeSkipsIncompleteRows() {
        let map = ContainerStat.decodeMap(from: Data(json.utf8))
        XCTAssertEqual(Set(map.keys), ["wpc-demo-wp", "wpc-demo-db"])
        XCTAssertEqual(map["wpc-demo-wp"]?.memoryUsageBytes, 300_000_000)
    }

    func testDecodeGarbageIsEmpty() {
        XCTAssertTrue(ContainerStat.decodeMap(from: Data("not json".utf8)).isEmpty)
    }

    func testRatesAreSummedAcrossContainers() throws {
        let before = ["wpc-demo-wp": stat("wpc-demo-wp", cpu: 1_000_000, mem: 100, rx: 1_000, tx: 0),
                      "wpc-demo-db": stat("wpc-demo-db", cpu: 0, mem: 50, rx: 0, tx: 0)]
        let after = ["wpc-demo-wp": stat("wpc-demo-wp", cpu: 2_000_000, mem: 120, rx: 3_000, tx: 400),
                     "wpc-demo-db": stat("wpc-demo-db", cpu: 1_000_000, mem: 60, rx: 0, tx: 600)]
        let s = try XCTUnwrap(InstanceMetricsSampler.sample(containers: ["wpc-demo-wp", "wpc-demo-db", "wpc-demo-mail"],
                                                             previous: before, current: after, interval: 2, at: Date()))
        // 2 s of wall time, 2 s of CPU across two containers = one core = 100%.
        XCTAssertEqual(s.cpuPercent, 100, accuracy: 0.001)
        XCTAssertEqual(s.memoryBytes, 180)
        XCTAssertEqual(s.rxBytesPerSecond, 1_000, accuracy: 0.001)
        XCTAssertEqual(s.txBytesPerSecond, 500, accuracy: 0.001)
    }

    func testRestartedContainerContributesMemoryButNoRate() throws {
        let before = ["wpc-demo-wp": stat("wpc-demo-wp", cpu: 9_000_000, mem: 100, rx: 9_000, tx: 9_000)]
        let after = ["wpc-demo-wp": stat("wpc-demo-wp", cpu: 10, mem: 80, rx: 10, tx: 10)]
        let s = try XCTUnwrap(InstanceMetricsSampler.sample(containers: ["wpc-demo-wp"], previous: before,
                                                             current: after, interval: 2, at: Date()))
        XCTAssertEqual(s.cpuPercent, 0)
        XCTAssertEqual(s.rxBytesPerSecond, 0)
        XCTAssertEqual(s.memoryBytes, 80)
    }

    func testStoppedInstanceHasNoSample() {
        XCTAssertNil(InstanceMetricsSampler.sample(containers: ["wpc-demo-wp"], previous: [:], current: [:], interval: 2, at: Date()))
    }

    private func stat(_ id: String, cpu: UInt64, mem: UInt64, rx: UInt64, tx: UInt64) -> ContainerStat {
        ContainerStat(id: id, cpuUsageUsec: cpu, memoryUsageBytes: mem, memoryLimitBytes: 1 << 30, networkRxBytes: rx, networkTxBytes: tx)
    }
}
