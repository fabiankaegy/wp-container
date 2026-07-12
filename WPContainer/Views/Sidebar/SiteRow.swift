import SwiftUI
import WPContainerKit

/// A single site row in the sidebar: colored avatar, name, status dot, and a
/// port subtitle — Studio-style.
struct SiteRow: View {
    let site: Site
    let envCount: Int

    var body: some View {
        HStack(spacing: 10) {
            SiteAvatar(name: site.name, slug: site.slug, size: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text(site.name)
                    .font(.body.weight(.medium))
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
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 4)

            StatusDot(status: site.status)
        }
        .padding(.vertical, 3)
    }
}
