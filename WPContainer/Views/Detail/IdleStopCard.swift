import SwiftUI
import WPContainerKit

/// "Idle stop" card (issue #16): how long this site / environment may sit unused
/// before the proxy stops it to give its VM's memory back to macOS. The next
/// request wakes it again (~1s of VM boot) behind a self-refreshing page, so the
/// trade is memory for a moment of latency.
///
/// Follows `ResourcesCard`'s Default/override shape — the picker's "Default"
/// state persists `nil`, which resolves to 3 hours for an environment (whose
/// every request the proxy sees) and to OFF for a site. The card states plainly
/// what the idle clock can and cannot see, because a site you only ever reach at
/// `127.0.0.1:<port>` would look like a bug rather than a limitation (see
/// `IdlePolicy`).
struct IdleStopCard: View {
    @Environment(AppViewModel.self) private var vm

    /// nil ⇒ follow the default; 0 ⇒ never; > 0 ⇒ minutes.
    let configured: Int?
    /// Envs and sites have different defaults and different copy.
    let isEnv: Bool
    /// For an ENV: the port whose ownership decides whether this policy is being
    /// enforced at all (issue #16 follow-through). nil for sites, whose enforcement
    /// only needs a proxy to exist.
    var envPort: Int? = nil
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

    /// Why this setting is NOT currently in force, or nil when it is.
    ///
    /// For an env there are two distinct answers, and the second one is the whole
    /// reason the proxy publishes its port report: a running proxy that does not
    /// own the env's socket cannot see its traffic, and so deliberately refuses to
    /// judge it idle (see `HTTPSProxy.sweepIdleInstances`).
    private var enforcementProblem: String? {
        guard let envPort else {
            return proxyRunning ? nil : Self.noProxy
        }
        switch ProxyControl.envPortOwnership(envPort) {
        case .noProxy:
            return Self.noProxy
        case .conflicted:
            return "Not active: the proxy doesn’t hold port \(envPort). Stop and start this environment."
        case .owned, .unknown:
            return nil
        }
    }

    private static let noProxy = "Not active: the proxy isn’t running."

    var body: some View {
        SectionCard(title: "Idle stop", systemImage: "moon.zzz") {
            SettingRow(title: "Stop after", detail: Text(detailText)) {
                Picker("", selection: selection) {
                    Text(defaultLabel).tag(Int?.none)
                    Text("Never").tag(Int?.some(0))
                    // `selectableMinutes` leads with the recommended value.
                    ForEach(IdlePolicy.selectableMinutes, id: \.self) { minutes in
                        Text(minutes == IdlePolicy.recommendedMinutes
                             ? "\(IdlePolicy.formatMinutes(minutes)) (recommended)"
                             : IdlePolicy.formatMinutes(minutes))
                            .tag(Int?.some(minutes))
                    }
                }
                .labelsHidden().fixedSize()
            } footer: {
                if effective > 0, let notEnforced = enforcementProblem {
                    Text(notEnforced)
                        .font(.caption2).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 3)
                }
            }
            .help(helpText)
        }
    }

    private var defaultLabel: String {
        let fallback = IdlePolicy.effectiveMinutes(configured: nil, isEnv: isEnv)
        return fallback == 0 ? "Default (never)" : "Default (\(IdlePolicy.formatMinutes(fallback)))"
    }

    /// One line on what the current choice does. Sites add the one thing that
    /// would otherwise look like a bug: visits to `127.0.0.1:<port>` bypass the
    /// proxy, so they don't count as use (see `IdlePolicy.activityNote`).
    private var detailText: String {
        guard effective > 0 else {
            return "Runs until you stop it."
        }
        let after = IdlePolicy.formatMinutes(effective)
        if isEnv {
            return "Stops after \(after) without visits, freeing about 500 MB. The next visit starts it again."
        }
        return "Stops after \(after) without visits to its .localhost or custom domain. The next visit starts it again."
    }

    /// The nuance that doesn't need to be on screen: what counts as a visit, and
    /// the grace period new environments get while on the default.
    private var helpText: String {
        if isEnv {
            let grace = configured == nil
                ? " While on the default, a new environment isn’t stopped during its first "
                    + "\(IdlePolicy.formatMinutes(IdlePolicy.envCreationGraceMinutes)); pick a time to skip that."
                : ""
            return "Browser requests, wp-cli, MCP and magic-login all count as visits." + grace
        }
        return "Requests to http://127.0.0.1:<port> don’t count, and a site is never stopped while one of its branch environments runs."
    }
}
