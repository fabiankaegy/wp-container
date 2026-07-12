import Foundation

/// WordPress network type for a site (PLAN.md §2j). `none` is an ordinary
/// single site; the two multisite modes map to `wp core multisite-install
/// [--subdomains]` plus the matching `.htaccess` + wp-config constants.
public enum NetworkType: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case none
    case subdirectory
    case subdomain

    public var id: String { rawValue }

    /// Whether this is any kind of multisite network.
    public var isMultisite: Bool { self != .none }

    /// Whether subsites live on subdomains (`site2.<host>`) rather than
    /// subdirectories (`<host>/site2`).
    public var isSubdomain: Bool { self == .subdomain }

    /// Human-readable label for pickers / CLI output.
    public var label: String {
        switch self {
        case .none:         return "Single site"
        case .subdirectory: return "Multisite — subdirectories"
        case .subdomain:    return "Multisite — subdomains"
        }
    }
}
