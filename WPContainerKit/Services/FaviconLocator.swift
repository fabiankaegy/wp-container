import Foundation

/// Pure, file-system-only lookup of a site's favicon / site-icon so it can be
/// used as the site avatar (PLAN.md §2l). No HTTP, no image decoding — it just
/// returns the best candidate file URL. Decoding/downsampling happens in the UI
/// layer with a bounded cache.
///
/// Search order (first hit wins):
///  1. `wordpress/favicon.{ico,png}` — a favicon dropped at the web root.
///  2. `wp-content/uploads/**/…site-icon…` / `cropped-*` — WordPress stores the
///     Site Icon as resized crops in uploads; prefer the largest crop ≥ 64px.
///  3. `wp-content/themes/*/favicon.{ico,png}` — last resort.
///
/// SVG is intentionally unsupported: ImageIO/NSImage rasterize it unreliably at
/// avatar sizes, so `.svg` files are skipped (documented in PLAN.md §2l).
public enum FaviconLocator {
    /// Raster extensions we trust to decode at avatar size.
    private static let supportedExtensions: Set<String> = ["ico", "png", "jpg", "jpeg"]

    /// Locate the best favicon candidate for a site's `wordpress/` folder, or
    /// nil when none is found.
    public static func locate(in wordpressFolder: URL) -> URL? {
        let fm = FileManager.default

        // 1. Web-root favicon.
        for ext in ["png", "ico"] {
            let candidate = wordpressFolder.appendingPathComponent("favicon.\(ext)")
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }

        let uploads = wordpressFolder.appendingPathComponent("wp-content/uploads", isDirectory: true)

        // 2. WordPress Site Icon crops under uploads.
        if let siteIcon = bestSiteIcon(under: uploads) { return siteIcon }

        // 3. Any theme favicon.
        let themes = wordpressFolder.appendingPathComponent("wp-content/themes", isDirectory: true)
        if let entries = try? fm.contentsOfDirectory(at: themes, includingPropertiesForKeys: nil) {
            for theme in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                for ext in ["png", "ico"] {
                    let candidate = theme.appendingPathComponent("favicon.\(ext)")
                    if fm.fileExists(atPath: candidate.path) { return candidate }
                }
            }
        }

        return nil
    }

    /// The largest site-icon crop (by filename `-WxH` suffix, preferring ≥ 64px)
    /// found within `uploads`, scanned to a bounded depth so a big media library
    /// never makes this expensive.
    private static func bestSiteIcon(under uploads: URL) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: uploads.path) else { return nil }

        var best: (url: URL, width: Int)?
        let maxDepth = 4

        func scan(_ dir: URL, depth: Int) {
            guard depth <= maxDepth,
                  let entries = try? fm.contentsOfDirectory(
                    at: dir,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]) else { return }
            for entry in entries {
                let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir {
                    scan(entry, depth: depth + 1)
                    continue
                }
                let name = entry.lastPathComponent.lowercased()
                guard supportedExtensions.contains(entry.pathExtension.lowercased()) else { continue }
                let looksLikeSiteIcon = name.contains("site-icon")
                    || (name.hasPrefix("cropped-") && name.contains("x"))
                guard looksLikeSiteIcon else { continue }
                let width = parsedWidth(name) ?? 0
                if best == nil || width > best!.width {
                    best = (entry, width)
                }
            }
        }

        scan(uploads, depth: 1)

        guard let best else { return nil }
        // Prefer a crop of at least 64px; if the only matches are smaller (or
        // dimensionless), still use the largest we found.
        return best.url
    }

    /// Parse the width from a WordPress resize suffix like `-512x512.png` → 512.
    private static func parsedWidth(_ name: String) -> Int? {
        guard let range = name.range(of: #"-(\d+)x\d+\."#, options: .regularExpression) else { return nil }
        let match = name[range]                 // e.g. "-512x512."
        let digits = match.dropFirst().prefix { $0.isNumber }
        return Int(digits)
    }
}
