import Foundation

/// The owned loopback zone (PLAN.md §2f-ter): WP Container's own loopback
/// addresses, DNS zone and pf redirect, so sites stop squatting on
/// `127.0.0.1:80/443` — the address every other local dev tool (Valet/Herd,
/// Local, Docker) also lands on.
///
/// How a request reaches a site in zone mode:
///   1. `<slug>.wpc.test` resolves via `/etc/resolver/wpc.test` to the proxy
///      process's tiny DNS responder on `127.0.0.1:<dnsPort>`, which answers
///      every name in the zone with `ipv4` / `ipv6` (the lo0 aliases).
///      Custom domains get `/etc/hosts` lines pointing at the same aliases.
///   2. pf (anchor `pfAnchor`, loaded by the root helper) redirects
///      `ipv4|ipv6 :80/:443` — and the vmnet gateway's `:80/:443`, which is how
///      in-container WordPress loopback requests reach the host — onto the
///      proxy's unprivileged loopback listeners `httpPort` / `httpsPort`.
///
/// Every value is a FIXED constant compiled into both the app/CLI and the
/// privileged helper. The helper therefore never takes an address, port or
/// rule from its client — the only input to the zone ops is one Bool.
///
/// Fixed ports (rather than whatever the proxy happens to bind) keep the
/// resolver file static and the root-side rules free of client data. If any of
/// them is taken, the proxy falls back to the legacy wildcard `*:80/*:443`
/// listeners instead of guessing another port.
public enum LoopbackZone {
    /// The DNS zone sites live in by default: `<slug>.wpc.test`. `.test` is
    /// reserved (RFC 2606), so it can never collide with a real domain, and
    /// unlike `.local` it never touches mDNS.
    public static let zone = "wpc.test"

    /// lo0 alias every zone name resolves to. Not `127.0.0.1`, so nothing else
    /// on the machine competes for its ports.
    public static let ipv4 = "127.0.0.77"
    /// IPv6 lo0 alias (a /128 out of the ULA range fd00::/8; `7063` is "pc").
    /// Gives AAAA lookups — and the `/etc/hosts` lines of `.local` custom
    /// domains, which would otherwise wait out a 5s mDNS timeout — an answer
    /// that reaches us instead of whatever owns `[::1]:443`.
    public static let ipv6 = "fd77:7063::77"

    /// Proxy plain-HTTP listener (`127.0.0.1` + `::1`). pf maps `:80` onto it.
    public static let httpPort: UInt16 = 47080
    /// Proxy TLS listener (`127.0.0.1` + `::1`). pf maps `:443` onto it.
    public static let httpsPort: UInt16 = 47443
    /// The zone's DNS responder (UDP, `127.0.0.1` only). resolver(5) honours a
    /// non-53 `port`, so no redirect is needed for DNS.
    public static let dnsPort: UInt16 = 47053

    /// Written once by the helper; its presence is also how unprivileged code
    /// knows the zone is set up (`isInstalled`).
    public static let resolverPath = "/etc/resolver/\(zone)"

    /// pf anchor the helper loads its rules into. Apple's stock `/etc/pf.conf`
    /// already evaluates `rdr-anchor "com.apple/*"`, so pf.conf is never edited.
    public static let pfAnchor = "com.apple/wpcontainer"

    /// The vmnet bridge Apple `container` attaches guests to. Its (dynamic)
    /// address is the gateway the in-guest `/etc/hosts` maps site names to.
    public static let vmnetInterface = "bridge100"

    /// Whether the helper has set the zone up on this Mac (and not torn it
    /// down since). Cheap and unprivileged, so the model layer can use it to
    /// pick the default host for new sites. Says nothing about whether a proxy
    /// is currently serving it.
    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: resolverPath)
    }

    /// `<label>.wpc.test`.
    public static func host(_ label: String) -> String { "\(label).\(zone)" }

    /// Contents of `resolverPath`.
    public static var resolverFileContents: String {
        """
        # Managed by WP Container: *.\(zone) is answered by the app's built-in
        # DNS responder. Removed when the privileged helper is turned off.
        nameserver 127.0.0.1
        port \(dnsPort)

        """
    }

    /// The pf rules for `pfAnchor`.
    ///
    /// - `legacyLoopback`: ALSO redirect `127.0.0.1` / `::1` `:80/:443`. Needed
    ///   only while some instance is still served at a `*.localhost` URL, which
    ///   browsers hard-wire to 127.0.0.1 — see `HTTPSProxy.needsLegacyLoopback`.
    ///   This is the one rule set that still competes with other dev tools, so it
    ///   exists only as a migration bridge.
    /// - `includeVMNet`: the gateway rules. Separate so the helper can retry
    ///   without them if a kernel ever refuses an absent-interface rule.
    public static func pfRules(legacyLoopback: Bool, includeVMNet: Bool = true) -> String {
        var lines = [
            "rdr pass on lo0 inet proto tcp from any to \(ipv4) port 80 -> 127.0.0.1 port \(httpPort)",
            "rdr pass on lo0 inet proto tcp from any to \(ipv4) port 443 -> 127.0.0.1 port \(httpsPort)",
            "rdr pass on lo0 inet6 proto tcp from any to \(ipv6) port 80 -> ::1 port \(httpPort)",
            "rdr pass on lo0 inet6 proto tcp from any to \(ipv6) port 443 -> ::1 port \(httpsPort)",
        ]
        if includeVMNet {
            let nic = vmnetInterface
            lines += [
                "rdr pass on \(nic) inet proto tcp from any to (\(nic)) port 80 -> 127.0.0.1 port \(httpPort)",
                "rdr pass on \(nic) inet proto tcp from any to (\(nic)) port 443 -> 127.0.0.1 port \(httpsPort)",
            ]
        }
        if legacyLoopback {
            lines += [
                "rdr pass on lo0 inet proto tcp from any to 127.0.0.1 port 80 -> 127.0.0.1 port \(httpPort)",
                "rdr pass on lo0 inet proto tcp from any to 127.0.0.1 port 443 -> 127.0.0.1 port \(httpsPort)",
                "rdr pass on lo0 inet6 proto tcp from any to ::1 port 80 -> ::1 port \(httpPort)",
                "rdr pass on lo0 inet6 proto tcp from any to ::1 port 443 -> ::1 port \(httpsPort)",
            ]
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
