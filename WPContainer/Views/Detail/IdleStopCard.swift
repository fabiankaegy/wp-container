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
            return proxyRunning ? nil
                : "The reverse proxy isn’t running, so nothing is enforcing this yet."
        }
        switch ProxyControl.envPortOwnership(envPort) {
        case .noProxy:
            return "The reverse proxy isn’t running, so nothing is enforcing this yet."
        case .conflicted:
            return "The proxy doesn’t own port \(envPort), so it can’t see this environment’s "
                + "traffic and won’t stop it. Stop and start the environment once."
        case .owned, .unknown:
            return nil
        }
    }

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
                        // `selectableMinutes` leads with the recommended value.
                        ForEach(IdlePolicy.selectableMinutes, id: \.self) { minutes in
                            Text(minutes == IdlePolicy.recommendedMinutes
                                 ? "\(IdlePolicy.formatMinutes(minutes)) (recommended)"
                                 : IdlePolicy.formatMinutes(minutes))
                                .tag(Int?.some(minutes))
                        }
                    }
                    .labelsHidden().fixedSize()
                }

                if effective > 0 {
                    Text(IdlePolicy.activityNote(isEnv: isEnv))
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if effective > 0, let notEnforced = enforcementProblem {
                    Text(notEnforced)
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var defaultLabel: String {
        let fallback = IdlePolicy.effectiveMinutes(configured: nil, isEnv: isEnv)
        return fallback == 0 ? "Default (never)" : "Default (\(IdlePolicy.formatMinutes(fallback)))"
    }

    private var detailText: String {
        if isEnv {
            return "On by default (\(IdlePolicy.formatMinutes(IdlePolicy.defaultEnvMinutes))). While on that default, a freshly created environment is never stopped for its first \(IdlePolicy.formatMinutes(IdlePolicy.envCreationGraceMinutes)) regardless of use — pick an explicit value below to opt out of that grace period too. After it applies, one nobody is using gives its ~500 MB back, and the next request to its URL starts it again in about a second behind a page that refreshes into the site."
        }
        return "Off by default — you’re usually working in a site. When on, it is never stopped while any of its environments are running, and opening its proxied URL starts it again."
    }
}
