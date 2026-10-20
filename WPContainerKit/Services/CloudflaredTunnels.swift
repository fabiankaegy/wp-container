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
/// recorded tunnels are ever deleted. The registry also lists every hostname it routed:
/// cloudflared cannot delete DNS records, so those CNAMEs outlive their tunnels, and only
/// they may be pointed at a new tunnel.
public struct CloudflaredTunnels: Sendable {
    /// The registry file's contents.
    private struct Registry: Codable {
        var tunnels: [CloudflareTunnelRecord] = []
        /// Hostnames whose DNS record WP Container created with `tunnel route dns`.
        var routedHostnames: [String] = []
    }

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

    /// Creates the tunnel and its DNS route unless they are already recorded. An existing
    /// DNS record for the hostname is overwritten only when WP Container routed it before.
    public func ensure(instanceID: UUID, tunnelName: String, hostname: String) async throws {
        try ShareProviders.validateTunnelName(tunnelName)
        guard ShareProviders.isValidDNSHost(hostname) else { throw ShareError.invalidShareHostname(hostname) }

        let recorded = records().first { $0.instanceID == instanceID && $0.tunnelName == tunnelName }
        if let recorded, let routed = recorded.hostname, routed != hostname {
            throw ShareError.cloudflaredHostnameChanged(tunnel: tunnelName, recorded: routed, requested: hostname)
        }

        if recorded == nil {
            do {
                try await run(["tunnel", "create", tunnelName])
            } catch ShareError.cloudflaredFailed(let command, let output) where output.contains("already exists") {
                let hint = "Delete the leftover tunnel with: cloudflared tunnel delete \(tunnelName)"
                throw ShareError.cloudflaredFailed(command: command, output: output + "\n" + hint)
            }
            // A crash before this save leaves an unrecorded tunnel that WP Container never
            // deletes and that blocks the next create; the user removes it with
            // `cloudflared tunnel delete <tunnelName>`.
            try update { registry in
                registry.tunnels.append(CloudflareTunnelRecord(instanceID: instanceID, tunnelName: tunnelName, hostname: nil))
            }
        } else if recorded?.hostname == hostname {
            return
        }

        let ownsRecord = routedHostnames().contains(hostname)
        let route = ownsRecord
            ? ["tunnel", "route", "dns", "--overwrite-dns", tunnelName, hostname]
            : ["tunnel", "route", "dns", tunnelName, hostname]
        do {
            try await run(route)
        } catch ShareError.cloudflaredFailed(let command, let output) {
            let exists = output.contains("already exists")
            throw exists ? ShareError.dnsRecordExists(hostname) : ShareError.cloudflaredFailed(command: command, output: output)
        }
        try update { registry in
            if !registry.routedHostnames.contains(hostname) { registry.routedHostnames.append(hostname) }
            guard let i = registry.tunnels.firstIndex(where: { $0.instanceID == instanceID && $0.tunnelName == tunnelName }) else {
                return
            }
            registry.tunnels[i].hostname = hostname
        }
    }

    public func records() -> [CloudflareTunnelRecord] {
        readRegistry().tunnels
    }

    /// Hostnames whose DNS record WP Container created, kept after their tunnels are deleted.
    public func routedHostnames() -> [String] {
        readRegistry().routedHostnames
    }

    /// Deletes a recorded tunnel and drops its record. cloudflared has no command that
    /// removes DNS records, so the CNAME is left for the user and reported as a warning.
    public func cleanup(_ record: CloudflareTunnelRecord) async -> [String] {
        guard records().contains(record) else {
            return ["Skipped \(record.tunnelName): it is not a tunnel WP Container created."]
        }
        do {
            try ShareProviders.validateTunnelName(record.tunnelName)
            try await run(["tunnel", "delete", "-f", record.tunnelName])
        } catch {
            return ["Could not delete the Cloudflare tunnel \(record.tunnelName): \(error)"]
        }
        do {
            try update { registry in registry.tunnels.removeAll { $0 == record } }
        } catch {
            return ["Deleted the Cloudflare tunnel \(record.tunnelName) but could not update the registry: \(error)"]
        }
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

    /// The registry, or an empty one when the file is missing or unreadable. A bare array
    /// of tunnel records is read as a registry whose routed hostnames are theirs.
    private func readRegistry() -> Registry {
        guard let data = try? Data(contentsOf: registryFile) else { return Registry() }
        let decoder = JSONDecoder()
        if let registry = try? decoder.decode(Registry.self, from: data) { return registry }
        guard let tunnels = try? decoder.decode([CloudflareTunnelRecord].self, from: data) else { return Registry() }
        return Registry(tunnels: tunnels, routedHostnames: tunnels.compactMap(\.hostname))
    }

    /// Applies `change` to a freshly read registry and writes it back atomically.
    private func update(_ change: (inout Registry) -> Void) throws {
        var registry = readRegistry()
        change(&registry)
        do {
            let data = try JSONEncoder().encode(registry)
            try FileManager.default.createDirectory(at: registryFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: registryFile, options: .atomic)
        } catch {
            throw ShareError.cloudflaredRegistryWriteFailed("\(registryFile.path): \(error.localizedDescription)")
        }
    }
}
