import Foundation

/// How to start a tunnel provider process.
public struct ShareLaunchSpec: Sendable, Equatable {
    public let executable: URL
    public let arguments: [String]
    public let environment: [String: String]
    /// Public URL known before the process starts (a fixed hostname on cloudflared).
    public let fixedPublicURL: String?

    public init(
        executable: URL,
        arguments: [String],
        environment: [String: String] = [:],
        fixedPublicURL: String? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.fixedPublicURL = fixedPublicURL
    }
}

/// A tunnel that connects a public URL to a loopback share listener.
public protocol ShareProvider: Sendable {
    var name: String { get }
    /// Whether a URL without a fixed hostname changes on every start.
    var randomURLsAreTemporary: Bool { get }
    /// Throws when the provider is not installed or not ready to use.
    func preflight() async throws
    func launchSpec(upstream: URL, hostname: String?, instanceSlug: String, tunnelName: String?) throws -> ShareLaunchSpec
    /// The public URL announced by one line of provider output.
    func publicURL(fromOutputLine: String) -> String?
    /// Whether one line of provider output means the tunnel is serving traffic.
    func isReady(outputLine: String) -> Bool
}

public extension ShareProvider {
    func isReady(outputLine: String) -> Bool {
        publicURL(fromOutputLine: outputLine) != nil
    }
}

public enum ShareProviders {
    /// `/opt/homebrew/bin`, `/usr/local/bin`, then the directories in `PATH`.
    public static var defaultSearchPath: [URL] {
        var paths = ["/opt/homebrew/bin", "/usr/local/bin"]
        let envPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for part in envPath.split(separator: ":") where !paths.contains(String(part)) {
            paths.append(String(part))
        }
        return paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// The built-in provider for `ngrok` and `cloudflared`, otherwise the executable of that
    /// name in `customDirectory`.
    public static func resolve(
        _ name: String,
        searchPath: [URL] = ShareProviders.defaultSearchPath,
        customDirectory: URL = ProxyControl.directory.appendingPathComponent("share-providers")
    ) throws -> any ShareProvider {
        switch name {
        case "ngrok":
            return NgrokProvider(searchPath: searchPath)
        case "cloudflared":
            return CloudflaredProvider(searchPath: searchPath)
        default:
            let isPlainName = !name.isEmpty && !name.hasPrefix(".") && !name.contains("/")
            guard isPlainName else { throw ShareError.providerNotFound(name) }
            let url = customDirectory.appendingPathComponent(name)
            guard isExecutableFile(url) else { throw ShareError.providerNotFound(name) }
            return ScriptProvider(name: name, executable: url)
        }
    }

    static func findExecutable(_ name: String, in searchPath: [URL]) -> URL? {
        for directory in searchPath {
            let candidate = directory.appendingPathComponent(name)
            if isExecutableFile(candidate) { return candidate }
        }
        return nil
    }

    static func isExecutableFile(_ url: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath()
        let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey])
        return values?.isRegularFile == true && FileManager.default.isExecutableFile(atPath: resolved.path)
    }

    static func upstreamString(_ upstream: URL) -> String {
        var text = upstream.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    static func firstURL(in line: String, schemes: Set<String>, hostSuffix: String? = nil, allowPort: Bool = true) -> String? {
        for token in line.split(whereSeparator: { $0.isWhitespace || $0 == "|" }) {
            let text = String(token)
            if text.hasPrefix("https://") || text.hasPrefix("http://") {
                return validatedOrigin(text, schemes: schemes, hostSuffix: hostSuffix, allowPort: allowPort)
            }
        }
        return nil
    }

    /// The normalized origin (`scheme://host[:port]`) of a bare public URL, or nil when the text
    /// has control characters, credentials, a query, a fragment, a path, or no host.
    static func validatedOrigin(_ text: String, schemes: Set<String>, hostSuffix: String? = nil, allowPort: Bool = true) -> String? {
        let hasControl = text.unicodeScalars.contains { $0.properties.generalCategory == .control || $0.properties.isWhitespace }
        guard !hasControl, let parts = URLComponents(string: text) else { return nil }
        guard let scheme = parts.scheme?.lowercased(), schemes.contains(scheme) else { return nil }
        guard parts.host?.isEmpty == false, !text.contains("%"), text.allSatisfy(\.isASCII) else { return nil }
        // Foundation decodes punycode labels, so the host is read from the ASCII text itself.
        let authority = text.drop { $0 != ":" }.dropFirst(3).prefix { !"/?#".contains($0) }
        let hostAndPort = authority.hasPrefix("[")
            ? authority.prefix { $0 != "]" } + "]"
            : Substring(authority.prefix { $0 != ":" })
        let rawHost = hostAndPort.lowercased()
        let host = rawHost.hasPrefix("[") && rawHost.hasSuffix("]") ? String(rawHost.dropFirst().dropLast()) : rawHost
        let isIPv6 = host.contains(":")
        let ipv6Chars = Set("0123456789abcdef:.")
        let hostIsValid = isIPv6 ? host.allSatisfy { ipv6Chars.contains($0) } : isValidDNSHost(host)
        guard hostIsValid else { return nil }
        guard parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else { return nil }
        guard parts.path.isEmpty || parts.path == "/" else { return nil }
        if let hostSuffix, !host.hasSuffix(hostSuffix) { return nil }
        if parts.port != nil && !allowPort { return nil }
        let port = parts.port.map { ":\($0)" } ?? ""
        let shownHost = isIPv6 ? "[\(host)]" : host
        return "\(scheme)://\(shownHost)\(port)"
    }

    /// `https://<hostname>` for a bare DNS host name.
    static func fixedURL(forHostname hostname: String) throws -> String {
        guard isValidDNSHost(hostname) else { throw ShareError.invalidShareHostname(hostname) }
        return "https://\(hostname)"
    }

    /// ASCII DNS labels (letters, digits, hyphens; IDN only as `xn--` punycode) joined by dots.
    static func isValidDNSHost(_ hostname: String) -> Bool {
        let labels = hostname.split(separator: ".", omittingEmptySubsequences: false)
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        return !hostname.isEmpty && hostname.count <= 253 && labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.allSatisfy { allowed.contains($0) }
        }
    }

    static func validateTunnelName(_ name: String) throws {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let valid = !name.isEmpty && !name.hasPrefix("-") && name.allSatisfy { allowed.contains($0) }
        guard valid else { throw ShareError.invalidTunnelName(name) }
    }
}

