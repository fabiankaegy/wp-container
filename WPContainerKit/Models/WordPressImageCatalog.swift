import Foundation

/// Curated matrix of WordPress × PHP official image tags (PLAN.md §2k).
///
/// The official `wordpress` image publishes tags shaped `<wp>-php<php>-apache`
/// (e.g. `wordpress:6.8-php8.3-apache`) plus the moving `latest`. Not every
/// WP×PHP pairing is published, so `isKnownValid` gates the combinations the UI
/// offers; a custom-tag escape hatch covers anything outside the matrix.
public enum WordPressImageCatalog {
    /// WordPress versions offered in the setup guide (newest first).
    public static let wordPressVersions: [String] = ["latest", "6.8", "6.7", "6.6"]

    /// PHP versions offered in the setup guide (newest first).
    public static let phpVersions: [String] = ["8.4", "8.3", "8.2", "8.1"]

    /// The default PHP version paired with a fresh site.
    public static let defaultPHP = "8.3"

    /// Combinations known to be unpublished on Docker Hub. Kept as a denylist so
    /// the matrix stays permissive: only genuinely-missing tags are disabled.
    /// (PHP 8.4 images only exist for WP 6.7+; older WP lines cap at PHP 8.3.)
    private static let knownInvalid: Set<String> = [
        "6.6-php8.4",
    ]

    /// Build the official image tag for a WP + PHP pair.
    ///
    /// `latest` WordPress with the newest PHP is just `wordpress:latest`; every
    /// other pairing uses the explicit `<wp>-php<php>-apache` form.
    public static func imageTag(wordpress: String, php: String) -> String {
        if wordpress == "latest" && php == defaultPHP {
            return "wordpress:latest"
        }
        if wordpress == "latest" {
            return "wordpress:php\(php)-apache"
        }
        return "wordpress:\(wordpress)-php\(php)-apache"
    }

    /// Whether a WP×PHP pairing is expected to resolve to a published tag.
    public static func isKnownValid(wordpress: String, php: String) -> Bool {
        !knownInvalid.contains("\(wordpress)-php\(php)")
    }

    /// Best-effort PHP version extracted from an arbitrary image tag
    /// (e.g. `wordpress:6.8-php8.2-apache` → `8.2`), else nil.
    public static func php(fromTag tag: String) -> String? {
        guard let range = tag.range(of: #"php\d+\.\d+"#, options: .regularExpression) else { return nil }
        return String(tag[range].dropFirst(3))
    }

    /// Best-effort WordPress version extracted from an image tag
    /// (`wordpress:6.8-php8.2-apache` → `6.8`, `wordpress:latest` → `latest`).
    public static func wordpress(fromTag tag: String) -> String? {
        let ref = tag.hasPrefix("wordpress:") ? String(tag.dropFirst("wordpress:".count)) : tag
        if ref == "latest" || ref.hasPrefix("php") { return "latest" }
        if let dash = ref.firstIndex(of: "-") { return String(ref[..<dash]) }
        return ref.isEmpty ? nil : ref
    }
}
