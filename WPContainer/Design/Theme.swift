import SwiftUI
import WPContainerKit

/// Design tokens and shared UI atoms: colors, card styling, section colors,
/// status dot / pill, and deterministic per-site avatars. Centralizing these
/// keeps every view thin and visually consistent across light and dark modes.
enum Theme {
    /// WordPress-blue accent (mirrors the asset AccentColor / app icon).
    static let accent = Color("AccentColor")

    /// Corner radius used for all cards and prominent controls.
    static let cardRadius: CGFloat = 12
    static let cardPadding: CGFloat = 18

    // MARK: Status colors

    static func color(for status: SiteStatus) -> Color {
        switch status {
        case .running:  return .green
        case .starting: return .orange
        case .stopping: return .orange
        case .error:    return .red
        case .stopped:  return .gray
        }
    }

    // MARK: Section colors

    /// The tile color for a sidebar or inspector section, by its title.
    static func sectionColor(for title: String) -> Color {
        switch title {
        case "Overview", "Site", "Domain", "Environment": return .blue
        case "Live": return .green
        case "Branches": return .purple
        case "Development": return .orange
        case "Software": return .indigo
        case "Resources": return .teal
        case "Integrations": return .pink
        case "Idle stop": return .mint
        case "Danger Zone": return .red
        case "Stack": return .orange
        case "Lifecycle": return .brown
        case "Network Sites": return .cyan
        default: return .gray
        }
    }

    // MARK: Avatar hue

    /// Deterministic hue in 0..<1 derived from a slug (stable across launches —
    /// deliberately NOT Swift's randomized `Hasher`).
    static func avatarHue(for slug: String) -> Double {
        var hash: UInt64 = 5381
        for scalar in slug.unicodeScalars {
            hash = (hash &* 33) &+ UInt64(scalar.value)
        }
        return Double(hash % 360) / 360.0
    }

    static func avatarGradient(for slug: String) -> LinearGradient {
        let hue = avatarHue(for: slug)
        return LinearGradient(
            colors: [
                Color(hue: hue, saturation: 0.55, brightness: 0.95),
                Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.70, brightness: 0.80),
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    /// One or two uppercase initials from a name.
    static func initials(for name: String) -> String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" })
        if words.isEmpty { return "?" }
        if words.count == 1 {
            return String(words[0].prefix(2)).uppercased()
        }
        return (String(words[0].prefix(1)) + String(words[1].prefix(1))).uppercased()
    }
}

// MARK: - Card modifier

private struct CardModifier: ViewModifier {
    var padding: CGFloat = Theme.cardPadding
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
            )
    }
}

extension View {
    /// Wraps content in a Studio-style rounded card with a subtle border.
    func card(padding: CGFloat = Theme.cardPadding) -> some View {
        modifier(CardModifier(padding: padding))
    }
}

// MARK: - Status atoms

/// Small colored dot; pulses gently while a lifecycle transition is in flight.
struct StatusDot: View {
    let status: SiteStatus
    var size: CGFloat = 9

    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(Theme.color(for: status))
            .frame(width: size, height: size)
            .overlay {
                if status.isTransitional {
                    Circle()
                        .stroke(Theme.color(for: status), lineWidth: 2)
                        .scaleEffect(pulse ? 2.0 : 1.0)
                        .opacity(pulse ? 0 : 0.7)
                }
            }
            .onAppear { if status.isTransitional { pulse = true } }
            .animation(status.isTransitional
                       ? .easeOut(duration: 1.0).repeatForever(autoreverses: false)
                       : .default, value: pulse)
    }
}

/// Rounded status pill: colored dot + label, with a tinted background.
struct StatusPill: View {
    let status: SiteStatus

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(status: status, size: 8)
            Text(status.label)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Theme.color(for: status).opacity(0.14), in: Capsule())
        .foregroundStyle(Theme.color(for: status))
    }
}

/// Rounded-square site avatar. Renders the site's WordPress Site Icon (read
/// from its database while it runs, see `SiteIcons`) or else a favicon found in
/// its files (PLAN.md §2l), falling back to a colored initials gradient. The
/// image loads asynchronously off-main via `FaviconImageCache` and re-checks
/// when `reloadToken` changes (site selection / start) or a Site Icon resolves,
/// so an icon added while the app is open appears without a relaunch.
struct SiteAvatar: View {
    let name: String
    let slug: String
    var size: CGFloat = 30
    /// The site's `wordpress/` folder — searched for a favicon. nil = no lookup
    /// (e.g. the not-yet-created site in the Add Site sheet).
    var wordpressFolder: URL? = nil
    /// Any value that should force a favicon re-check (e.g. the site status), so
    /// an icon uploaded while running is picked up after a start.
    var reloadToken: AnyHashable = 0

    @State private var favicon: NSImage?

    private var corner: CGFloat { size * 0.28 }

    var body: some View {
        Group {
            if let favicon {
                Image(nsImage: favicon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                    .background(
                        RoundedRectangle(cornerRadius: corner, style: .continuous)
                            .fill(Color.white)
                    )
            } else {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(Theme.avatarGradient(for: slug))
                    .frame(width: size, height: size)
                    .overlay {
                        Text(Theme.initials(for: name))
                            .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    }
            }
        }
        .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
        .task(id: FaviconKey(path: wordpressFolder?.path, token: reloadToken, icons: SiteIcons.shared.version)) {
            await loadFavicon()
        }
    }

    private func loadFavicon() async {
        guard let wordpressFolder else { favicon = nil; return }
        let data = await FaviconImageCache.shared.faviconPNG(wordpressFolder: wordpressFolder)
        favicon = data.flatMap(NSImage.init(data:))
    }

    /// Distinct task identity: reload when either the folder or the token change.
    private struct FaviconKey: Hashable {
        let path: String?
        let token: AnyHashable
        /// Bumped when a Site Icon resolves from a site's database.
        let icons: Int
    }
}
