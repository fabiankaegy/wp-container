import Foundation
import Network
import Security

/// TLS-terminating reverse proxy for trusted local HTTPS (PLAN.md §2f).
///
/// Listens on 443 (falling back to 8443), terminates TLS with the CA's wildcard
/// leaf identity, routes each request to `127.0.0.1:<site port>` by its `Host`
/// header, and injects `X-Forwarded-Proto: https` / `X-Forwarded-Host` so
/// WordPress builds correct HTTPS URLs. Containers are never touched.
///
/// Deliberately simple and correct rather than clever: TLS in, one HTTP/1.1
/// request per connection (we force `Connection: close`), a header rewrite at the
/// request boundary, then a raw bidirectional byte relay to the upstream. No
/// HTTP/2, no keep-alive multiplexing.
public final class HTTPSProxy: @unchecked Sendable {
    public enum ProxyError: Error, Sendable, CustomStringConvertible {
        case identityUnavailable(String)
        case listenerFailed(String)
        case noPortAvailable

        public var description: String {
            switch self {
            case .identityUnavailable(let s): return "TLS identity unavailable: \(s)"
            case .listenerFailed(let s):      return "listener failed: \(s)"
            case .noPortAvailable:            return "neither 443 nor 8443 could be bound"
            }
        }
    }

    public static let preferredPorts: [UInt16] = [443, 8443]
    /// Plain-HTTP listener ports for custom domains without HTTPS (PLAN.md §2i).
    public static let preferredHTTPPorts: [UInt16] = [80, 8080]

    private let ca: CertificateAuthority
    private let persistence: StorePersistence
    private let queue = DispatchQueue(label: "dev.wpcontainer.httpsproxy", attributes: .concurrent)
    private let stateLock = NSLock()

    /// A resolved routing entry: the upstream port plus the display metadata
    /// used by the friendly "site is stopped" page (#6).
    public struct Route: Sendable {
        public let port: Int
        /// Store slug usable with `wp-container start <slug>` (site or env slug).
        public let slug: String?
        public let displayName: String?

        public init(port: Int, slug: String? = nil, displayName: String? = nil) {
            self.port = port
            self.slug = slug
            self.displayName = displayName
        }
    }

    private var listener: NWListener?
    private var httpListener: NWListener?
    private var hostMap: [String: Route] = [:]
    private var refreshTask: Task<Void, Never>?
    private var _boundPort: UInt16?
    private var _boundHTTPPort: UInt16?
    /// SAN hosts the leaf currently covers, to detect when a reload is needed.
    private var coveredHosts: Set<String> = []

    public init(ca: CertificateAuthority = CertificateAuthority(),
                persistence: StorePersistence = StorePersistence()) {
        self.ca = ca
        self.persistence = persistence
    }

    /// The port the listener actually bound, once started.
    public var boundPort: UInt16? {
        stateLock.withLock { _boundPort }
    }

    /// The plain-HTTP listener port, once started.
    public var boundHTTPPort: UInt16? {
        stateLock.withLock { _boundHTTPPort }
    }

    // MARK: - Host map

    /// Replace the `<host> → port` routing table (compat overload — routes
    /// carry no display metadata, so the stopped-site page falls back to the
    /// hostname).
    public func updateHostMap(_ map: [String: Int]) {
        stateLock.withLock { hostMap = map.mapValues { Route(port: $0) } }
    }

    /// Replace the full `<host> → route` table.
    public func updateHostMap(routes: [String: Route]) {
        stateLock.withLock { hostMap = routes }
    }

    /// Route by an exact Host-header lookup, then fall back to stripping the
    /// leftmost label so subdomain-multisite subsites (`sub.<slug>.localhost`,
    /// `sub.mysite.local`) route to their network's port (PLAN.md §2i/§2j).
    private func route(forHost host: String) -> Route? {
        // Strip any :port suffix and lowercase.
        var name = host.split(separator: ":").first.map { $0.lowercased() } ?? host.lowercased()
        return stateLock.withLock {
            while true {
                if let route = hostMap[name] { return route }
                guard let dot = name.firstIndex(of: ".") else { return nil }
                let rest = String(name[name.index(after: dot)...])
                if rest.isEmpty || !rest.contains(".") { return nil }
                name = rest
            }
        }
    }

