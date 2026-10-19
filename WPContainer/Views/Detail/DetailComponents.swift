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
/// clickable link (browser/Finder), and optionally show a copy button. In the
/// narrow inspector the label sits above the value, so values aren't squeezed.
struct InfoRow<Value: View>: View {
    let label: String
    @ViewBuilder var value: () -> Value

    @Environment(\.sectionCardStyle) private var style

    var body: some View {
        if style == .inspector {
            GridRow {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.caption).foregroundStyle(.secondary)
                    value().font(.callout)
                }
                .gridCellColumns(2)
                .gridColumnAlignment(.leading)
            }
        } else {
            columns
        }
    }

    private var columns: some View {
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

/// How `SectionCard` renders: a standalone rounded card, or a compact,
/// foldable section stacked in the inspector column.
enum SectionCardStyle { case card, inspector }

extension EnvironmentValues {
    @Entry var sectionCardStyle: SectionCardStyle = .card
}

/// A card section with a title (optionally a trailing accessory) and content.
/// Inside the inspector (`.sectionCardStyle(.inspector)`) it becomes a foldable
/// section with a colored icon tile; which sections are folded is remembered.
struct SectionCard<Content: View, Accessory: View>: View {
    let title: String
    var systemImage: String?
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    @Environment(\.sectionCardStyle) private var style
    @AppStorage("inspectorFoldedSections") private var foldedRaw = ""

    var body: some View {
        switch style {
        case .card: card
        case .inspector: inspectorSection
        }
    }

    private var card: some View {
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

    private var folded: Bool { foldedRaw.split(separator: "|").contains { $0 == title } }

    private func toggleFolded() {
        var titles = foldedRaw.split(separator: "|").map(String.init).filter { $0 != title }
        if !folded { titles.append(title) }
        withAnimation(.easeOut(duration: 0.18)) { foldedRaw = titles.joined(separator: "|") }
    }

    private var inspectorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button(action: toggleFolded) {
                    HStack(spacing: 8) {
                        if let systemImage { SectionIcon(systemName: systemImage, color: Theme.sectionColor(for: title)) }
                        Text(title).font(.callout.weight(.semibold))
                        Spacer(minLength: 4)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if !folded { accessory() }
                Button(action: toggleFolded) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(folded ? 0 : 90))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(folded ? "Show \(title)" : "Hide \(title)")
            }
            if !folded {
                content()
                    .controlSize(.small)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A small rounded tile holding a white SF Symbol, like System Settings' sidebar icons.
struct SectionIcon: View {
    let systemName: String
    let color: Color
    var size: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: systemName)
                    .font(.system(size: size * 0.52, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }
}

extension SectionCard where Accessory == EmptyView {
    init(title: String, systemImage: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, systemImage: systemImage, accessory: { EmptyView() }, content: content)
    }
}

/// A monospaced command snippet with a copy button.
struct CLISnippet: View {
    let command: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(command)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            CopyButton(value: command, help: "Copy command")
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// A small orange capsule flagging something unused for a while: a "Stale"
/// tag or a stale count. On a selected row (accent background) it turns white
/// so it stays readable.
struct StaleBadge: View {
    let text: String
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        let onAccent = prominence == .increased
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background((onAccent ? Color.white : .orange).opacity(onAccent ? 0.25 : 0.18), in: Capsule())
            .foregroundStyle(onAccent ? Color.white : .orange)
    }
}

extension View {
    /// A status color (orange "stale", green "running") that yields to the
    /// row's own text color when the row is selected, where it would clash.
    func statusTint(_ color: Color, when active: Bool = true) -> some View {
        modifier(StatusTint(color: color, active: active))
    }
}

private struct StatusTint: ViewModifier {
    let color: Color
    let active: Bool
    @Environment(\.backgroundProminence) private var prominence

    func body(content: Content) -> some View {
        if active && prominence != .increased {
            content.foregroundStyle(color)
        } else {
            content.foregroundStyle(.secondary)
        }
    }
}
