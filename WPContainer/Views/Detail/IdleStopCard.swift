import SwiftUI
import WPContainerKit

/// "Idle stop" card (issue #16): how long this site / environment may sit unused
/// before the proxy stops it to give its VM's memory back to macOS. The next
/// request wakes it again (~1s of VM boot) behind a self-refreshing page, so the
/// trade is memory for a moment of latency.
///
/// Follows `ResourcesCard`'s Default/override shape — the picker's "Default"
/// state persists `nil`, which resolves to 15 minutes for an environment and OFF
/// for a parent site (auto-stopping the thing you are working on is opt-in).
struct IdleStopCard: View {
    @Environment(AppViewModel.self) private var vm

    /// nil ⇒ follow the default; 0 ⇒ never; > 0 ⇒ minutes.
    let configured: Int?
    /// Envs and sites have different defaults and different copy.
    let isEnv: Bool
    let onChange: (Int?) -> Void

    private var selection: Binding<Int?> {
        Binding(get: { configured }, set: { onChange($0) })
    }

    private var effective: Int {
        IdlePolicy.effectiveMinutes(configured: configured, isEnv: isEnv)
    }

    /// Enforced by whichever process hosts the proxy — with no proxy listening
    /// nothing stops anything, so say so rather than lying with a picker.
    private var proxyRunning: Bool { vm.proxyPort != nil }

    var body: some View {
        SectionCard(title: "Idle stop", systemImage: "moon.zzz") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Stop when unused").font(.callout.weight(.medium))
                        Text(detailText)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Picker("", selection: selection) {
                        Text(defaultLabel).tag(Int?.none)
                        Text("Never").tag(Int?.some(0))
                        ForEach(IdlePolicy.selectableMinutes, id: \.self) { minutes in
                            Text("\(minutes) min").tag(Int?.some(minutes))
                        }
                    }
                    .labelsHidden().fixedSize()
                }

                if effective > 0 && !proxyRunning {
                    Text("The reverse proxy isn’t running, so nothing is enforcing this yet.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var defaultLabel: String {
        let fallback = IdlePolicy.effectiveMinutes(configured: nil, isEnv: isEnv)
        return fallback == 0 ? "Default (never)" : "Default (\(fallback) min)"
    }

    private var detailText: String {
        if isEnv {
            return "Frees this environment’s memory when nobody is using it. Opening its URL starts it again in about a second."
        }
        return "Off by default for sites — you’re usually working in them. When on, the site is never stopped while any of its environments are running, and opening its URL starts it again."
    }
}
