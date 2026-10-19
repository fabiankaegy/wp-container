import Foundation

public enum WPEnvError: Error, Sendable, CustomStringConvertible {
    case configNotFound(String)
    case invalidJSON(file: String, detail: String)

    public var description: String {
        switch self {
        case .configNotFound(let dir): return "No .wp-env.json found in \(dir)."
        case .invalidJSON(let file, let detail): return "\(file) is not valid JSON: \(detail)"
        }
    }
}

/// A source string from `.wp-env.json`'s `core`, `plugins`, `themes`, or
/// `mappings`.
public enum WPEnvSource: Sendable, Equatable {
    /// A local folder, resolved against the project directory.
    case local(URL)
    /// `<owner>/<repo>[/<path>][#<ref>]`.
    case github(owner: String, repo: String, path: String?, ref: String?)
    /// `http[s]://…/<file>.zip`.
    case zip(URL)
    /// SSH repositories and anything else wp-container can't fetch.
    case unsupported(String)

    public static func parse(_ raw: String, relativeTo project: URL) -> WPEnvSource {
        if raw.hasPrefix(".") || raw.hasPrefix("/") {
            let url = raw.hasPrefix("/") ? URL(fileURLWithPath: raw) : project.appendingPathComponent(raw)
            return .local(url.standardizedFileURL)
        }
        if raw.hasPrefix("~") {
            return .local(URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).standardizedFileURL)
        }
        if let url = URL(string: raw), let scheme = url.scheme?.lowercased() {
            if (scheme == "http" || scheme == "https"), url.path.lowercased().hasSuffix(".zip") { return .zip(url) }
            return .unsupported(raw)
        }
        if let match = raw.wholeMatch(of: /([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+)(\/[^#]+)?(?:#(.+))?/) {
            let path = match.3.map { String($0.dropFirst()) }
            return .github(owner: String(match.1), repo: String(match.2), path: path, ref: match.4.map(String.init))
        }
        return .unsupported(raw)
    }

    /// The archive URL a `wp plugin|theme install` can fetch, or nil when the
    /// source can't be installed from a single archive (a repo subfolder).
    public var archiveURL: URL? {
        switch self {
        case .zip(let url): return url
        case .github(let owner, let repo, nil, let ref):
            return URL(string: "https://codeload.github.com/\(owner)/\(repo)/zip/\(ref ?? "HEAD")")
        default: return nil
        }
    }
}

/// A `config` value from `.wp-env.json`.
public enum WPEnvValue: Sendable, Equatable {
    case bool(Bool)
    case number(String)
    case string(String)
    case null
    case unsupported

    init(json: Any) {
        switch json {
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
            self = .bool(number.boolValue)
        case let number as NSNumber: self = .number(number.stringValue)
        case let text as String: self = .string(text)
        case is NSNull: self = .null
        default: self = .unsupported
        }
    }
}

/// A project's resolved `.wp-env.json` for the development environment:
/// `.wp-env.override.json` applied on top (its `config` and `mappings` merge,
/// every other key replaces), then `env.development` the same way.
public struct WPEnvProject: Sendable {
    public let directory: URL
    public var core: String?
    public var phpVersion: String?
    public var multisite = false
    public var plugins: [String] = []
    public var themes: [String] = []
    /// WordPress-relative path → source, in sorted order.
    public var mappings: [(path: String, source: String)] = []
    /// Constant name → value, in sorted order.
    public var config: [(name: String, value: WPEnvValue)] = []
    /// Keys present but not applied (ports, lifecycle scripts).
    public var ignoredKeys: [String] = []

    public static let fileName = ".wp-env.json"
    public static let overrideFileName = ".wp-env.override.json"
    static let mergedKeys: Set<String> = ["config", "mappings"]
    static let ignorableKeys = ["port", "testsPort", "mysqlPort", "phpmyadminPort", "lifecycleScripts", "testsEnvironment"]

    public static func load(directory: URL) throws -> WPEnvProject {
        let base = try read(directory.appendingPathComponent(fileName), required: true) ?? [:]
        let override = try read(directory.appendingPathComponent(overrideFileName), required: false) ?? [:]
        return resolve(base: base, override: override, directory: directory)
    }

    /// `base` with `override` applied, then `env.development`. Pure, for tests.
    static func resolve(base: [String: Any], override: [String: Any], directory: URL) -> WPEnvProject {
        var merged = merge(base, override)
        if let development = (merged["env"] as? [String: Any])?["development"] as? [String: Any] {
            merged = merge(merged, development)
        }
        var project = WPEnvProject(directory: directory)
        project.core = merged["core"] as? String
        project.phpVersion = merged["phpVersion"] as? String
        project.multisite = merged["multisite"] as? Bool ?? false
        project.plugins = merged["plugins"] as? [String] ?? []
        project.themes = merged["themes"] as? [String] ?? []
        project.mappings = ((merged["mappings"] as? [String: String]) ?? [:]).sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        project.config = ((merged["config"] as? [String: Any]) ?? [:]).sorted { $0.key < $1.key }
            .map { ($0.key, WPEnvValue(json: $0.value)) }
        project.ignoredKeys = ignorableKeys.filter { merged[$0] != nil }
        return project
    }

    private static func merge(_ base: [String: Any], _ top: [String: Any]) -> [String: Any] {
        var result = base
        for (key, value) in top {
            if mergedKeys.contains(key), let lower = base[key] as? [String: Any], let upper = value as? [String: Any] {
                result[key] = lower.merging(upper) { _, new in new }
            } else {
                result[key] = value
            }
        }
        return result
    }

    private static func read(_ url: URL, required: Bool) throws -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else {
            if required { throw WPEnvError.configNotFound(url.deletingLastPathComponent().path) }
            return nil
        }
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw WPEnvError.invalidJSON(file: url.lastPathComponent, detail: "the top level is not an object")
            }
            return object
        } catch let error as WPEnvError {
            throw error
        } catch {
            throw WPEnvError.invalidJSON(file: url.lastPathComponent, detail: error.localizedDescription)
        }
    }
}

