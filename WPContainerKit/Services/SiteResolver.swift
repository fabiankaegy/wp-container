import Foundation

/// Resolves an absolute filesystem path to the WP Container site or worktree-env
/// whose `wordpress/` tree contains it (PLAN.md §2e follow-up). Powers the
/// `wp-container resolve-site` subcommand and the global `wp` router.
public enum SiteResolver {
    public struct Match: Sendable, Codable {
        public let matched: Bool
        public let kind: String        // "site" | "env"
        public let slug: String
        public let wordpressPath: String
        public let dbContainer: String
        public let port: Int
        /// Path of the query relative to `wordpressPath` ("" when it IS the root).
        public let subpath: String
        /// PHP-matched one-shot wp-cli image for the resolved site/env, so the
        /// global `wp` router runs wp-cli on the correct PHP version.
        public let cliImage: String
    }

    /// The most-specific match for `path` (longest `wordpress/` prefix wins), or
    /// nil when the path is not inside any known site/env.
    public static func resolve(path: String, in envelope: StoreEnvelope) -> Match? {
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        var best: Match?
        var bestLen = -1

        func consider(_ wpFolder: URL, kind: String, slug: String, db: String, port: Int, imageTag: String) {
            let wpPath = wpFolder.resolvingSymlinksInPath().path
            let sub: String?
            if target == wpPath { sub = "" }
            else if target.hasPrefix(wpPath + "/") { sub = String(target.dropFirst(wpPath.count + 1)) }
            else { sub = nil }
            if let sub, wpPath.count > bestLen {
                bestLen = wpPath.count
                best = Match(matched: true, kind: kind, slug: slug,
                             wordpressPath: wpPath, dbContainer: db, port: port, subpath: sub,
                             cliImage: WordPressImageCatalog.cliImage(for: imageTag))
            }
        }

        for s in envelope.sites {
            consider(s.wordpressFolder, kind: "site", slug: s.slug, db: s.dbContainerName, port: s.port, imageTag: s.imageTag)
        }
        for e in envelope.envs {
            consider(e.wordpressFolder, kind: "env", slug: e.envSlug, db: e.dbContainerName, port: e.port, imageTag: e.imageTag)
        }
        return best
    }
}
