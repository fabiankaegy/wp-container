import Foundation

/// Single source of truth for the marketing version string, shared by the app
/// (Settings footer / About) and the `wp-container` CLI (`--version`).
///
/// Keep this in sync with `MARKETING_VERSION` in `project.yml`. The Makefile's
/// `verify-version` target checks that they match; `make release` runs it.
public enum WPContainerVersion {
    /// Human-facing marketing version, e.g. `0.1.0`.
    public static let marketing = "0.2.0"

    /// Convenience alias used where a bare version string is expected.
    public static var current: String { marketing }
}
