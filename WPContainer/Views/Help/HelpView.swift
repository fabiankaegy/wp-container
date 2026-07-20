import SwiftUI
import WPContainerKit

/// In-app feature guide: a two-pane help browser with a selectable topic list on
/// the left and a scrolling detail pane on the right. All content is static
/// (`HelpTopic.all`), so the view needs no environment objects and can be hosted
/// in its own resizable `Window` scene (~760×580). "Welcome to WP Container" is
/// selected by default.
struct HelpView: View {
    @State private var selection: HelpTopic.ID? = HelpTopic.all.first?.id

    private var selectedTopic: HelpTopic {
        HelpTopic.all.first { $0.id == selection } ?? HelpTopic.all[0]
    }

    var body: some View {
        NavigationSplitView {
            List(HelpTopic.all, selection: $selection) { topic in
                HelpTopicRow(topic: topic, isSelected: topic.id == selection)
                    .tag(topic.id)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
            .navigationTitle("Help")
        } detail: {
            HelpDetailView(topic: selectedTopic)
        }
        .frame(minWidth: 680, idealWidth: 760, minHeight: 480, idealHeight: 580)
    }
}

// MARK: - Sidebar row

/// A single topic in the sidebar list: a tinted rounded-square icon, the topic
/// title, and a one-line summary.
private struct HelpTopicRow: View {
    let topic: HelpTopic
    /// When the row is selected the sidebar paints a filled accent background, so
    /// the accent-on-accent icon would vanish — invert it to white in that state.
    var isSelected: Bool = false

    var body: some View {
        HStack(spacing: 11) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.22) : Theme.accent.opacity(0.14))
                .frame(width: 30, height: 30)
                .overlay {
                    Image(systemName: topic.icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.white : Theme.accent)
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(topic.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(topic.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Detail pane

/// The scrolling right-hand pane: a large header (icon, title, intro) followed
/// by each of the topic's sub-sections rendered as cards.
private struct HelpDetailView: View {
    let topic: HelpTopic

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                ForEach(topic.sections) { section in
                    HelpSectionCard(section: section)
                }
            }
            .padding(28)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Let people copy any of the help text (commands, ports, URLs).
            .textSelection(.enabled)
        }
        .navigationTitle(topic.title)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.accent.opacity(0.14))
                    .frame(width: 52, height: 52)
                    .overlay {
                        Image(systemName: topic.icon)
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                Text(topic.title)
                    .font(.system(.largeTitle, weight: .bold))
                    .lineLimit(2)
            }
            Text(styledMarkdown(topic.intro))
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Section card

/// Renders one `HelpSection` as a card: title, optional body prose, numbered
/// steps, bullets, and an optional tip callout — only the populated slots show.
private struct HelpSectionCard: View {
    let section: HelpSection

    var body: some View {
        SectionCard(title: section.title) {
            VStack(alignment: .leading, spacing: 12) {
                if let body = section.body {
                    Text(styledMarkdown(body))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !section.steps.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(section.steps.enumerated()), id: \.offset) { index, step in
                            StepRow(number: index + 1, text: step)
                        }
                    }
                }
                if !section.bullets.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(section.bullets, id: \.self) { bullet in
                            BulletRow(text: bullet)
                        }
                    }
                }
                if let tip = section.tip {
                    TipRow(text: tip)
                }
            }
        }
    }
}

/// A numbered step: an accent-tinted circle with the step number, then the text.
private struct StepRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.accent)
                .frame(width: 22, height: 22)
                .background(Theme.accent.opacity(0.14), in: Circle())
            Text(styledMarkdown(text))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// An unordered bullet point with an accent dot.
private struct BulletRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "circle.fill")
                .font(.system(size: 5))
                .foregroundStyle(Theme.accent)
                .padding(.top, 7)
            Text(styledMarkdown(text))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A highlighted "tip" callout with a lightbulb and a subtle accent-tinted fill.
private struct TipRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "lightbulb.fill")
                .font(.callout)
                .foregroundStyle(Theme.accent)
            Text(styledMarkdown(text))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Theme.accent.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Inline Markdown

/// Render a string as inline Markdown so backticked `code`, **bold**, and links
/// display properly (help content lives in `String` properties, which `Text`
/// otherwise shows verbatim). Inline-code runs additionally get an accent color
/// and a subtle tinted background so backticked terms — commands, ports, paths —
/// stand out. Falls back to plain text if the Markdown can't be parsed.
func styledMarkdown(_ string: String) -> AttributedString {
    var attributed: AttributedString
    do {
        attributed = try AttributedString(
            markdown: string,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
    } catch {
        return AttributedString(string)
    }
    // Collect code-run ranges first, then style — mutating during iteration of
    // `.runs` would invalidate it.
    let codeRanges = attributed.runs
        .filter { $0.inlinePresentationIntent?.contains(.code) == true }
        .map(\.range)
    for range in codeRanges {
        attributed[range].foregroundColor = Theme.accent
        attributed[range].backgroundColor = Theme.accent.opacity(0.12)
    }
    return attributed
}

#Preview {
    HelpView()
}
