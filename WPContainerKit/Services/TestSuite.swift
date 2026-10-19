import Foundation

public enum TestSuiteError: Error, Sendable, CustomStringConvertible {
    case unknownWordPressVersion(path: String)
    case libraryUnavailable(version: String, detail: String)
    case phpunitMissing(path: String, slug: String)

    public var description: String {
        switch self {
        case .unknownWordPressVersion(let path):
            return "Could not read the WordPress version from \(path)."
        case .libraryUnavailable(let version, let detail):
            return "Could not download the WordPress test library for \(version) (wp-phpunit): \(detail)"
        case .phpunitMissing(let path, let slug):
            return "vendor/bin/phpunit not found in \(path). Install the project's dev dependencies first: "
                + "wp-container run \(slug) --image composer:2 -- composer install"
        }
    }
}

/// Runs a project's PHPUnit integration tests (`WP_UnitTestCase`) against an
/// instance, the way `wp-env run tests-cli … phpunit` does:
///
/// - a dedicated test schema on the instance's database server, so the suite's
///   table wipes never touch the site's data;
/// - the WordPress test library for the instance's WordPress version, from the
///   matching `wp-phpunit/wp-phpunit` tag, downloaded once into the instance's
///   private `phpunit/` folder (beside `wordpress/`, outside the project);
/// - a generated `wp-tests-config.php` that reads its database from env vars.
public enum TestSuite {
    /// Where the test library is mounted in the test container.
    public static let libraryContainerPath = "/wpc-tests/wp-phpunit"
    public static let configFileName = "wp-tests-config.php"
    /// Env var carrying the test schema into `wp-tests-config.php`.
    static let databaseEnvKey = "WPC_TESTS_DB_NAME"
    /// Test schemas sit outside the `wpc_` prefix of managed env schemas, so env
    /// schema cleanup can never mistake one for the other.
    public static let schemaPrefix = "wpctests_"

    static let configMarker = "WP Container: WordPress test suite config (managed — do not edit)"

    // MARK: - Names and paths

    /// `wpctests_` + the container slug, sanitized and capped like env schemas.
    public static func databaseName(for inst: any RunnableInstance) -> String {
        let sanitized = String(inst.containerSlug.map { ch in
            (ch.isASCII && (ch.isLetter || ch.isNumber)) ? ch : Character("_")
        })
        let full = schemaPrefix + sanitized
        guard full.count > WorktreeEnv.maxSchemaNameLength else { return full }
        let hash = WorktreeEnv.shortHash(inst.containerSlug)
        return String(full.prefix(WorktreeEnv.maxSchemaNameLength - hash.count - 1)) + "_" + hash
    }

    /// The instance's private folder for test libraries, beside `wordpress/`.
    public static func phpunitFolder(for inst: any RunnableInstance) -> URL {
        inst.wordpressFolder.deletingLastPathComponent().appendingPathComponent("phpunit", isDirectory: true)
    }

    public static func libraryFolder(for inst: any RunnableInstance, version: String) -> URL {
        phpunitFolder(for: inst).appendingPathComponent("wp-phpunit-\(version)", isDirectory: true)
    }