/// ngrok v3, started with JSON logging on stdout.
public struct NgrokProvider: ShareProvider {
    public let name = "ngrok"
    public let randomURLsAreTemporary = false

    private let searchPath: [URL]
    private let environment: [String: String]
    private let configCandidates: [URL]

    public init(
        searchPath: [URL] = ShareProviders.defaultSearchPath,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        configCandidates: [URL]? = nil
    ) {
        self.searchPath = searchPath
        self.environment = environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.configCandidates = configCandidates ?? [
            home.appendingPathComponent("Library/Application Support/ngrok/ngrok.yml"),
            home.appendingPathComponent(".config/ngrok/ngrok.yml"),
            home.appendingPathComponent(".ngrok2/ngrok.yml"),
        ]
    }

    public func preflight() async throws {
        let binary = try executable()
        let token = environment["NGROK_AUTHTOKEN"] ?? ""
        guard token.isEmpty else { return }

        // `config check` prints the path of the configuration file in use.
        var candidates = configCandidates
        let result = try await ProcessRunner.run(executable: binary.path, args: ["config", "check"])
        let marker = " at "
        if result.succeeded, let range = result.stdout.range(of: marker) {
            let path = result.stdout[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty { candidates.insert(URL(fileURLWithPath: path), at: 0) }
        }
        guard candidates.contains(where: Self.hasAuthtoken) else { throw ShareError.ngrokNotAuthenticated }
    }

    public func launchSpec(upstream: URL, hostname: String?, instanceSlug: String, tunnelName: String?) throws -> ShareLaunchSpec {
        let binary = try executable()
        var arguments = ["http", ShareProviders.upstreamString(upstream), "--log", "stdout", "--log-format", "json"]
        if let hostname, !hostname.isEmpty {
            arguments += ["--url", try ShareProviders.fixedURL(forHostname: hostname)]
        }
        return ShareLaunchSpec(executable: binary, arguments: arguments)
    }

    public func publicURL(fromOutputLine line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let message = object["msg"] as? String
        guard message == "started tunnel", let url = object["url"] as? String else { return nil }
        return ShareProviders.validatedOrigin(url, schemes: ["https"])
    }

    private func executable() throws -> URL {
        guard let binary = ShareProviders.findExecutable("ngrok", in: searchPath) else {
            throw ShareError.providerMissingBinary(name: "ngrok", install: "brew install ngrok")
        }
        return binary
    }

    private static func hasAuthtoken(_ file: URL) -> Bool {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return false }
        return text.split(whereSeparator: \.isNewline).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("authtoken:") else { return false }
            let value = trimmed.dropFirst("authtoken:".count).trimmingCharacters(in: .whitespaces)
            return !value.isEmpty
        }
    }
}

