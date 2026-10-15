import Network

extension NWParameters {
    /// TCP parameters for dialing a container (vmnet IP or published port).
    /// Use these instead of `.tcp` for every host → container connection.
    ///
    /// ECN is disabled because on macOS 27, with `net.inet.tcp.l4s=1`, the
    /// ECN-setup SYN (marked ECT(1)) reaches the guest over vmnet with a corrupt
    /// TCP checksum and gets dropped. macOS only falls back to a plain SYN after
    /// two retransmits, so every new connection stalls for about 2s. ECN does
    /// nothing useful on a host-to-local-VM link, so turning it off per connection
    /// costs nothing and doesn't depend on the system sysctl.
    public static var containerTCP: NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.disableECN = true
        return NWParameters(tls: nil, tcp: tcp)
    }
}
