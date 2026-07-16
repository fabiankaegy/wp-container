import Foundation
import os

/// Detects and repairs the "site loads in Chrome but Safari can't find the
/// server" failure (2026-07-16). Safari resolves through mDNSResponder, whose
/// etc-hosts subsystem can wedge and stop serving `/etc/hosts` entries even
/// though the file is perfectly valid — the libinfo path (Chrome, curl,
/// `dscacheutil`) keeps working, so the breakage looks Safari-specific and
/// nothing in the hosts file explains it. SIGHUP does not recover the daemon;
/// a full restart does. See `MDNSHostCheck` for the detection primitive.
///
/// `checkAndRepair()` is silent and logged, safe to run on every app launch:
/// it no-ops without managed domains, and only restarts mDNSResponder (via the
/// promptless `repairDNSResolver` helper op) when entries that are demonstrably
/// in the file fail to resolve through the path Safari uses.
public enum DNSHealthService {
    static let log = Logger(subsystem: "com.fabiankaegy.wpcontainer", category: "dns-health")

    public enum Status: Sendable, Equatable {
        /// No custom domains are registered — nothing to check.
        case notApplicable
        /// Every managed domain resolves through mDNSResponder.
        case healthy
        /// mDNSResponder was wedged; restarting it restored resolution.
        case repaired(domains: [String])
        /// Broken and not repaired — helper unavailable, or the restart didn't
        /// help. The listed domains resolve via /etc/hosts but not in Safari.
        case broken(domains: [String], reason: String)
    }

    /// Check every domain in the managed `/etc/hosts` block through the SAME
    /// resolver path Safari uses; when broken, restart mDNSResponder via the
    /// privileged helper and re-verify.
    public static func checkAndRepair() async -> Status {
        let contents = (try? String(contentsOfFile: HostsFileService.hostsPath, encoding: .utf8)) ?? ""
        let domains = HostsFileService.managedDomains(in: contents)
        guard !domains.isEmpty else { return .notApplicable }

        // MDNSHostCheck blocks its thread (healthy case: single-digit ms per
        // domain; wedged case: up to the timeout) — keep it off the pool the
        // caller runs on.
        let broken = await Task.detached(priority: .utility) {
            domains.filter { !MDNSHostCheck.resolvesToLoopback($0, timeout: 2.0) }
        }.value
        guard !broken.isEmpty else { return .healthy }

        log.error("mDNSResponder is not serving /etc/hosts entries for: \(broken.joined(separator: ", "), privacy: .public)")

        guard HostsHelperClient.isEnabled else {
            let reason = "hosts helper not enabled — run `sudo killall mDNSResponder` to repair manually"
            log.error("cannot auto-repair: \(reason, privacy: .public)")
            return .broken(domains: broken, reason: reason)
        }
        do {
            try await HostsHelperClient.repairDNSResolver()
        } catch {
            log.error("DNS repair via helper failed: \(String(describing: error), privacy: .public)")
            return .broken(domains: broken, reason: String(describing: error))
        }

        // The daemon respawns on demand; poll one of the broken domains until
        // it comes back (or we give up and report).
        let recovered = await Task.detached(priority: .utility) { () -> Bool in
            let deadline = Date().addingTimeInterval(4.0)
            while Date() < deadline {
                if MDNSHostCheck.resolvesToLoopback(broken[0], timeout: 1.0) { return true }
                usleep(250_000)
            }
            return false
        }.value

        if recovered {
            log.notice("mDNSResponder restart restored resolution for \(broken.joined(separator: ", "), privacy: .public)")
            return .repaired(domains: broken)
        }
        let reason = "mDNSResponder restart did not restore resolution"
        log.error("\(reason, privacy: .public)")
        return .broken(domains: broken, reason: reason)
    }
}