/// cloudflared quick tunnels (random `trycloudflare.com` URL) and named tunnels (fixed hostname).
public struct CloudflaredProvider: ShareProvider {
    public let name = "cloudflared"
    public let randomURLsAreTemporary = true

    private let searchPath: [URL]

    public init(searchPath: [URL] = ShareProviders.defaultSearchPath) {
        self.searchPath = searchPath
    }

    public func preflight() async throws {
        _ = try executable()
    }

    public func launchSpec(upstream: URL, hostname: String?, instanceSlug: String, tunnelName: String?) throws -> ShareLaunchSpec {
        let binary = try executable()
        let origin = ShareProviders.upstreamString(upstream)
        guard let hostname, !hostname.isEmpty else {
            return ShareLaunchSpec(executable: binary, arguments: ["tunnel", "--url", origin])
        }
        let fixedURL = try ShareProviders.fixedURL(forHostname: hostname)
        guard let tunnelName, !tunnelName.isEmpty else { throw ShareError.cloudflaredTunnelNameRequired }
        try ShareProviders.validateTunnelName(tunnelName)
        return ShareLaunchSpec(
            executable: binary,
            arguments: ["tunnel", "run", "--url", origin, tunnelName],
            fixedPublicURL: fixedURL
        )
    }

    public func publicURL(fromOutputLine line: String) -> String? {
        guard let url = ShareProviders.firstURL(in: line, schemes: ["https"], hostSuffix: ".trycloudflare.com", allowPort: false)
        else { return nil }
        let host = URL(string: url)?.host
        guard host != "api.trycloudflare.com" else { return nil }
        return url
    }

    public func isReady(outputLine line: String) -> Bool {
        if line.contains("Registered tunnel connection") { return true }
        let url = publicURL(fromOutputLine: line)
        return url != nil
    }

    private func executable() throws -> URL {
        guard let binary = ShareProviders.findExecutable("cloudflared", in: searchPath) else {
            throw ShareError.providerMissingBinary(name: "cloudflared", install: "brew install cloudflared")
        }
        return binary
    }
}

/// A user-supplied executable that prints its public URL on stdout.
public struct ScriptProvider: ShareProvider {
    public let name: String
    public let randomURLsAreTemporary = true

    private let executable: URL

    public init(name: String, executable: URL) {
        self.name = name
        self.executable = executable
    }

    public func preflight() async throws {
        guard ShareProviders.isExecutableFile(executable) else { throw ShareError.providerNotFound(name) }
    }

    public func launchSpec(upstream: URL, hostname: String?, instanceSlug: String, tunnelName: String?) throws -> ShareLaunchSpec {
        ShareLaunchSpec(
            executable: executable,
            arguments: [],
            environment: [
                "WPC_SHARE_UPSTREAM": ShareProviders.upstreamString(upstream),
                "WPC_SHARE_HOSTNAME": hostname ?? "",
                "WPC_SHARE_INSTANCE": instanceSlug,
            ]
        )
    }

    public func publicURL(fromOutputLine line: String) -> String? {
        ShareProviders.firstURL(in: line, schemes: ["http", "https"])
    }
}