    /// Build a routing table from a store envelope: every site and env is
    /// reachable at `<slug>.localhost`, and custom-domain sites also at their
    /// domain, regardless of `httpsEnabled` (the flag governs WordPress URL
    /// rewriting, not proxy reachability). Subdomain-multisite wildcards are
    /// handled by the leftmost-label fallback in `route(forHost:)`.
    public static func routes(from envelope: StoreEnvelope) -> [String: Route] {
        var map: [String: Route] = [:]
        for site in envelope.sites {
            let route = Route(port: site.port, slug: site.slug, displayName: site.name)
            map["\(site.slug).localhost"] = route
            if let domain = site.customDomain, !domain.isEmpty { map[domain.lowercased()] = route }
            // Mailpit web UI at <slug>-mail.localhost (issue #10).
            if site.mailpitEnabled, let mp = site.mailpitPort {
                map["\(site.slug)-mail.localhost"] = Route(port: mp, slug: site.slug,
                                                           displayName: "\(site.name) · Mailbox")
            }
        }
        for env in envelope.envs {
            map["\(env.envSlug).localhost"] = Route(port: env.port, slug: env.envSlug,
                                                    displayName: "\(env.parentSlug) · \(env.branch)")
            if env.mailpitEnabled, let mp = env.mailpitPort {
                map["\(env.envSlug)-mail.localhost"] = Route(port: mp, slug: env.envSlug,
                                                             displayName: "\(env.parentSlug) · \(env.branch) · Mailbox")
            }
        }
        return map
    }

    /// Compat: the port-only view of `routes(from:)`.
    public static func hostMap(from envelope: StoreEnvelope) -> [String: Int] {
        routes(from: envelope).mapValues(\.port)
    }

    /// The full set of leaf SAN hostnames the cert must cover for an envelope
    /// (includes custom domains and subdomain-multisite wildcards, §2i/§2j).
    public static func sanHosts(from envelope: StoreEnvelope) -> [String] {
        var hosts = Set<String>()
        for site in envelope.sites {
            site.proxyHosts.forEach { hosts.insert($0) }
            // Cover the mailbox hostname so https://<slug>-mail.localhost is
            // trusted when the proxy serves it (issue #10).
            if site.mailpitEnabled, site.mailpitPort != nil { hosts.insert("\(site.slug)-mail.localhost") }
        }
        for env in envelope.envs {
            hosts.insert("\(env.envSlug).localhost")
            if env.mailpitEnabled, env.mailpitPort != nil { hosts.insert("\(env.envSlug)-mail.localhost") }
        }
        return Array(hosts)
    }

    // MARK: - Lifecycle