    /// `$wp_version` from `wp-includes/version.php`.
    public static func wordPressVersion(wordpressFolder: URL) -> String? {
        let url = wordpressFolder.appendingPathComponent("wp-includes/version.php")
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let match = text.firstMatch(of: /\$wp_version\s*=\s*'([^']+)'/) else { return nil }
        return String(match.1)
    }

    // MARK: - Config

    /// `wp-tests-config.php`: ABSPATH is the container's WordPress, and the
    /// database comes from env vars set by `SiteRecipe.runTestsArgs`. It refuses
    /// to run without a test schema rather than fall back to the site's.
    static let configContents = """
    <?php
    /*
     * \(configMarker)
     * WordPress test suite configuration. The database comes from the test
     * container's environment; the schema is a dedicated test schema.
     */
    $wpc_tests_db = getenv( '\(databaseEnvKey)' );
    if ( empty( $wpc_tests_db ) ) {
        fwrite( STDERR, "\(databaseEnvKey) is not set; run the tests with `wp-container test`.\\n" );
        exit( 1 );
    }
    define( 'ABSPATH', '\(SiteRecipe.wordpressContainerPath)/' );
    define( 'WP_DEFAULT_THEME', 'default' );
    define( 'WP_DEBUG', true );
    define( 'DB_NAME', $wpc_tests_db );
    define( 'DB_USER', getenv( 'WORDPRESS_DB_USER' ) );
    define( 'DB_PASSWORD', getenv( 'WORDPRESS_DB_PASSWORD' ) );
    define( 'DB_HOST', getenv( 'WORDPRESS_DB_HOST' ) );
    define( 'DB_CHARSET', 'utf8' );
    define( 'DB_COLLATE', '' );
    $table_prefix = 'wptests_';
    define( 'WP_TESTS_DOMAIN', 'example.org' );
    define( 'WP_TESTS_EMAIL', 'admin@example.org' );
    define( 'WP_TESTS_TITLE', 'Test Blog' );
    define( 'WP_PHP_BINARY', 'php' );
    define( 'WPLANG', '' );
    unset( $wpc_tests_db );
    """

    // MARK: - Library

    /// The library for `version`, downloading and extracting it on first use.
    /// The config is rewritten on every call, so it stays current.
    public static func ensureLibrary(for inst: any RunnableInstance, version: String) async throws -> URL {
        let library = libraryFolder(for: inst, version: version)
        if !FileManager.default.fileExists(atPath: library.appendingPathComponent("includes/bootstrap.php").path) {
            try await download(version: version, into: phpunitFolder(for: inst))
        }
        try PrependService.writeIfDiffers(configContents, to: library.appendingPathComponent(configFileName))
        return library
    }

    /// Fetch the `wp-phpunit` tag archive and extract it as `wp-phpunit-<version>/`
    /// (the archive's own top-level folder name), via a staging folder so a
    /// failed download never leaves a partial library behind.
    private static func download(version: String, into folder: URL) async throws {
        guard let url = URL(string: "https://codeload.github.com/wp-phpunit/wp-phpunit/tar.gz/refs/tags/\(version)") else {
            throw TestSuiteError.libraryUnavailable(version: version, detail: "invalid version")
        }
        let (archive, response) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: archive) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw TestSuiteError.libraryUnavailable(version: version, detail: "HTTP \(status) for tag \(version)")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let staging = folder.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let result = try await ProcessRunner.run(executable: "/usr/bin/tar", args: ["-xzf", archive.path, "-C", staging.path])
        guard result.succeeded else {
            throw TestSuiteError.libraryUnavailable(version: version, detail: result.stderr)
        }
        let extracted = staging.appendingPathComponent("wp-phpunit-\(version)", isDirectory: true)
        let target = folder.appendingPathComponent("wp-phpunit-\(version)", isDirectory: true)
        try? fm.removeItem(at: target)
        try fm.moveItem(at: extracted, to: target)
    }

    // MARK: - Preparation

    /// Checks the project at container path `workdir` has PHPUnit installed and
    /// returns the container path of its PHPUnit Polyfills, if present. A
    /// workdir outside the instance's mounts is left for PHPUnit to report.
    public static func checkProject(workdir: String, in inst: any RunnableInstance, slug: String) throws -> String? {
        guard let project = SiteRecipe.hostPath(forContainerPath: workdir, in: inst) else { return nil }
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: project.appendingPathComponent("vendor/bin/phpunit").path) else {
            throw TestSuiteError.phpunitMissing(path: project.path, slug: slug)
        }
        let polyfills = "vendor/yoast/phpunit-polyfills"
        return fm.fileExists(atPath: project.appendingPathComponent(polyfills).path) ? "\(workdir)/\(polyfills)" : nil
    }

    /// Everything a run needs: the library for the instance's WordPress version
    /// and the test schema on its (running) database server.
    public static func prepare(_ inst: any RunnableInstance, cli: ContainerCLI) async throws -> (library: URL, schema: String) {
        guard let version = wordPressVersion(wordpressFolder: inst.wordpressFolder) else {
            throw TestSuiteError.unknownWordPressVersion(path: inst.wordpressFolder.path)
        }
        let library = try await ensureLibrary(for: inst, version: version)
        let schema = databaseName(for: inst)
        try await cli.run(SiteRecipe.createTestDatabaseArgs(inst, schema: schema))
        return (library, schema)
    }

    // MARK: - Results

    /// The counts from PHPUnit's closing summary line.
    public struct Summary: Sendable, Equatable, Codable {
        public var passed: Bool
        public var tests: Int
        public var assertions: Int
        public var failures = 0
        public var errors = 0
        public var skipped = 0
        public var incomplete = 0
        public var risky = 0
        public var warnings = 0
    }

    /// Parses `OK (12 tests, 34 assertions)` or
    /// `Tests: 5, Assertions: 9, Failures: 1, Skipped: 2.` from PHPUnit output.
    public static func summary(fromOutput output: String) -> Summary? {
        if let ok = output.firstMatch(of: /OK \((\d+) tests?, (\d+) assertions?\)/) {
            return Summary(passed: true, tests: Int(ok.1) ?? 0, assertions: Int(ok.2) ?? 0)
        }
        guard let line = output.split(separator: "\n").last(where: { $0.hasPrefix("Tests: ") }) else { return nil }
        var counts: [String: Int] = [:]
        for match in line.matches(of: /([A-Za-z]+): (\d+)/) {
            counts[String(match.1).lowercased()] = Int(match.2)
        }
        var summary = Summary(passed: false, tests: counts["tests"] ?? 0, assertions: counts["assertions"] ?? 0)
        summary.failures = counts["failures"] ?? 0
        summary.errors = counts["errors"] ?? 0
        summary.skipped = counts["skipped"] ?? 0
        summary.incomplete = counts["incomplete"] ?? 0
        summary.risky = counts["risky"] ?? 0
        summary.warnings = counts["warnings"] ?? 0
        summary.passed = summary.failures == 0 && summary.errors == 0
        return summary
    }
}
