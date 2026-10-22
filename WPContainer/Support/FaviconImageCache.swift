import AppKit
import ImageIO
import UniformTypeIdentifiers
import WPContainerKit

/// Loads and caches downsampled favicon images for use as site avatars
/// (PLAN.md §2l). Runs entirely off the main actor and is bounded on every
/// axis:
///
/// - The site's real WordPress Site Icon wins when `SiteIcons` has resolved
///   one (`setPreferred`); otherwise locating the file is delegated to the
///   pure `FaviconLocator` heuristics.
/// - Decoding uses ImageIO thumbnail generation capped at `maxPixel`, so a
///   huge or malformed source never blows up memory.
/// - Results are cached per `wordpress/` folder and invalidated by the located
///   file's modification date, so a favicon uploaded/changed/deleted while the
///   app is open is picked up on the next re-check (site selection or start).
///
/// The cache returns PNG `Data` (Sendable); the view builds the `NSImage`.
actor FaviconImageCache {
    static let shared = FaviconImageCache()

    private struct Entry {
        let sourcePath: String?
        let mtime: Date?
        let png: Data?
    }

    private var cache: [String: Entry] = [:]
    /// The Site Icon file per `wordpress/` folder path, from the site's database.
    private var preferred: [String: URL] = [:]

    /// Records (or clears) the Site Icon file for a site's `wordpress/` folder.
    func setPreferred(_ file: URL?, wordpressFolder: URL) {
        preferred[wordpressFolder.path] = file
    }
    private let maxPixel: CGFloat = 128

    /// Resolve the favicon PNG data for a site's `wordpress/` folder, or nil.
    func faviconPNG(wordpressFolder: URL) -> Data? {
        let key = wordpressFolder.path
        let known = preferred[key].flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        let located = known ?? FaviconLocator.locate(in: wordpressFolder)
        let mtime = located.flatMap {
            (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }

        if let entry = cache[key],
           entry.sourcePath == located?.path,
           entry.mtime == mtime {
            return entry.png
        }

        let png = located.flatMap { downsampledPNG(from: $0, maxPixel: maxPixel) }
        cache[key] = Entry(sourcePath: located?.path, mtime: mtime, png: png)
        return png
    }

    /// Downsample an image file to a square-bounded thumbnail and encode PNG.
    private func downsampledPNG(from url: URL, maxPixel: CGFloat) -> Data? {
        let srcOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, srcOptions as CFDictionary) else { return nil }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
