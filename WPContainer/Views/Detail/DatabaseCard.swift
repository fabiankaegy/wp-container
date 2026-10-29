import SwiftUI
import WPContainerKit

/// Connection details for an instance's MariaDB database, for desktop clients
/// such as TablePlus. The host is the DB container's IP, looked up while it
/// runs; the rest are fixed credentials.
struct DatabaseCard: View {
    @Environment(AppViewModel.self) private var vm
    let instance: any RunnableInstance
    let status: SiteStatus

    @State private var host: String?

    var body: some View {
        SectionCard(title: "Database", systemImage: "cylinder.split.1x2") {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 24, verticalSpacing: 12) {
                InfoRow(label: "Host") {
                    if let host {
                        credential(host)
                    } else {
                        Text("Shown while the database is running.").foregroundStyle(.secondary)
                    }
                }
                InfoRow(label: "Port") {
                    credential(String(SiteRecipe.dbPort))
                }
                InfoRow(label: "Database") {
                    credential(instance.databaseName)
                }
                InfoRow(label: "User") {
                    credential(SiteRecipe.dbUser)
                }
                InfoRow(label: "Password") {
                    credential(SiteRecipe.dbPassword)
                }
                if let host {
                    InfoRow(label: "URL") {
                        connectionURL(SiteRecipe.databaseURL(dbHost: host, database: instance.databaseName))
                    }
                }
            }
        }
        .task(id: status) { host = await vm.databaseHost(instance) }
    }

    private func credential(_ value: String) -> some View {
        HStack(spacing: 3) {
            Text(value).monospaced().textSelection(.enabled)
            CopyButton(value: value, help: "Copy \(value)")
        }
    }

    private func connectionURL(_ value: String) -> some View {
        HStack(spacing: 6) {
            Text(value)
                .monospaced()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            CopyButton(value: value, help: "Copy connection URL")
            if let url = URL(string: value), let app = SystemActions.appName(toOpen: url) {
                Button("Open in \(app)") {
                    SystemActions.openInBrowser(url)
                }
                .buttonStyle(.link)
                .padding(.leading, 4)
            }
        }
    }
}
