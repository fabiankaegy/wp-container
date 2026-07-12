import Foundation

/// Slug sanitization shared by site slugs and branch slugs.
/// Output is restricted to `[a-z0-9-]`, collision-suffixed on demand.
public enum Slug {
    /// Lowercase, ASCII-fold, and reduce to `[a-z0-9-]` with single dashes.
    public static func make(_ raw: String) -> String {
        let folded = raw.folding(options: .diacriticInsensitive, locale: .current).lowercased()
        var out = ""
        var lastDash = false
        for ch in folded {
            if (ch >= "a" && ch <= "z") || (ch >= "0" && ch <= "9") {
                out.append(ch)
                lastDash = false
            } else if ch == "-" || ch == "_" || ch == " " || ch == "." || ch == "/" {
                if !out.isEmpty && !lastDash {
                    out.append("-")
                    lastDash = true
                }
            }
            // all other characters are dropped
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }

    /// A slug guaranteed not to collide with `existing`, suffixing `-2`, `-3`, …
    public static func unique(_ raw: String, existing: Set<String>, fallback: String = "site") -> String {
        let base0 = make(raw)
        let base = base0.isEmpty ? fallback : base0
        if !existing.contains(base) { return base }
        var n = 2
        while existing.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }
}
