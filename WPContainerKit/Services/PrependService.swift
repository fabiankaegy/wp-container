import Foundation

/// Owns the single master `auto_prepend_file` loader that lets WP Container ship
/// runtime PHP handlers WITHOUT ever writing into a user's project tree (issue
/// #13). An earlier design dropped handlers into `wp-content/mu-plugins/`, which
/// can sit inside a tracked git repo and get committed by accident.
///
/// Everything lives in the per-instance `php/` folder (`inst.phpConfFolder`, a
/// sibling of `wordpress/`, already bind-mounted at `/usr/local/etc/php/wpc-conf.d`
/// and activated via `PHP_INI_SCAN_DIR`):
///
///   php/wpc-prepend.php   — the ONLY auto_prepend file. Registers one
///                           pre-initialized hook (`muplugins_loaded`, prio 0)
///                           that includes every `prepend.d/*.php`.
///   php/wpc-prepend.ini   — the ONLY ini that sets `auto_prepend_file` (two
///                           inis setting it would clobber each other — hence a
///                           single shared master that fans out to prepend.d).
///   php/prepend.d/*.php   — individual managed handlers (magic login, Mailpit,
///                           remote media), each a normal `add_action`/`add_filter`
///                           file because by `muplugins_loaded` WordPress is
///                           bootstrapping normally.
///   php/prepend.d/early/*.php — handlers included at prepend time, before
///                           wp-config.php, for hooks that fire before
///                           `muplugins_loaded` (Redis, which must be wired
///                           before the object-cache drop-in loads). They register
///                           pre-initialized hooks only.
///
/// The pre-initialized-hook trick is WordPress-supported: a raw array left in
/// `$GLOBALS['wp_filter']` before `wp-includes/plugin.php` loads is converted by
/// `WP_Hook::build_preinitialized_hooks()` (the same mechanism advanced-cache
/// drop-ins and APM agents use to hook early).
public enum PrependService {
    static let masterFileName = "wpc-prepend.php"
    static let masterIniName = "wpc-prepend.ini"
    static let prependDirName = "prepend.d"
    /// Subfolder of `prepend.d` whose handlers load at prepend time.
    static let earlyDirName = "early"

    static let masterMarker = "WP Container: master auto_prepend loader (managed — do not edit)"
    static let iniMarker = "; WP Container: auto_prepend loader (managed — do not edit)"

    /// The first-generation single-handler ini (login-only prepend design),
    /// cleaned up here because it also set `auto_prepend_file` and would clobber
    /// the master.
    static let legacyLoginIniName = "wpc-login.ini"
    static let legacyLoginIniMarker = "; WP Container: Magic Login (managed — do not edit)"

    static let masterContainerPath = "\(SiteRecipe.phpConfContainerPath)/\(masterFileName)"

    static let masterContents = """
    <?php
    /*
     * \(masterMarker)
     * WP Container master auto_prepend loader (issue #13). Includes the handlers
     * in ./prepend.d/early/*.php right away, and registers ONE pre-initialized
     * hook (muplugins_loaded, priority 0) that includes every managed runtime
     * handler in ./prepend.d/*.php. Those handlers live in the
     * site's private php/ folder — OUTSIDE the project tree — so nothing WP
     * Container manages at runtime can be committed to a user's repo by accident.
     * Do not edit.
     */

    if ( ! function_exists( 'wpc_prepend_load_handlers' ) ) {
        function wpc_prepend_load_handlers() {
            foreach ( glob( __DIR__ . '/\(prependDirName)/*.php' ) ?: array() as $wpc_handler ) {
                include_once $wpc_handler;
            }
        }
    }

    if ( ! function_exists( 'wpc_prepend_load_early_handlers' ) ) {
        function wpc_prepend_load_early_handlers() {
            foreach ( glob( __DIR__ . '/\(prependDirName)/\(earlyDirName)/*.php' ) ?: array() as $wpc_handler ) {
                include_once $wpc_handler;
            }
        }
    }
    wpc_prepend_load_early_handlers();

    // Pre-initialized hook: WP_Hook::build_preinitialized_hooks() (wp-includes/
    // plugin.php) turns this raw array into a real hook when WordPress boots.
    $GLOBALS['wp_filter']['muplugins_loaded'][0]['wpc_prepend'] = array(
        'function'      => 'wpc_prepend_load_handlers',
        'accepted_args' => 1,
    );
    """

