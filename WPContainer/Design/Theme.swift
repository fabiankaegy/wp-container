import SwiftUI
import WPContainerKit

/// Studio-inspired design tokens and shared UI atoms: colors, card styling,
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
        case .stopped:  return .secondary
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

/// Colored rounded-square avatar with the site's initials.
struct SiteAvatar: View {
    let name: String
    let slug: String
    var size: CGFloat = 30

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(Theme.avatarGradient(for: slug))
            .frame(width: size, height: size)
            .overlay {
                Text(Theme.initials(for: name))
                    .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
    }
}
