import Foundation

/// A named tunnel WP Container created. `hostname` is set only once the DNS route exists.
public struct CloudflareTunnelRecord: Codable, Sendable, Equatable {
    public let instanceID: UUID
    public let tunnelName: String
    public var hostname: String?

    public init(instanceID: UUID, tunnelName: String, hostname: String?) {
        self.instanceID = instanceID
        self.tunnelName = tunnelName
        self.hostname = hostname
    }
}

/// Creates and removes the named tunnels behind fixed cloudflared hostnames.
///
/// Everything it creates is recorded in a registry file beside the proxy files, so a
/// tunnel is still cleaned up after its instance is deleted from any surface, and only
/// recorded tunnels are ever deleted.
public struct CloudflaredTunnels: Sendable {
    private let executable: URL
    private let registryFile: URL

    public init(
        executable: URL,
        registryFile: URL = ProxyControl.directory.appendingPathComponent("share-cloudflare.json")
    ) {
        self.executable = executable
        self.registryFile = registryFile
    }

    public static func tunnelName(for slug: String) -> String {
        "wpc-" + slug
    }

    /// Creates the tunnel and its DNS route unless they are already recorded.
    /// An existing DNS record for the hostname is never overwritten.
    public func ensure(instanceID: UUID, tunnelName: String, hostname: String) async throws {
        try ShareProviders.validateTunnelName(tunnelName)
        guard ShareProviders.isValidDNSHost(hostname) else { throw ShareError.invalidShareHostname(hostname) }

        var all = records()
        var index = all.firstIndex { $0.instanceID == instanceID && $0.tunnelName == tunnelName }
        if index == nil {
            try await run(["tunnel", "create", tunnelName])
            all.append(CloudflareTunnelRecord(instanceID: instanceID, tunnelName: tunnelName, hostname: nil))
            index = all.count - 1
            save(all)
        }
        guard let index else { return }
        guard all[index].hostname != hostname else { return }

        do {
            try await run(["tunnel", "route", "dns", tunnelName, hostname])
        } catch ShareError.cloudflaredFailed(let command, let output) {
            let exists = output.contains("already exists")
            throw exists ? ShareError.dnsRecordExists(hostname) : ShareError.cloudflaredFailed(command: command, output: output)
        }
        all[index].hostname = hostname
        save(all)
    }

    public func records() -> [CloudflareTunnelRecord] {
        guard let data = try? Data(contentsOf: registryFile),
              let decoded = try? JSONDecoder().decode([CloudflareTunnelRecord].self, from: data)
        else { return [] }
        return decoded
    }

    /// Deletes a recorded tunnel and drops its record. cloudflared has no command that
    /// removes DNS records, so the CNAME is left for the user and reported as a warning.
    public func cleanup(_ record: CloudflareTunnelRecord) async -> [String] {
        var all = records()
        guard all.contains(record) else {
            return ["Skipped \(record.tunnelName): it is not a tunnel WP Container created."]
        }
        do {
            try ShareProviders.validateTunnelName(record.tunnelName)
            try await run(["tunnel", "delete", "-f", record.tunnelName])
        } catch {
            return ["Could not delete the Cloudflare tunnel \(record.tunnelName): \(error)"]
        }
        all.removeAll { $0 == record }
        save(all)
        guard let hostname = record.hostname else { return [] }
        return ["cloudflared cannot delete DNS records: remove the CNAME for \(hostname) in the Cloudflare dashboard."]
    }

    private func run(_ arguments: [String]) async throws {
        let result = try await ProcessRunner.run(executable: executable.path, args: arguments)
        guard !result.succeeded else { return }
        let output = (result.stderr + "\n" + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
        if output.contains("cert.pem") || output.contains("origin cert") {
            throw ShareError.cloudflaredNotLoggedIn
        }
        throw ShareError.cloudflaredFailed(command: arguments.prefix(while: { !$0.hasPrefix("-") }).joined(separator: " "), output: output)
    }

    private func save(_ records: [CloudflareTunnelRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? FileManager.default.createDirectory(at: registryFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: registryFile, options: .atomic)
    }
}
