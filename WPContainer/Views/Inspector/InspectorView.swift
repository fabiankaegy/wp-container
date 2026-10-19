import SwiftUI
import WPContainerKit

/// The right-hand inspector: every setting for the current selection, so
/// nothing lives behind a tab or a sheet. Shows a site, one branch
/// environment, or several rows of a branch table at once.
struct InspectorView: View {
    @Environment(AppViewModel.self) private var vm

    var body: some View {
        content
            .environment(\.sectionCardStyle, .inspector)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // Giving the inspector toolbar items of its own makes it a separate
            // toolbar section, so the center column's items stay above the
            // center column instead of drifting over the inspector.
            .toolbar {
                ToolbarSpacer(.flexible)
                ToolbarItem { InspectorToggle() }
            }
    }

    @ViewBuilder
    private var content: some View {
        let envs = vm.selectedEnvs
        if envs.count > 1 {
            MultiEnvInspector(envs: envs)
        } else if let env = envs.first {
            EnvInspector(env: env).id(env.id)
        } else if vm.screen == nil && vm.library == .branches {
            placeholder("Select branch environments to see their settings.")
        } else if let env = vm.selectedEnv {
            EnvInspector(env: env).id(env.id)
        } else if let site = vm.selectedSite {
            SiteInspector(site: site).id(site.id)
        } else {
            placeholder("Select a site to see its settings.")
        }
    }

    private func placeholder(_ text: String) -> some View {
        ContentUnavailableView {
            Label("No Selection", systemImage: "sidebar.right")
        } description: {
            Text(text)
        }
    }
}

// MARK: - Shared pieces

/// Shows or hides the inspector column (⌥⌘I).
struct InspectorToggle: View {
    @Environment(AppViewModel.self) private var vm

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) { vm.showsInspector.toggle() }
        } label: {
            Label(vm.showsInspector ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.trailing")
        }
        .help("\(vm.showsInspector ? "Hide" : "Show") Inspector (⌥⌘I)")
    }
}

/// The inspector's title block: icon, name, status line and primary actions.
struct InspectorHeader<Icon: View, Subtitle: View, Actions: View>: View {
    let title: String
    var monospacedTitle = false
    @ViewBuilder var icon: () -> Icon
    @ViewBuilder var subtitle: () -> Subtitle
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                icon()
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(monospacedTitle ? .system(.headline, design: .monospaced) : .headline)
                        .lineLimit(2)
                        .textSelection(.enabled)
                    HStack(spacing: 6) { subtitle() }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) { actions() }
                .controlSize(.small)
        }
        .padding(14)
    }
}

/// A gray capsule matching `StatusPill`, for parked things: a settled branch
/// environment ("Settled") or an archived site ("Archived").
struct SettledPill: View {
    var label = "Settled"

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "archivebox").font(.caption2.weight(.semibold))
            Text(label).font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.gray.opacity(0.14), in: Capsule())
        .foregroundStyle(.secondary)
    }
}

/// Stacks inspector sections with hairlines between them.
struct InspectorStack<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Group(subviews: content()) { sections in
                    ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                        if index > 0 { Divider().padding(.horizontal, 14) }
                        section
                    }
                }
            }
            .padding(.bottom, 16)
        }
    }
}
