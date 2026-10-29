import SwiftUI
import WPContainerKit

/// Site "at a glance" details, Studio-style: a labeled grid of URL, path,
/// WordPress image, PHP hint, DB engine, and admin credentials with copy
/// buttons.
struct OverviewCard: View {
    let site: Site

    @State private var missingHosts: [String] = []

    var body: some View {
        SectionCard(title: "Overview", systemImage: "info.circle") {
            if !missingHosts.isEmpty {
                MissingHostsRow(site: site, missing: $missingHosts)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 24, verticalSpacing: 12) {
                InfoRow(label: "URL") {
                    HStack(spacing: 6) {
                        Button(site.url.absoluteString) {
                            SystemActions.openInBrowser(site.url)
                        }
                        .buttonStyle(.link)
                        CopyButton(value: site.url.absoluteString, help: "Copy URL")
                    }
                }

                if site.url != site.localURL {
                    InfoRow(label: "Local port") {
                        HStack(spacing: 6) {
                            Text(site.localURL.absoluteString).foregroundStyle(.secondary).textSelection(.enabled)
                            CopyButton(value: site.localURL.absoluteString, help: "Copy local URL")
                        }
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

                if site.mailpitEnabled, let mailbox = site.mailboxURL {
                    InfoRow(label: "Mailbox") {
                        HStack(spacing: 6) {
                            Button(mailbox.absoluteString) {
                                SystemActions.openInBrowser(mailbox)
                            }
                            .buttonStyle(.link)
                            .disabled(!site.status.isRunning)
                            CopyButton(value: mailbox.absoluteString, help: "Copy mailbox URL")
                        }
                    }
                }

                InfoRow(label: "WordPress") {
                    Text(site.imageTag).textSelection(.enabled)
                }

                InfoRow(label: "PHP") {
                    Text(phpHint).foregroundStyle(.secondary)
                }

                InfoRow(label: "Web server") {
                    Text(site.webServer.label).textSelection(.enabled)
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
                            SystemActions.openInBrowser(site.wpAdminURL)
                        }
                        .buttonStyle(.link)
                        .padding(.leading, 4)
                    }
                }
            }
        }
        .trackingMissingHosts(of: site, into: $missingHosts)
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
