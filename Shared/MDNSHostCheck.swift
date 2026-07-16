import Foundation
import dnssd

/// One-shot hostname check against mDNSResponder — deliberately NOT `getaddrinfo`.
///
/// Safari, CFNetwork and Network.framework resolve through mDNSResponder, while
/// the classic libinfo path (`getaddrinfo` — Chrome, curl, `dscacheutil`) reads
/// `/etc/hosts` directly. mDNSResponder's etc-hosts subsystem can wedge and stop
/// serving hosts entries entirely (observed 2026-07-16: every entry, including
/// the stock `broadcasthost`, returned "No Such Record" until the daemon was
/// fully restarted — SIGHUP did not recover it). In that state custom-domain
/// sites fail ONLY in Safari and other Apple apps, which is maximally confusing.
/// Querying through the same path Safari uses is the only reliable way to
/// detect it, and it is what makes the helper's escalate-to-restart repair safe
/// to automate.
///
/// Compiled into BOTH `WPContainerKit` (launch-time health check) and the
/// privileged `wpc-hosts-helper` (post-write verification), like
/// `HostsHelperProtocol`.
public enum MDNSHostCheck {

    /// Whether `host` resolves to `127.0.0.1` via mDNSResponder within
    /// `timeout` seconds. Returns `false` on negative answers, on timeout, AND
    /// when mDNSResponder is unreachable (e.g. mid-restart) — callers that just
    /// restarted the daemon should retry against their own deadline.
    ///
    /// Blocks the calling thread for up to `timeout`; call off the main actor.
    public static func resolvesToLoopback(_ host: String, timeout: TimeInterval = 2.0) -> Bool {
        /// Filled in by the C callback; only ever touched on this thread (the
        /// callback fires inside `DNSServiceProcessResult`).
        final class Answer {
            var isLoopback = false
            /// A definitive answer arrived (positive, or a terminal error such
            /// as NoSuchRecord) — no point waiting out the timeout.
            var isTerminal = false
        }
        let answer = Answer()

        var serviceRef: DNSServiceRef?
        // ReturnIntermediates delivers "No Such Record" as a callback instead of
        // leaving us to time out on NXDOMAIN.
        let err = DNSServiceGetAddrInfo(
            &serviceRef,
            DNSServiceFlags(kDNSServiceFlagsReturnIntermediates),
            0,
            DNSServiceProtocol(kDNSServiceProtocol_IPv4),
            host,
            { _, flags, _, errorCode, _, address, _, context in
                guard let context else { return }
                let answer = Unmanaged<Answer>.fromOpaque(context).takeUnretainedValue()
                if errorCode == DNSServiceErrorType(kDNSServiceErr_NoError), let address {
                    guard address.pointee.sa_family == sa_family_t(AF_INET) else { return }
                    let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                        $0.pointee.sin_addr.s_addr
                    }
                    if ip == inet_addr("127.0.0.1") { answer.isLoopback = true }
                    answer.isTerminal = true
                } else if flags & DNSServiceFlags(kDNSServiceFlagsMoreComing) == 0 {
                    answer.isTerminal = true
                }
            },
            Unmanaged.passUnretained(answer).toOpaque()
        )
        guard err == DNSServiceErrorType(kDNSServiceErr_NoError), let serviceRef else { return false }
        defer { DNSServiceRefDeallocate(serviceRef) }

        let fd = DNSServiceRefSockFD(serviceRef)
        guard fd >= 0 else { return false }

        let deadline = Date().addingTimeInterval(timeout)
        while !answer.isTerminal {
            let remainingMs = Int32((deadline.timeIntervalSinceNow * 1000).rounded(.down))
            guard remainingMs > 0 else { break }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, remainingMs) > 0 else { break } // timeout / error
            guard DNSServiceProcessResult(serviceRef) == DNSServiceErrorType(kDNSServiceErr_NoError) else { break }
        }
        return answer.isLoopback
    }
}
