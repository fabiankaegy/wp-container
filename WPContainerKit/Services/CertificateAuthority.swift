import Foundation

/// mkcert-style local certificate authority for trusted HTTPS (PLAN.md §2f).
///
/// Generates a "WP Container Local CA" (key + self-signed cert) once, plus a
/// single wildcard leaf (`*.localhost`, `localhost`, `127.0.0.1`) signed by it,
/// and exports a PKCS#12 bundle the `HTTPSProxy` imports as a `SecIdentity`.
///
/// All crypto is delegated to the system `openssl` (LibreSSL) via argument-array
/// `Process` calls — verified to work with LibreSSL 3.3.6. Trusting the CA is a
/// one-time admin action left to the user (`trustCA()`); everything else runs
/// without elevation.
public actor CertificateAuthority {
    public enum CAError: Error, Sendable, CustomStringConvertible {
        case openSSLFailed(String)
        case fileMissing(String)

        public var description: String {
            switch self {
            case .openSSLFailed(let s): return "openssl failed: \(s)"
            case .fileMissing(let s):   return "expected file missing: \(s)"
            }
        }
    }

    public static let opensslPath = "/usr/bin/openssl"
    public static let securityPath = "/usr/bin/security"
    public static let systemKeychain = "/Library/Keychains/System.keychain"

    /// PKCS#12 passphrase used only for the on-disk bundle handed to SecPKCS12Import.
    public static let p12Passphrase = "wpcontainer"

    /// Default leaf SAN entries. Each entry is a bare host or IP; `IP:`/`DNS:`
    /// classification is automatic. A later phase (custom domains, PLAN.md §2i)
    /// appends entries like `mysite.local` and re-issues via `issueLeaf(sans:)`.
    public static let defaultSANs = ["*.localhost", "localhost", "127.0.0.1"]

    public let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? CertificateAuthority.defaultDirectory
    }

    /// `~/Library/Application Support/WPContainer/ca/`
    public static var defaultDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("WPContainer", isDirectory: true)
            .appendingPathComponent("ca", isDirectory: true)
    }

    public var caKeyURL: URL { directory.appendingPathComponent("ca.key") }
    public var caCertURL: URL { directory.appendingPathComponent("ca.pem") }
    public var leafKeyURL: URL { directory.appendingPathComponent("leaf.key") }
    public var leafCertURL: URL { directory.appendingPathComponent("leaf.pem") }
    public var leafP12URL: URL { directory.appendingPathComponent("leaf.p12") }
    public var sansFileURL: URL { directory.appendingPathComponent("sans.json") }

    /// The SAN entries the current leaf was (or will be) issued for.
    public func currentSANs() -> [String] {
        guard let data = try? Data(contentsOf: sansFileURL),
              let list = try? JSONDecoder().decode([String].self, from: data),
              !list.isEmpty else { return Self.defaultSANs }
        return list
    }

    /// True once the CA cert + leaf bundle exist on disk.
    public var isGenerated: Bool {
        FileManager.default.fileExists(atPath: caCertURL.path)
            && FileManager.default.fileExists(atPath: leafCertURL.path)
            && FileManager.default.fileExists(atPath: leafP12URL.path)
    }

    /// Generate the CA (if absent) and the leaf + PKCS#12 bundle for the current
    /// SAN set. Idempotent: an existing CA is reused so the trusted root never
    /// changes, and the leaf is only issued if missing.
    public func ensureGenerated() async throws {
        try ensureDirectory()
        if !FileManager.default.fileExists(atPath: caCertURL.path) {
            try await generateCA()
        }
        if !FileManager.default.fileExists(atPath: leafP12URL.path)
            || !FileManager.default.fileExists(atPath: leafCertURL.path) {
            try await issueLeaf(sans: currentSANs())
        }
    }

    /// (Re)issue the wildcard leaf for an explicit SAN set, persisting it so
    /// later phases can append custom domains and re-issue cheaply. The CA is
    /// generated first if needed; the trusted root is untouched.
    public func issueLeaf(sans: [String]) async throws {
        try ensureDirectory()
        if !FileManager.default.fileExists(atPath: caCertURL.path) {
            try await generateCA()
        }
        let effective = sans.isEmpty ? Self.defaultSANs : sans
        try persistSANs(effective)
        try await generateLeaf(sans: effective)
    }

    // MARK: - CA + leaf generation

    private func generateCA() async throws {
        try await openssl([
            "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-keyout", caKeyURL.path, "-out", caCertURL.path,
            "-days", "3650",
            "-subj", "/CN=WP Container Local CA/O=WP Container",
            "-addext", "basicConstraints=critical,CA:TRUE",
            "-addext", "keyUsage=critical,keyCertSign,cRLSign",
        ])
        try restrict(caKeyURL)
        try restrict(caCertURL)
        guard FileManager.default.fileExists(atPath: caCertURL.path) else {
            throw CAError.fileMissing(caCertURL.path)
        }
    }

    private func generateLeaf(sans: [String]) async throws {
        let csrURL = directory.appendingPathComponent("leaf.csr")
        let extURL = directory.appendingPathComponent("leaf.ext")
        defer {
            try? FileManager.default.removeItem(at: csrURL)
            try? FileManager.default.removeItem(at: extURL)
        }
        // CN is the first DNS-style SAN for readability; SANs are authoritative.
        let cn = sans.first(where: { !isIPAddress($0) }) ?? sans.first ?? "*.localhost"
        // Leaf private key + CSR.
        try await openssl(["genrsa", "-out", leafKeyURL.path, "2048"])
        try await openssl(["req", "-new", "-key", leafKeyURL.path, "-out", csrURL.path,
                           "-subj", "/CN=\(cn)"])
        // v3 extensions: SANs + serverAuth, ~825-day validity (Apple trust limit).
        let sanList = sans.map { isIPAddress($0) ? "IP:\($0)" : "DNS:\($0)" }.joined(separator: ",")
        let ext = """
        basicConstraints=CA:FALSE
        keyUsage=critical,digitalSignature,keyEncipherment
        extendedKeyUsage=serverAuth
        subjectAltName=\(sanList)
        """
        try ext.write(to: extURL, atomically: true, encoding: .utf8)
        try await openssl([
            "x509", "-req", "-in", csrURL.path,
            "-CA", caCertURL.path, "-CAkey", caKeyURL.path, "-CAcreateserial",
            "-out", leafCertURL.path, "-days", "825", "-extfile", extURL.path,
        ])
        // PKCS#12 bundle the proxy imports as a SecIdentity.
        try await openssl([
            "pkcs12", "-export",
            "-inkey", leafKeyURL.path, "-in", leafCertURL.path, "-certfile", caCertURL.path,
            "-out", leafP12URL.path, "-name", "WP Container Leaf",
            "-passout", "pass:\(Self.p12Passphrase)",
        ])
        try restrict(leafKeyURL)
        try restrict(leafP12URL)
        guard FileManager.default.fileExists(atPath: leafP12URL.path) else {
            throw CAError.fileMissing(leafP12URL.path)
        }
    }

    // MARK: - Trust

    /// Whether the CA cert is already trusted as a root by the system.
    /// Uses `security verify-cert` (exit 0 ⇒ chain validates against trust store).
    public func isCATrusted() async -> Bool {
        guard FileManager.default.fileExists(atPath: caCertURL.path) else { return false }
        let result = try? await ProcessRunner.run(
            executable: Self.securityPath,
            args: ["verify-cert", "-c", caCertURL.path, "-p", "basic"]
        )
        return result?.exitCode == 0
    }

    /// Install the CA cert as a trusted root in the System keychain. Prompts for
    /// administrator privileges via osascript (exactly mkcert's mechanism).
    /// NOTE: triggers a GUI admin prompt — call only in response to explicit user intent.
    public func trustCA() async throws {
        try await ensureGenerated()
        // Build the privileged `security add-trusted-cert` invocation and run it
        // through osascript so macOS presents the standard admin auth dialog.
        let inner = "\(Self.securityPath) add-trusted-cert -d -r trustRoot -k \(Self.systemKeychain) "
            + shellQuote(caCertURL.path)
        let script = "do shell script \"\(appleScriptEscape(inner))\" with administrator privileges"
        let result = try await ProcessRunner.run(
            executable: "/usr/bin/osascript",
            args: ["-e", script]
        )
        if result.exitCode != 0 {
            throw CAError.openSSLFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }

    // MARK: - Helpers

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    private func restrict(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func persistSANs(_ sans: [String]) throws {
        let data = try JSONEncoder().encode(sans)
        try data.write(to: sansFileURL, options: .atomic)
    }

    /// True for a literal IPv4/IPv6 address (so SAN entries are tagged `IP:` not `DNS:`).
    private func isIPAddress(_ s: String) -> Bool {
        var v4 = in_addr(); var v6 = in6_addr()
        return s.withCString { inet_pton(AF_INET, $0, &v4) } == 1
            || s.withCString { inet_pton(AF_INET6, $0, &v6) } == 1
    }

    @discardableResult
    private func openssl(_ args: [String]) async throws -> String {
        let result = try await ProcessRunner.run(executable: Self.opensslPath, args: args)
        guard result.succeeded else {
            throw CAError.openSSLFailed("openssl \(args.first ?? "") — \(result.stderr.isEmpty ? result.stdout : result.stderr)")
        }
        return result.stdout
    }

    private func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
