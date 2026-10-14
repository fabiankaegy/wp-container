import AppKit
import SwiftUI
import WPContainerKit

/// Root window, Studio-style: a DARK FRAME (near-black shell spanning the whole
/// window, including the sidebar and the hidden-title-bar band) with the detail
/// content floating inside it as a light, rounded, inset panel. The top band is
/// left free of controls so the window stays draggable there.
struct MainWindow: View {
    @Environment(AppViewModel.self) private var vm
    /// Persisted sidebar width (written only when a drag ends, never per-frame —
    /// per-frame UserDefaults writes are a big cause of resize stutter).
    @AppStorage("sidebarWidth") private var persistedSidebarWidth: Double = 272
    /// Live width driving the layout during a drag. Seeded from the persisted
    /// value on appear; committed back to it when the drag ends.
    @State private var sidebarWidth: Double = 272
    private let sidebarRange: ClosedRange<Double> = 220...460
    /// The default width the divider snaps to (with a haptic tick) when dragged
    /// within `snapDistance` points of it.
    private let sidebarDefault: Double = 272

    var body: some View {
        @Bindable var vm = vm
        ZStack(alignment: .topLeading) {
            Theme.frame.ignoresSafeArea()

            HStack(spacing: 0) {
                SidebarView()
                    .frame(width: sidebarWidth)

                SidebarResizeHandle(width: $sidebarWidth, range: sidebarRange, snapTo: sidebarDefault) {
                    persistedSidebarWidth = sidebarWidth
                }

                panel
                    .padding(.top, Theme.titlebarInset)
                    .padding(.trailing, 10)
                    .padding(.bottom, 10)
            }
            // Lay out from the window's top edge rather than below the system
            // title-bar safe area, so the dark band is exactly `titlebarInset`
            // tall (just enough for the traffic lights), not safe area + padding.
            .ignoresSafeArea(edges: .top)
        }
        .onAppear { sidebarWidth = persistedSidebarWidth.clamped(to: sidebarRange) }
        .sheet(isPresented: $vm.presentingAddSite) {
            AddSiteSheet()
        }
        .sheet(isPresented: $vm.presentingNewEnv) {
            if let site = vm.selectedSite {
                NewBranchEnvSheet(site: site)
            }
        }
        .sheet(isPresented: $vm.presentingImportDB, onDismiss: { vm.pendingImportDump = nil }) {
            if let site = vm.selectedSite {
                ImportDatabaseSheet(site: site, initialDump: vm.pendingImportDump)
            }
        }
        .sheet(isPresented: $vm.presentingCLIInstallOffer) {
            CLIInstallOfferSheet()
        }
    }

    // MARK: Floating light panel

    private var panel: some View {
        detail
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.panelBorder, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .top) {
                VStack(spacing: 0) {
                    localNetworkBanner
                    errorBanner
                }
            }
            .shadow(color: .black.opacity(0.28), radius: 12, y: 3)
    }

    @ViewBuilder
    private var detail: some View {
        if let status = vm.systemStatus, !status.isReady {
            OnboardingView(status: status)
        } else if let site = vm.selectedSite {
            SiteDetailView(site: site)
                .id(site.id)
        } else if let env = vm.selectedEnv {
            // Worktree-env rows are selectable in the sidebar (§2b) and get a
            // compact detail pane of their own.
            EnvDetailView(env: env)
                .id(env.id)
        } else {
            ContentUnavailableView {
                Label("No Site Selected", systemImage: "square.stack.3d.up")
            } description: {
                Text("Select a site from the sidebar, or add a new one.")
            } actions: {
                Button("Add Site") { vm.presentingAddSite = true }
                    .buttonStyle(.borderedProminent)
            }
            // Fill the panel and center: the enclosing `panel` frame pins its
            // content to `.topLeading` (correct for the scrolling site detail),
            // which otherwise strands this placeholder at the very top. Expanding
            // to fill makes the placeholder own the whole panel and center within.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// macOS is refusing this app's connections to the container network, so every
    /// site and environment is unreachable. Deliberately NOT dismissible: it is a
    /// TCC decision, nothing in this app can clear it, and it disappears by itself
    /// within one reconcile tick of the user granting access.
    @ViewBuilder
    private var localNetworkBanner: some View {
        if vm.localNetworkDenied {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "network.slash")
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("WP Container needs Local Network access")
                        .font(.callout.weight(.medium))
                    Text("macOS is blocking WP Container from reaching your containers, so sites and environments can’t load. Enable WP Container under Privacy & Security → Local Network.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Open System Settings") { vm.openLocalNetworkSettings() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.red.opacity(0.4), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
            .padding(16)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let err = vm.lastError {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(err)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button {
                    vm.lastError = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.orange.opacity(0.4), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
            .padding(16)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

// MARK: - Sidebar resize

/// A thin drag gutter between the sidebar and the content panel that resizes the
/// sidebar the way the system does. Two things make it smooth:
///
/// 1. The drag is measured in the **global** coordinate space. Measuring in the
///    handle's own space feeds back on itself — the handle moves as the sidebar
///    resizes, distorting `translation` and making the drag stutter/oscillate.
/// 2. `width` is a lightweight `@State` on `MainWindow`; the value is only
///    persisted to `UserDefaults` when the drag ends (via `onCommit`), so there
///    are no synchronous defaults writes mid-drag.
///
/// The native column-resize pointer shows on hover via `.pointerStyle`.
private struct SidebarResizeHandle: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    /// Width the divider snaps to when dragged within `snapDistance` of it.
    let snapTo: Double
    /// Called when the drag ends, to persist the final width.
    var onCommit: () -> Void

    /// Half-width of the snap zone, in points, on either side of `snapTo`.
    private let snapDistance: Double = 5

    /// Sidebar width captured at drag start; the drag is relative to it.
    @State private var startWidth: Double?
    /// Whether the drag is currently held inside the snap zone — used to fire the
    /// haptic exactly once per entry (not on every frame while snapped).
    @State private var snapped = false

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 8)
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        if startWidth == nil { startWidth = width }
                        let raw = (startWidth! + value.translation.width).clamped(to: range)
                        if abs(raw - snapTo) <= snapDistance {
                            // Inside the snap zone: pin to the default width, and
                            // give one alignment tick the first frame we enter.
                            if !snapped {
                                snapped = true
                                NSHapticFeedbackManager.defaultPerformer
                                    .perform(.alignment, performanceTime: .now)
                            }
                            width = snapTo
                        } else {
                            snapped = false
                            width = raw
                        }
                    }
                    .onEnded { _ in
                        startWidth = nil
                        snapped = false
                        onCommit()
                    }
            )
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
