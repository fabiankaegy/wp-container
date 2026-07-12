import SwiftUI
import WPContainerKit

/// A single site row in the dark sidebar: colored avatar, name, status dot, and
/// a port subtitle. Text uses the on-dark palette; the selection/hover fill is
/// applied by the enclosing sidebar row container.
struct SiteRow: View {
    let site: Site
    let envCount: Int

    var body: some View {
        HStack(spacing: 10) {
            SiteAvatar(name: site.name, slug: site.slug, size: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(site.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Theme.onFrame)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text("localhost:\(String(site.port))")
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

            StatusDot(status: site.status)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
    }
}
