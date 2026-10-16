import Foundation
import OSLog

/// The owned zone's DNS responder (PLAN.md §2f-ter): answers every name in
/// `LoopbackZone.zone` — `<slug>.wpc.test`, and any subdomain of it, which is
/// what makes subdomain multisite work without per-subsite hosts entries — with
/// the zone's lo0 aliases.
///
/// Runs INSIDE the proxy process (app or `wp-container proxy serve`), not in
/// the root helper: the zone's names are only useful while the proxy serves
/// them, so co-locating guarantees "resolves ⇔ proxied", and parsing packets is
/// exactly the kind of work that should stay unprivileged. macOS reaches it via
/// `/etc/resolver/wpc.test` (`nameserver 127.0.0.1`, `port 47053`), which the
/// helper writes once.
///
/// Deliberately tiny: UDP only (our answers are a few dozen bytes, never
/// truncated, so resolvers never fall back to TCP), one question per query,
/// authoritative answers, and REFUSED for anything outside the zone.
public enum LoopbackZoneDNS {
    static let log = Logger(subsystem: "com.fabiankaegy.wpcontainer", category: "zone-dns")

    /// Answer TTL. The aliases are compile-time constants, so this only bounds
    /// how long a cached answer outlives the zone being torn down.
    static let ttl: UInt32 = 60

    private static let typeA: UInt16 = 1
    private static let typeAAAA: UInt16 = 28
    private static let classIN: UInt16 = 1

    /// Build the response datagram for `query`, or nil to drop it (malformed,
    /// or not a standard query). Pure — the unit-tested core.
    public static func response(to query: [UInt8]) -> [UInt8]? {
        guard query.count >= 12 else { return nil }
        let flags = UInt16(query[2]) << 8 | UInt16(query[3])
        // Must be a query (QR=0), opcode QUERY (0), with exactly one question.
        guard flags & 0x8000 == 0, (flags >> 11) & 0xF == 0,
              query[4] == 0, query[5] == 1 else { return nil }

        // Walk QNAME (uncompressed labels — compression is never used in a question).
        var i = 12
        var labels: [String] = []
        while true {
            guard i < query.count else { return nil }
            let len = Int(query[i])
            if len == 0 { i += 1; break }
            guard len <= 63, i + 1 + len <= query.count else { return nil }
            labels.append(String(decoding: query[(i + 1)..<(i + 1 + len)], as: UTF8.self).lowercased())
            i += 1 + len
        }
        guard i + 4 <= query.count else { return nil }
        let qtype = UInt16(query[i]) << 8 | UInt16(query[i + 1])
        let qclass = UInt16(query[i + 2]) << 8 | UInt16(query[i + 3])
        let questionEnd = i + 4

        let name = labels.joined(separator: ".")
        let zone = LoopbackZone.zone
        let inZone = name == zone || name.hasSuffix("." + zone)

        var rdata: [UInt8]?
        if inZone, qclass == classIN {
            if qtype == typeA { rdata = ipv4Bytes(LoopbackZone.ipv4) }
            if qtype == typeAAAA { rdata = ipv6Bytes(LoopbackZone.ipv6) }
        }

        // Header: same ID; QR=1, AA=1 (in zone), RD echoed; RCODE NOERROR, or
        // REFUSED (5) for names that aren't ours. Any other type in the zone is
        // NOERROR with no answer (NODATA): the name exists, that record doesn't.
        var out: [UInt8] = [query[0], query[1]]
        let rd = flags & 0x0100
        let responseFlags: UInt16 = 0x8000 | (inZone ? 0x0400 : 0) | rd | (inZone ? 0 : 5)
        out += [UInt8(responseFlags >> 8), UInt8(responseFlags & 0xFF)]
        out += [0, 1, 0, rdata == nil ? 0 : 1, 0, 0, 0, 0] // QD=1, AN, NS=0, AR=0 (EDNS dropped)
        out += query[12..<questionEnd]
        if let rdata {
            out += [0xC0, 0x0C] // name: pointer to the question's QNAME
            out += [UInt8(qtype >> 8), UInt8(qtype & 0xFF), 0, UInt8(classIN)]
            out += [UInt8(ttl >> 24), UInt8((ttl >> 16) & 0xFF), UInt8((ttl >> 8) & 0xFF), UInt8(ttl & 0xFF)]
            out += [0, UInt8(rdata.count)]
            out += rdata
        }
        return out
    }

    private static func ipv4Bytes(_ s: String) -> [UInt8] {
        var addr = in_addr()
        inet_pton(AF_INET, s, &addr)
        return withUnsafeBytes(of: &addr) { Array($0) }
    }

    private static func ipv6Bytes(_ s: String) -> [UInt8] {
        var addr = in6_addr()
        inet_pton(AF_INET6, s, &addr)
        return withUnsafeBytes(of: &addr) { Array($0) }
    }

    // MARK: - Server

    /// A UDP socket on `127.0.0.1:<port>` answering with `response(to:)`.
    /// Plain BSD socket + dispatch source: a stateless request/response
    /// datagram loop gains nothing from Network.framework's connection model.
    public final class Server: @unchecked Sendable {
        private let queue = DispatchQueue(label: "dev.wpcontainer.zone-dns")
        private var source: DispatchSourceRead?

        public init() {}

        /// Bind and start answering. Throws when the port is unavailable.
        public func start(port: UInt16 = LoopbackZone.dnsPort) throws {
            let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            // A proxy `reload()` stops and immediately restarts the responder;
            // the old socket closes asynchronously on `queue`.
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard rc == 0 else {
                let err = errno
                close(fd)
                throw POSIXError(.init(rawValue: err) ?? .EADDRINUSE)
            }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)

            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { Self.drain(fd) }
            source.setCancelHandler { close(fd) }
            self.source = source
            source.resume()
        }

        public func stop() {
            source?.cancel()
            source = nil
        }

        /// Answer every datagram currently queued on `fd`.
        private static func drain(_ fd: Int32) {
            var buffer = [UInt8](repeating: 0, count: 1500)
            while true {
                var peer = sockaddr_storage()
                var peerLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
                let n = withUnsafeMutablePointer(to: &peer) { peerPtr in
                    peerPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(fd, &buffer, buffer.count, 0, $0, &peerLen)
                    }
                }
                guard n > 0 else { return }
                guard let reply = LoopbackZoneDNS.response(to: Array(buffer[0..<n])) else { continue }
                _ = withUnsafePointer(to: &peer) { peerPtr in
                    peerPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, reply, reply.count, 0, $0, peerLen)
                    }
                }
            }
        }
    }
}