/// What applying a `WPEnvProject` to a site does, worked out up front.
public struct WPEnvPlan: Sendable {
    /// `major.minor` WordPress version for the image, or nil for latest.
    public var wordpressVersion: String?
    public var phpVersion: String?
    public var multisite = false
    /// Local plugins, themes, and mappings, bind-mounted into the site.
    public var mounts: [Mount] = []
    /// Mounted plugin folder names to activate.
    public var activatePlugins: [String] = []
    /// Archives to `wp plugin install --activate`.
    public var installPlugins: [URL] = []
    /// Archives to `wp theme install`.
    public var installThemes: [URL] = []
    /// `wp config set` arguments: name, value, and whether `--raw`.
    public var constants: [(name: String, value: String, raw: Bool)] = []
    public var warnings: [String] = []

    public init(project: WPEnvProject) {
        let root = SiteRecipe.wordpressContainerPath
        let fm = FileManager.default
        func exists(_ url: URL, _ label: String) -> Bool {
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue { return true }
            warnings.append("\(label) folder \(url.path) doesn't exist; skipped.")
            return false
        }
        if let core = project.core {
            switch WPEnvSource.parse(core, relativeTo: project.directory) {
            case .github(let owner, let repo, nil, let ref?) where owner == "WordPress" && repo == "WordPress":
                wordpressVersion = Self.majorMinor(ref)
            case .zip(let url):
                wordpressVersion = url.lastPathComponent.firstMatch(of: /wordpress-(\d+\.\d+(?:\.\d+)?)/).map { Self.majorMinor(String($0.1)) } ?? nil
            default:
                wordpressVersion = nil
            }
            if wordpressVersion == nil {
                warnings.append("core \"\(core)\" isn't a WordPress version wp-container can map to an image; using the latest WordPress.")
            }
        }
        phpVersion = project.phpVersion
        multisite = project.multisite

        for raw in project.plugins {
            switch WPEnvSource.parse(raw, relativeTo: project.directory) {
            case .local(let url):
                guard exists(url, "plugin") else { continue }
                let name = url.lastPathComponent
                mounts.append(Mount(hostPath: url.path, containerPath: "\(root)/wp-content/plugins/\(name)"))
                activatePlugins.append(name)
            case let source:
                if let archive = source.archiveURL { installPlugins.append(archive) }
                else { warnings.append("plugin \"\(raw)\" can't be installed from a single archive; install it yourself.") }
            }
        }
        for raw in project.themes {
            switch WPEnvSource.parse(raw, relativeTo: project.directory) {
            case .local(let url):
                guard exists(url, "theme") else { continue }
                mounts.append(Mount(hostPath: url.path, containerPath: "\(root)/wp-content/themes/\(url.lastPathComponent)"))
            case let source:
                if let archive = source.archiveURL { installThemes.append(archive) }
                else { warnings.append("theme \"\(raw)\" can't be installed from a single archive; install it yourself.") }
            }
        }
        for (path, raw) in project.mappings {
            let clean = path.split(separator: "/").filter { $0 != ".." && $0 != "." }.joined(separator: "/")
            guard case .local(let url) = WPEnvSource.parse(raw, relativeTo: project.directory), !clean.isEmpty else {
                warnings.append("mapping \"\(path)\" → \"\(raw)\" isn't a local folder; skipped.")
                continue
            }
            guard exists(url, "mapping") else { continue }
            mounts.append(Mount(hostPath: url.path, containerPath: "\(root)/\(clean)"))
        }
        for (name, value) in project.config {
            switch value {
            case .bool(let flag): constants.append((name, flag ? "true" : "false", true))
            case .number(let number): constants.append((name, number, true))
            case .string(let text): constants.append((name, text, false))
            case .null: warnings.append("config \(name) is null; left unset.")
            case .unsupported: warnings.append("config \(name) has a value wp-container can't write; left unset.")
            }
        }
        for key in project.ignoredKeys {
            switch key {
            case "lifecycleScripts": warnings.append("lifecycleScripts are ignored: wp-container doesn't run them.")
            case "testsEnvironment": warnings.append("testsEnvironment is ignored: `wp-container test` uses its own test schema.")
            default: warnings.append("\(key) is ignored: wp-container assigns ports itself.")
            }
        }
    }

