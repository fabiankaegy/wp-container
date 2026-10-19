import Foundation

/// Finds a free localhost port for a new site/env, starting at 8881.
public enum PortAllocator {
    public static let basePort = 8881

    /// First port `>= base` that is both not in `taken` and free to bind on
    /// 127.0.0.1. Returns nil if none found below 65536.
    public static func firstFreePort(from base: Int = basePort, excluding taken: Set<Int>) -> Int? {
        var port = max(base, 1)
        while port <= 65_535 {
            if !taken.contains(port) && isPortFree(port) {
                return port
            }
            port += 1
        }
        return nil
    }

    /// Ports these instances hold: every site's, every active env's, and the
    /// host ports of their sidecars. A settled env holds none, so its ports can
    /// be handed out again.
    public static func reservedPorts(sites: [Site], envs: [WorktreeEnv]) -> Set<Int> {
        let active = envs.filter { !$0.isSettled }
        return Set(sites.map(\.port)).union(active.map(\.port))
            .union(SidecarAddons.reservedHostPorts(sites: sites, envs: active))
    }

    /// Bind-test a TCP port on 127.0.0.1.
    public static func isPortFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 { return false }
        defer { close(fd) }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port)).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.bind(fd, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bindResult == 0
    }
}
