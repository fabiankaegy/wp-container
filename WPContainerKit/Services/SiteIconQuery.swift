import Foundation

/// Finds a running site's WordPress Site Icon — the attachment stored in the
/// `site_icon` option — by asking its database directly. One read-only query
/// in the already-running MariaDB container (~0.3 s), instead of a one-shot
/// wp-cli container per site. `FaviconLocator`'s filename heuristics remain
/// the fallback for stopped sites and sites without a Site Icon.
public enum SiteIconQuery {
    /// The query didn't run: the database isn't accepting connections yet, or
    /// the lookup was cancelled. Worth retrying, unlike a site without an icon.
    public struct Unavailable: Error {}

    /// The Site Icon's path relative to `wp-content/uploads`, or nil when the
    /// site has none or the path looks unsafe. Throws `Unavailable` when the
    /// database couldn't be asked.
    public static func attachmentPath(for inst: any RunnableInstance, cli: ContainerCLI) async throws -> String? {
        let config = (try? String(contentsOf: WPConfigService.configURL(for: inst.wordpressFolder), encoding: .utf8)) ?? ""
        let args = ["exec", inst.dbContainerName, "mariadb",
                    "-u\(SiteRecipe.dbUser)", "-p\(SiteRecipe.dbPassword)", inst.databaseName,
                    "-N", "-B", "-e", sql(prefix: WPConfigService.parseTablePrefix(config) ?? "wp_")]
        guard let result = try? await cli.runCapturing(args), result.succeeded, !Task.isCancelled else { throw Unavailable() }
        return uploadsRelativePath(result.stdout)
    }

    /// The Site Icon's file on disk, or nil when the site has none or the file
    /// isn't local (e.g. media served from production); callers can then
    /// fetch `attachmentPath` through the site itself.
    public static func localFile(for inst: any RunnableInstance, relativePath: String) -> URL? {
        let file = inst.wordpressFolder.appendingPathComponent("wp-content/uploads/\(relativePath)")
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    /// The `_wp_attached_file` (a path relative to uploads) of the attachment
    /// named by the `site_icon` option. `prefix` is validated by
    /// `WPConfigService.parseTablePrefix` to `[A-Za-z0-9_]`, so it is safe to inline.
    public static func sql(prefix: String) -> String {
        """
        SELECT pm.meta_value FROM \(prefix)options o \
        JOIN \(prefix)postmeta pm ON pm.post_id = o.option_value AND pm.meta_key = '_wp_attached_file' \
        WHERE o.option_name = 'site_icon' LIMIT 1
        """
    }

    /// The uploads-relative path from the query output, rejecting anything
    /// that could point outside `wp-content/uploads`.
    public static func uploadsRelativePath(_ output: String) -> String? {
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\n"),
              !path.split(separator: "/").contains(where: { $0 == ".." }) else { return nil }
        return path
    }
}
