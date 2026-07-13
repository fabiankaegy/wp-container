import SwiftUI
import WPContainerKit

/// A single site row in the dark sidebar: colored avatar, name, status dot, and
/// a port subtitle. Text uses the on-dark palette; the selection/hover fill is
/// applied by the enclosing sidebar row container.
struct SiteRow: View {
    let site: Site
    let envCount: Int
    /// When provided, the trailing status dot becomes a start/stop control
    /// (PLAN.md §2l). Left nil for non-interactive contexts (e.g. drag preview).
    var onToggleRun: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            SiteAvatar(name: site.name, slug: site.slug, size: 28)

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