    /// Ensure certs exist, import the identity, bind the listener, and begin
    /// serving. Refreshes the host map from the store every few seconds so
    /// CLI/app changes are picked up without a restart.
    @discardableResult
    public func start() async throws -> UInt16 {
        // Seed the host map and ensure the leaf covers every current hostname
        // (explicit SANs — the *.localhost wildcard alone isn't honored by
        // OpenSSL/curl) BEFORE importing the identity.
        var hosts: [String] = []
        if let env = try? await persistence.load() {
            updateHostMap(routes: Self.routes(from: env))
            hosts = Self.sanHosts(from: env)
        }
        // Exact-set sync (#4): covers every live hostname AND prunes SAN
        // leftovers from sites/envs deleted before SAN-removal shipped.
        try await ca.syncLeafCoverage(hosts)
        stateLock.withLock { coveredHosts = Set(hosts) }
        let identity = try await loadSecIdentity()

        let tlsOptions = NWProtocolTLS.Options()
        guard let secIdentity = sec_identity_create(identity) else {
            throw ProxyError.identityUnavailable("sec_identity_create returned nil")
        }
        sec_protocol_options_set_local_identity(tlsOptions.securityProtocolOptions, secIdentity)

        var lastError: Error?
        var bound: UInt16?
        for candidate in Self.preferredPorts {
            do {
                let params = NWParameters(tls: tlsOptions)
                params.allowLocalEndpointReuse = true
                let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: candidate)!)
                try await startListener(listener, port: candidate, forwardedProto: "https")
                stateLock.withLock { _boundPort = candidate; self.listener = listener }
                bound = candidate
                break
            } catch {
                lastError = error
                continue
            }
        }
        guard let boundPort = bound else { throw lastError ?? ProxyError.noPortAvailable }

        // Plain-HTTP listener for custom domains with HTTPS off (§2i). Best
        // effort: HTTPS is the primary path, so a failure here is non-fatal.
        for candidate in Self.preferredHTTPPorts {
            do {
                let params = NWParameters.tcp
                params.allowLocalEndpointReuse = true
                let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: candidate)!)
                try await startListener(listener, port: candidate, forwardedProto: "http")
                stateLock.withLock { _boundHTTPPort = candidate; self.httpListener = listener }
                break
            } catch { continue }
        }

        startRefreshLoop()
        return boundPort
    }

    public func stop() {
        refreshTask?.cancel(); refreshTask = nil
        stateLock.withLock {
            listener?.cancel()
            listener = nil
            _boundPort = nil
            httpListener?.cancel()
            httpListener = nil
            _boundHTTPPort = nil
        }
    }

    /// Rebind the listener with a freshly imported identity and reseeded host
    /// table — used after the leaf is re-issued (e.g. new custom domain, §2i) so
    /// the cert swaps without an app restart. Returns the (possibly new) port.
    @discardableResult
    public func reload() async throws -> UInt16 {
        stop()
        return try await start()
    }

    private func startListener(_ listener: NWListener, port: UInt16, forwardedProto: String) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let resumed = ResumeOnce()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.tryResume() { cont.resume() }
                case .failed(let error):
                    if resumed.tryResume() { cont.resume(throwing: ProxyError.listenerFailed("\(error)")) }
                case .cancelled:
                    if resumed.tryResume() { cont.resume(throwing: ProxyError.listenerFailed("cancelled")) }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(inbound: connection, forwardedProto: forwardedProto)
            }
            listener.start(queue: queue)
        }
    }

    /// Refresh the host map from the store every few seconds, and re-issue +
    /// reload the leaf when the SAN set changes (so CLI-side domain edits are
    /// picked up by a headless proxy without a manual restart, §2i).
    private func startRefreshLoop() {
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self else { return }
                guard let env = try? await self.persistence.load() else { continue }
                self.updateHostMap(routes: Self.routes(from: env))
                let wanted = Set(Self.sanHosts(from: env))
                let known = self.stateLock.withLock { self.coveredHosts }
                if wanted != known {
                    self.stateLock.withLock { self.coveredHosts = wanted }
                    // Exact-set sync (#4): new hostnames get SANs, and SANs of
                    // deleted sites/envs are pruned rather than kept forever.
                    if (try? await self.ca.syncLeafCoverage(Array(wanted))) == true {
                        try? await self.reload()
                        return // reload() spins a fresh loop
                    }
                }
            }
        }
    }

    // MARK: - Connection handling

    private func handle(inbound: NWConnection, forwardedProto: String) {
        inbound.start(queue: queue)
        readRequestHeader(from: inbound, accumulated: Data(), forwardedProto: forwardedProto)
    }

    /// Accumulate inbound bytes until the end of the HTTP header block (CRLFCRLF).
    private func readRequestHeader(from inbound: NWConnection, accumulated: Data, forwardedProto: String) {
        inbound.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = accumulated
            if let data, !data.isEmpty { buffer.append(data) }

            if let range = Self.headerTerminator(in: buffer) {
                let headerData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                let bodyStart = buffer.subdata(in: range.upperBound..<buffer.endIndex)
                self.route(inbound: inbound, rawHeader: headerData, bufferedBody: bodyStart, forwardedProto: forwardedProto)
                return
            }
            if error != nil || isComplete {
                inbound.cancel()
                return
            }
            if buffer.count > 1_048_576 { // 1 MiB header cap — abuse guard.
                inbound.cancel()
                return
            }
            self.readRequestHeader(from: inbound, accumulated: buffer, forwardedProto: forwardedProto)
        }
    }

    private func route(inbound: NWConnection, rawHeader: Data, bufferedBody: Data, forwardedProto: String) {
        guard let header = String(data: rawHeader, encoding: .utf8) else { inbound.cancel(); return }
        let lines = header.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else { inbound.cancel(); return }

        let host = Self.headerValue("Host", in: lines) ?? ""
        guard let target = self.route(forHost: host) else {
            self.sendHTMLResponse(to: inbound, status: "502 Bad Gateway",
                                  html: Self.unknownHostPage(host: host))
            return
        }

        let rewritten = Self.rewriteHeaders(requestLine: requestLine, lines: Array(lines.dropFirst()), host: host, proto: forwardedProto)
        let upstreamBytes: Data = {
            var bytes = Data(rewritten.utf8)
            bytes.append(bufferedBody)
            return bytes
        }()

        // Connect explicitly and only forward once the upstream is READY: a
        // known host whose containers are stopped must get the friendly
        // "site is stopped" page (#6), not a raw connection reset. On
        // 127.0.0.1 a refused connect surfaces as `.waiting(ECONNREFUSED)`
        // (Network.framework treats it as transient and would retry forever),
        // so `.waiting` is treated as down too — correct for localhost where a
        // live listener accepts immediately.
        let upstream = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(target.port))!, using: .tcp)
        let decided = ResumeOnce()
        upstream.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard decided.tryResume() else { return }
                upstream.stateUpdateHandler = nil
                upstream.send(content: upstreamBytes, completion: .contentProcessed { [weak self] err in
                    if err != nil { inbound.cancel(); upstream.cancel(); return }
                    // Bidirectional raw relay until either side closes.
                    self?.relay(from: upstream, to: inbound)
                    self?.relay(from: inbound, to: upstream)
                })
            case .waiting, .failed:
                guard decided.tryResume() else { return }
                upstream.stateUpdateHandler = nil
                upstream.cancel()
                self.sendHTMLResponse(to: inbound, status: "502 Bad Gateway",
                                      html: Self.stoppedSitePage(host: host, route: target))
            case .cancelled:
                if decided.tryResume() { inbound.cancel() }
            default:
                break
            }
        }
        upstream.start(queue: queue)
    }

    /// One-directional pump: read from `source`, write to `destination`, tear
    /// both down on EOF/error.
    private func relay(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
            if let data, !data.isEmpty {
                destination.send(content: data, completion: .contentProcessed { _ in })
            }
            if isComplete || error != nil {
                source.cancel()
                destination.cancel()
                return
            }
            self.relay(from: source, to: destination)
        }
    }

    private func sendHTMLResponse(to inbound: NWConnection, status: String, html: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n\(html)"
        inbound.send(content: Data(response.utf8), completion: .contentProcessed { _ in inbound.cancel() })
    }

    // MARK: - Friendly 502 pages (#6)

    private static func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Shared shell for the styled proxy pages. `refresh` adds a meta-refresh
    /// so "start the site from the app" feels instant (#6).
    private static func proxyPage(title: String, heading: String, bodyHTML: String,
                                  refreshSeconds: Int?) -> String {
        let refreshTag = refreshSeconds.map { "<meta http-equiv=\"refresh\" content=\"\($0)\">" } ?? ""
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        \(refreshTag)
        <title>\(title)</title>
        <style>
          :root { color-scheme: light dark; }
          body {
            margin: 0; min-height: 100vh; display: flex; align-items: center; justify-content: center;
            font: 15px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
            background: #f5f5f7; color: #1d1d1f;
          }
          main { max-width: 30rem; padding: 2.5rem 2.75rem; background: #fff; border-radius: 18px;
                 box-shadow: 0 10px 40px rgba(0,0,0,.08); margin: 1.5rem; }
          .badge { display: inline-block; font-size: .75rem; font-weight: 600; letter-spacing: .06em;
                   padding: .25rem .6rem; border-radius: 999px; background: rgba(255,149,0,.15); color: #b25000; }
          h1 { font-size: 1.35rem; margin: .8rem 0 .4rem; }
          p { margin: .5rem 0; color: #6e6e73; }
          code, pre { font: .85rem/1.5 ui-monospace, "SF Mono", Menlo, monospace; }
          pre { background: rgba(0,0,0,.05); padding: .7rem .9rem; border-radius: 10px; overflow-x: auto; user-select: all; }
          .hint { font-size: .8rem; opacity: .75; }
          @media (prefers-color-scheme: dark) {
            body { background: #1c1c1e; color: #f5f5f7; }
            main { background: #2c2c2e; box-shadow: 0 10px 40px rgba(0,0,0,.4); }
            .badge { background: rgba(255,159,10,.2); color: #ffb340; }
            p { color: #98989d; }
            pre { background: rgba(255,255,255,.08); }
          }
        </style>
        </head>
        <body><main>
        <span class="badge">WP CONTAINER · 502</span>
        <h1>\(heading)</h1>
        \(bodyHTML)
        </main></body>
        </html>
        """
    }

    /// Known host, but its containers are down → tell the user how to start it.
    static func stoppedSitePage(host: String, route: Route) -> String {
        let name = htmlEscape(route.displayName ?? route.slug ?? host)
        let hostEsc = htmlEscape(host.split(separator: ":").first.map(String.init) ?? host)
        var body = "<p><code>\(hostEsc)</code> is a WP Container site, but it isn’t running right now.</p>"
        if let slug = route.slug {
            body += """
            <p>Start it from the WP Container app, or run:</p>
            <pre><code>wp-container start \(htmlEscape(slug))</code></pre>
            """
        } else {
            body += "<p>Start it from the WP Container app.</p>"
        }
        body += "<p class=\"hint\">This page reloads every 3 seconds and will show the site as soon as it’s up.</p>"
        return proxyPage(title: "\(name) is stopped — WP Container",
                         heading: "\(name) is stopped",
                         bodyHTML: body, refreshSeconds: 3)
    }

    /// Wholly-unmapped host → say so (styled, no slug hint available).
    static func unknownHostPage(host: String) -> String {
        let hostEsc = htmlEscape(host.isEmpty ? "(no Host header)" : host)
        let body = """
        <p>No WP Container site is mapped to <code>\(hostEsc)</code>.</p>
        <p class="hint">Check the site’s URL in WP Container, or <code>wp-container list</code>.</p>
        """
        return proxyPage(title: "No site here — WP Container",
                         heading: "No site mapped to this host",
                         bodyHTML: body, refreshSeconds: nil)
    }

    // MARK: - HTTP header helpers

    private static func headerTerminator(in data: Data) -> Range<Data.Index>? {
        let pattern = Data("\r\n\r\n".utf8)
        return data.range(of: pattern)
    }

    private static func headerValue(_ name: String, in lines: [String]) -> String? {
        let lower = name.lowercased()
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            if line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased() == lower {
                return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Rebuild the header block: drop hop-by-hop/forwarding headers we own,
    /// force `Connection: close`, and inject the X-Forwarded-* pair.
    private static func rewriteHeaders(requestLine: String, lines: [String], host: String, proto: String) -> String {
        var kept: [String] = []
        for line in lines {
            if line.isEmpty { continue }
            guard let colon = line.firstIndex(of: ":") else { kept.append(line); continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            switch key {
            case "x-forwarded-proto", "x-forwarded-host", "connection", "keep-alive", "proxy-connection", "upgrade":
                continue // we set these ourselves / strip hop-by-hop
            default:
                kept.append(line)
            }
        }
        kept.append("X-Forwarded-Proto: \(proto)")
        kept.append("X-Forwarded-Host: \(host)")
        kept.append("Connection: close")
        return requestLine + "\r\n" + kept.joined(separator: "\r\n") + "\r\n\r\n"
    }

    // MARK: - Identity

    private func loadSecIdentity() async throws -> SecIdentity {
        let p12URL = await ca.leafP12URL
        let data: Data
        do { data = try Data(contentsOf: p12URL) }
        catch { throw ProxyError.identityUnavailable("cannot read \(p12URL.lastPathComponent): \(error)") }

        let options = [kSecImportExportPassphrase as String: CertificateAuthority.p12Passphrase]
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess else {
            throw ProxyError.identityUnavailable("SecPKCS12Import failed (OSStatus \(status))")
        }
        guard let array = items as? [[String: Any]],
              let first = array.first,
              let identityAny = first[kSecImportItemIdentity as String] else {
            throw ProxyError.identityUnavailable("no identity in PKCS#12 bundle")
        }
        return identityAny as! SecIdentity
    }
}

/// One-shot guard so a continuation is resumed exactly once across NW callbacks.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func tryResume() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