    /// `6.5.2` → `6.5`; `trunk`, `master` → nil.
    static func majorMinor(_ version: String) -> String? {
        guard let match = version.firstMatch(of: /^(\d+)\.(\d+)/) else { return nil }
        return "\(match.1).\(match.2)"
    }
}

/// Applies the parts of a `WPEnvPlan` that need a running site: installs and
/// activates plugins, installs themes, and sets constants. Mounts, versions,
/// and multisite are applied when the site is created.
public enum WPEnvApplier {
    /// What a step changed, or why it failed.
    public struct Report: Sendable {
        public var done: [String] = []
        public var failures: [String] = []
    }

    public static func apply(_ plan: WPEnvPlan, to inst: any RunnableInstance, dbHost: String,
                             cli: ContainerCLI) async -> Report {
        var report = Report()
        let sidecarEnvironment = await SidecarAddons.environment(for: inst, cli: cli)

        func wp(_ args: [String], done: String) async {
            let result = try? await cli.runCapturing(SiteRecipe.wpProxyArgs(inst, dbHost: dbHost, wpArgs: args,
                                                                            sidecarEnvironment: sidecarEnvironment))
            if let result, result.succeeded {
                report.done.append(done)
            } else {
                let detail = result.map { ($0.stderr.isEmpty ? $0.stdout : $0.stderr).trimmingCharacters(in: .whitespacesAndNewlines) }
                    ?? "wp-cli did not run"
                report.failures.append("\(done) failed: \(detail.split(whereSeparator: \.isNewline).last.map(String.init) ?? detail)")
            }
        }

        for url in plan.installPlugins {
            await wp(["plugin", "install", url.absoluteString, "--activate", "--force"], done: "Installed plugin \(url.absoluteString)")
        }
        for name in plan.activatePlugins {
            await wp(["plugin", "activate", name], done: "Activated plugin \(name)")
        }
        for url in plan.installThemes {
            await wp(["theme", "install", url.absoluteString, "--force"], done: "Installed theme \(url.absoluteString)")
        }
        for constant in plan.constants {
            var args = ["config", "set", constant.name, constant.value, "--type=constant"]
            if constant.raw { args.append("--raw") }
            await wp(args, done: "Set \(constant.name)")
        }
        return report
    }
}
