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
        /// The MySQL schema to connect to (`WORDPRESS_DB_NAME`). Not always
        /// `wordpress`: a shared-database worktree env lives in its own `wpc_*`
        /// schema on the parent's server (issue #17), and the router MUST pass
        /// this through or `wp` would operate on the parent's data.
        public let dbName: String
        /// Sidecar container names whose addresses the router passes to wp-cli
        /// (`WPC_MAILPIT_HOST`, `EP_HOST`) when they are running.
        public let mailContainer: String
        public let esContainer: String
        /// The instance's `php/` overrides folder, mounted so wp-cli loads the
        /// managed runtime handlers.
        public let phpConfPath: String
    }

    /// The most-specific match for `path` (longest `wordpress/` prefix wins), or
    /// nil when the path is not inside any known site/env.
    public static func resolve(path: String, in envelope: StoreEnvelope) -> Match? {
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        var best: Match?
        var bestLen = -1

        func consider(_ inst: any RunnableInstance, kind: String, slug: String) {
            let wpPath = inst.wordpressFolder.resolvingSymlinksInPath().path
            let sub: String?
            if target == wpPath { sub = "" }
            else if target.hasPrefix(wpPath + "/") { sub = String(target.dropFirst(wpPath.count + 1)) }
            else { sub = nil }
            if let sub, wpPath.count > bestLen {
                bestLen = wpPath.count
                best = Match(matched: true, kind: kind, slug: slug,
                             wordpressPath: wpPath, dbContainer: inst.dbContainerName,
                             port: inst.port, subpath: sub,
                             cliImage: WordPressImageCatalog.cliImage(for: inst.imageTag),
                             dbName: inst.databaseName,
                             mailContainer: inst.mailContainerName,
                             esContainer: inst.esContainerName,
                             phpConfPath: inst.phpConfFolder.path)
            }
        }

        for s in envelope.sites {
            consider(s, kind: "site", slug: s.slug)
        }
        for e in envelope.envs {
            consider(e, kind: "env", slug: e.envSlug)
        }
        return best
    }
}
