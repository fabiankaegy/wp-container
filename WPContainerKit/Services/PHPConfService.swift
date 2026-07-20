import Foundation

/// Manages the per-instance PHP overrides folder (`php/`, alongside
/// `wordpress/`) that is bind-mounted into the wp container and picked up via
/// `PHP_INI_SCAN_DIR` (see `SiteRecipe.runWordPressArgs`).
///
/// The managed `wpc-defaults.ini` raises the stock image's 2 MB upload cap to
/// 50 MB for every site. `upload_max_filesize` is PHP_INI_PERDIR — it cannot be
/// set from WordPress code (no mu-plugin/wp-config route), only from an ini
/// scanned at PHP startup, hence the mounted folder.
///
/// The file is marker-headed (same convention as `MailpitService`): while the
/// marker line is present the file is OURS and gets refreshed on every start
/// whenever the managed defaults change. Deleting the marker line hands the
/// file to the user for per-site tuning; extra `.ini` files dropped next to it
/// are scanned too.
public enum PHPConfService {
    /// Name of the managed ini inside an instance's `php/` folder.
    public static let managedIniName = "wpc-defaults.ini"

    /// Unique marker in the file header, used to detect that the file is ours.
    static let marker = "; WP Container: managed PHP defaults (delete this line to take ownership)"

    static let managedIniContents = """
    \(marker)
    ; Loaded on top of the image's stock ini set via PHP_INI_SCAN_DIR. While the
    ; marker line above is present, WP Container refreshes this file on every
    ; site start. Additional .ini files in this folder are loaded as well.

    ; WordPress caps media uploads at min(upload_max_filesize, post_max_size);
    ; the stock wordpress image leaves PHP's useless 2M default in place.
    ; post_max_size is higher than upload_max_filesize so a full 50M file plus
    ; multipart overhead still fits in one request body.
    upload_max_filesize = 50M
    post_max_size = 64M
    """

    public static func managedIniURL(phpConfFolder: URL) -> URL {
        phpConfFolder.appendingPathComponent(managedIniName)
    }

    /// Ensure the folder exists (it is bind-mounted, so it MUST exist before
    /// `container run`) and the managed ini is present and current. A
    /// user-owned file (marker removed) is left untouched. Idempotent.
    public static func ensure(for inst: any RunnableInstance) throws {
        let folder = inst.phpConfFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = managedIniURL(phpConfFolder: folder)
        if let existing = try? String(contentsOf: url, encoding: .utf8) {
            // Missing marker ⇒ the user took ownership; identical ⇒ up to date.
            guard existing.contains(marker), existing != managedIniContents else { return }
        }
        try managedIniContents.write(to: url, atomically: true, encoding: .utf8)
    }
}
