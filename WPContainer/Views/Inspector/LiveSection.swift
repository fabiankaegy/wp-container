import Charts
import SwiftUI
import WPContainerKit

/// Live CPU, memory and network for one running site or env, from
/// `container stats` (see `LiveMetrics`): the current value plus a sparkline
/// of the last two minutes.
struct LiveSection: View {
    @Environment(AppViewModel.self) private var vm
    let id: UUID

    var body: some View {
        let samples = vm.metrics.history[id] ?? []
        SectionCard(title: "Live", systemImage: "waveform.path.ecg") {
            if let latest = samples.last {
                VStack(spacing: 10) {
                    MetricRow(label: "CPU", value: Format.percent(latest.cpuPercent), color: .blue,
                              values: samples.map(\.cpuPercent))
                    MetricRow(label: "Memory", value: Format.bytes(latest.memoryBytes), color: .purple,
                              values: samples.map { Double($0.memoryBytes) })
                    MetricRow(label: "Network", value: "↓\(Format.rate(latest.rxBytesPerSecond)) ↑\(Format.rate(latest.txBytesPerSecond))",
                              color: .green, values: samples.map { $0.rxBytesPerSecond + $0.txBytesPerSecond })
                }
            } else {
                Text("Measuring…").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// One live metric: label and current value over a sparkline.
struct MetricRow: View {
    let label: String
    let value: String
    let color: Color
    let values: [Double]

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.callout.weight(.semibold)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.75)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 8)
            Sparkline(values: values, color: color)
                .frame(width: 110, height: 28)
        }
    }
}

/// A minimal area chart with no axes.
struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        Chart(Array(values.enumerated()), id: \.offset) { index, value in
            AreaMark(x: .value("t", index), y: .value("v", value))
                .foregroundStyle(color.opacity(0.18).gradient)
                .interpolationMethod(.monotone)
            LineMark(x: .value("t", index), y: .value("v", value))
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .interpolationMethod(.monotone)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartXScale(domain: 0...max(values.count - 1, 1))
        .chartYScale(domain: 0...max(values.max() ?? 1, 0.0001) * 1.15)
    }
}

/// Number formatting for live metrics.
enum Format {
    static func percent(_ value: Double) -> String { value < 10 ? String(format: "%.1f%%", value) : "\(Int(value.rounded()))%" }
    static func bytes(_ value: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory) }
    static func rate(_ value: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false  // "0 bytes", never "Zero KB"
        return formatter.string(fromByteCount: Int64(value)) + "/s"
    }
}