    static let iniContents = """
    \(iniMarker)
    ; Managed by WP Container — the SINGLE auto_prepend_file entry (issue #13).
    ; All runtime handlers load via php/\(prependDirName), so only ONE ini may set
    ; auto_prepend_file (multiple would clobber each other). Refreshed on every
    ; site start. Do not edit.
    auto_prepend_file = "\(masterContainerPath)"
    """

    // MARK: - Paths

    /// The `php/` folder derived from a `wordpress/` folder (for the enable/disable
    /// call sites that only carry a `wordpressFolder`).
    public static func phpFolder(forWordpress wordpressFolder: URL) -> URL {
        wordpressFolder.deletingLastPathComponent().appendingPathComponent("php", isDirectory: true)
    }
    public static func prependDirURL(phpConfFolder: URL) -> URL {
        phpConfFolder.appendingPathComponent(prependDirName, isDirectory: true)
    }
    public static func handlerURL(phpConfFolder: URL, name: String) -> URL {
        prependDirURL(phpConfFolder: phpConfFolder).appendingPathComponent(name)
    }

    // MARK: - Master ensure

    /// Ensure the master loader + its ini exist and are current, and that
    /// `prepend.d/` exists. Also removes the legacy single-handler `wpc-login.ini`
    /// (it competes for `auto_prepend_file`). Idempotent.
    public static func ensure(for inst: any RunnableInstance) throws {
        let folder = inst.phpConfFolder
        try FileManager.default.createDirectory(at: prependDirURL(phpConfFolder: folder),
                                                withIntermediateDirectories: true)
        try writeIfDiffers(masterContents, to: folder.appendingPathComponent(masterFileName))
        try writeIfDiffers(iniContents, to: folder.appendingPathComponent(masterIniName))
        removeIfMarked(folder.appendingPathComponent(legacyLoginIniName), marker: legacyLoginIniMarker)
    }

    /// Whether the master loader + ini are both present (i.e. the running
    /// container, if any, was started with the loader active).
    public static func isEnsured(for inst: any RunnableInstance) -> Bool {
        let folder = inst.phpConfFolder
        return FileManager.default.fileExists(atPath: folder.appendingPathComponent(masterFileName).path)
            && FileManager.default.fileExists(atPath: folder.appendingPathComponent(masterIniName).path)
    }

    // MARK: - prepend.d handler helpers (used by the individual services)

    /// Write a handler; `name` may include a subfolder (`early/wpc-redis.php`).
    public static func writeHandler(phpConfFolder: URL, name: String, contents: String) throws {
        let url = handlerURL(phpConfFolder: phpConfFolder, name: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeIfDiffers(contents, to: url)
    }

    /// Remove a handler, but only when it carries `marker` (never a user file).
    public static func removeHandler(phpConfFolder: URL, name: String, marker: String) {
        removeIfMarked(handlerURL(phpConfFolder: phpConfFolder, name: name), marker: marker)
    }

    public static func isHandlerPresent(phpConfFolder: URL, name: String, marker: String) -> Bool {
        let url = handlerURL(phpConfFolder: phpConfFolder, name: name)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return text.contains(marker)
    }

    // MARK: - Shared file ops

    static func writeIfDiffers(_ contents: String, to url: URL) throws {
        if let existing = try? String(contentsOf: url, encoding: .utf8), existing == contents { return }
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Delete `url` only when present AND it contains `marker` (ours). Idempotent;
    /// a missing file or a user's own same-named file is left untouched.
    static func removeIfMarked(_ url: URL, marker: String) {
        guard let text = try? String(contentsOf: url, encoding: .utf8), text.contains(marker) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
