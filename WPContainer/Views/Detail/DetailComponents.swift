import SwiftUI

/// Small square icon-only button used to copy a value to the clipboard, with a
/// brief "copied" checkmark confirmation.
struct CopyButton: View {
    let value: String
    var help: String = "Copy"

    @State private var copied = false

    var body: some View {
        Button {
            SystemActions.copyToClipboard(value)
            withAnimation { copied = true }
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                withAnimation { copied = false }
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .foregroundStyle(copied ? .green : .secondary)
                .frame(width: 16)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// A labeled key/value row in an info grid. The value can be plain text, a
/// clickable link (browser/Finder), and optionally show a copy button.
struct InfoRow<Value: View>: View {
    let label: String
    @ViewBuilder var value: () -> Value

    var body: some View {
        GridRow {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            value()
                .font(.callout)
                .gridColumnAlignment(.leading)
        }
    }
}

/// A card section with a title (optionally a trailing accessory) and content.
struct SectionCard<Content: View, Accessory: View>: View {
    let title: String
    var systemImage: String?
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label {
                    Text(title).font(.headline)
                } icon: {
                    if let systemImage { Image(systemName: systemImage).foregroundStyle(Theme.accent) }
                }
                .labelStyle(.titleAndIcon)
                Spacer()
                accessory()
            }
            content()
        }
        .card()
    }
}

extension SectionCard where Accessory == EmptyView {
    init(title: String, systemImage: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, systemImage: systemImage, accessory: { EmptyView() }, content: content)
    }
}
