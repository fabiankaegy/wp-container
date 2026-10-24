import Foundation

/// The web server in front of PHP in a site's wp container.
///
/// `apache` runs the official `wordpress:<tag>` image (Apache + mod_php).
/// `nginx` runs a derived image built on the matching `-fpm` tag, with nginx
/// and PHP-FPM in the same container (`NginxImageService`). Either way the
/// instance keeps its Apache-shaped `imageTag`, which records the WordPress
/// and PHP versions; `WordPressImageCatalog.fpmTag(for:)` maps it to the FPM
/// base for nginx.
public enum WebServer: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case apache
    case nginx

    public var id: String { rawValue }

    /// Human-readable label for pickers and CLI output.
    public var label: String {
        switch self {
        case .apache: return "Apache"
        case .nginx:  return "nginx"
        }
    }

    /// Whether this web server can run a site on `imageTag`. nginx needs a
    /// tag with an official PHP-FPM counterpart.
    public func supports(imageTag: String) -> Bool {
        switch self {
        case .apache: return true
        case .nginx:  return WordPressImageCatalog.fpmTag(for: imageTag) != nil
        }
    }
}
