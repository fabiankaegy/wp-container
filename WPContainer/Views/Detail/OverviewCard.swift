import SwiftUI
import WPContainerKit

/// Site "at a glance" details, Studio-style: a labeled grid of URL, path,
/// WordPress image, PHP hint, DB engine, and admin credentials with copy
/// buttons.
struct OverviewCard: View {
    let site: Site

    var body: some View {
        SectionCard(title: "Overview", systemImage: "info.circle") {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 24, verticalSpacing: 12) {
                InfoRow(label: "Local URL") {
                    HStack(spacing: 6) {
                        Button(site.localURL.absoluteString) {
                            SystemActions.openInBrowser(site.localURL)
                        }
                        .buttonStyle(.link)
                        CopyButton(value: site.localURL.absoluteString, help: "Copy URL")
                    }
                }

                InfoRow(label: "Path") {
                    HStack(spacing: 6) {
                        Button {
                            SystemActions.revealInFinder(site.path)
                        } label: {
                            Text(site.path.path(percentEncoded: false))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .buttonStyle(.link)
                        CopyButton(value: site.path.path(percentEncoded: false), help: "Copy path")
                    }
                }

                InfoRow(label: "WordPress") {
                    Text(site.imageTag).textSelection(.enabled)
                }

                InfoRow(label: "PHP") {
                    Text(phpHint).foregroundStyle(.secondary)
                }

                InfoRow(label: "Database") {
                    Text("MariaDB 11").textSelection(.enabled)
                }

                InfoRow(label: "Admin") {
                    HStack(spacing: 6) {
                        credential(SiteRecipe.adminUser)
                        Text("/").foregroundStyle(.tertiary)
                        credential(SiteRecipe.adminPassword)
                        Button("Open WP Admin") {
                            SystemActions.openInBrowser(site.adminURL)
                        }
                        .buttonStyle(.link)
                        .padding(.leading, 4)
                    }
                }
            }
        }
    }

    private func credential(_ value: String) -> some View {
        HStack(spacing: 3) {
            Text(value).monospaced()
            CopyButton(value: value, help: "Copy \(value)")
        }
    }

    private var phpHint: String {
        if let php = site.phpVersion, !php.isEmpty { return php }
        if let range = site.imageTag.range(of: #"php\d\.\d"#, options: .regularExpression) {
            return site.imageTag[range].replacingOccurrences(of: "php", with: "PHP ")
        }
        return "Bundled with image"
    }
}
