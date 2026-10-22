import SwiftUI
import WPContainerKit

/// A single site row in the dark sidebar: colored avatar, name, status dot, and
/// a port subtitle. Text uses the on-dark palette; the selection/hover fill is
/// applied by the enclosing sidebar row container.
///
/// Sites with worktree envs (PLAN.md §2b nested design) additionally get a
/// "layers" badge on the avatar corner and a disclosure chevron that collapses
/// the env rows nested under the row.
struct SiteRow: View {
    let site: Site
    let envCount: Int
    /// Whether a public share of this site is live.
    var isShared: Bool = false
    /// When provided, the trailing status dot becomes a start/stop control
    /// (PLAN.md §2l). Left nil for non-interactive contexts (e.g. drag preview).
    var onToggleRun: (() -> Void)? = nil
    /// Disclosure state for the nested env rows; the chevron renders only when
    /// the site has envs AND a toggle closure is provided (not in drag previews).
    var isExpanded: Bool = true
    var onToggleExpanded: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            SiteAvatar(name: site.name, slug: site.slug, size: 28,
                       wordpressFolder: site.wordpressFolder, reloadToken: site.status)
                .overlay(alignment: .bottomTrailing) {
                    if envCount > 0 { layersBadge }
                }

            VStack(alignment: .leading, spacing: 1) {
                Text(site.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Theme.onFrame)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(site.displayHost)
                    if envCount > 0 {
                        Text("·")
                        Label("\(envCount)", systemImage: "arrow.triangle.branch")
                            .labelStyle(.titleAndIcon)
                    }
                }
                .font(.caption)
                .foregroundStyle(Theme.onFrameSecondary)
                .lineLimit(1)
            }

            Spacer(minLength: 4)

            if envCount > 0, let onToggleExpanded {
                DisclosureChevron(isExpanded: isExpanded, onToggle: onToggleExpanded)
            }

            if isShared {
                Image(systemName: "link")
                    .font(.caption2)
                    .foregroundStyle(Theme.onFrameSecondary)
                    .accessibilityLabel("Shared")
            }

            if let onToggleRun {
                InteractiveStatusDot(status: site.status, onToggle: onToggleRun)
            } else {
                StatusDot(status: site.status)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
    }

    /// The "special layer icon" (§2b): a small layers glyph pinned to the
    /// avatar's corner signalling this site has worktree clones. The favicon /
    /// initials avatar stays underneath.
    private var layersBadge: some View {
        Image(systemName: "square.3.layers.3d")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 13, height: 13)
            .background(Circle().fill(Theme.accent))
            .overlay(Circle().strokeBorder(Theme.frame, lineWidth: 1.5))
            .offset(x: 4, y: 4)
    }
}

/// The chevron that collapses/expands a site's nested env rows (§2b). Clicks
/// are consumed by the Button so row selection is unaffected.
private struct DisclosureChevron: View {
    let isExpanded: Bool
    let onToggle: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onToggle) {
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(hovering ? Theme.onFrame : Theme.onFrameSecondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(isExpanded ? "Hide branch environments" : "Show branch environments")
    }
}

/// A status dot that doubles as a start/stop control (PLAN.md §2l). On hover it
/// swaps the colored dot for a small play/stop glyph within a fixed-size hit
/// area, so the dot's size and position never shift. Transitional states show
/// the existing pulse and are non-interactive. Clicks are handled by the inner
/// Button, so they do not bubble up to the row's selection tap.
struct InteractiveStatusDot: View {
    let status: SiteStatus
    let onToggle: () -> Void
    var size: CGFloat = 9

    @State private var hovering = false

    /// Stable hit target so the glyph swap causes no layout shift.
    private var hitSize: CGFloat { 16 }

    var body: some View {
        if status.isTransitional {
            // Non-interactive: keep the existing pulse, centered in the hit area.
            StatusDot(status: status, size: size)
                .frame(width: hitSize, height: hitSize)
        } else {
            Button(action: onToggle) {
                ZStack {
                    StatusDot(status: status, size: size)
                        .opacity(hovering ? 0 : 1)
                    if hovering {
                        Image(systemName: status.isRunning ? "stop.fill" : "play.fill")
                            .font(.system(size: size, weight: .bold))
                            .foregroundStyle(status.isRunning ? Color.red : Theme.accent)
                    }
                }
                .frame(width: hitSize, height: hitSize)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(status.isRunning ? "Stop site" : "Start site")
        }
    }
}
