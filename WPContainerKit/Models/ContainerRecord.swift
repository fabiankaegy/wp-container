import Foundation

/// A single container as reported by `container list --all --format json`
/// (and `container inspect`).
///
/// IMPORTANT: The exact JSON shape emitted by `container` 1.1.0 is being
/// validated by a parallel agent. Decoding is therefore done *defensively* with
/// `JSONSerialization` and kept entirely inside this file so it is trivial to
/// adjust: we only extract id/name, status, labels, image, IP address, and
/// published ports, and we tolerate both flat and `configuration`-nested shapes
/// as well as unknown/extra keys.
public struct ContainerRecord: Sendable, Equatable {
    public var id: String
    public var name: String
    /// Raw status string as reported by the CLI (e.g. "running", "stopped").
    public var status: String
    public var labels: [String: String]
    public var image: String?
    public var ipAddress: String?
    public var publishedPorts: [PublishedPort]

    public struct PublishedPort: Sendable, Equatable {
        public var hostIP: String?
        public var hostPort: Int?
        public var containerPort: Int?
    }

    public var isRunning: Bool {
        status.lowercased().contains("running")
    }

    /// The WP-Container site slug label, if present.
    public var siteLabel: String? { labels["dev.wpcontainer.site"] }
    /// The WP-Container env slug label, if present.
    public var envLabel: String? { labels["dev.wpcontainer.env"] }

    // MARK: - Defensive decoding (adjust here only)

    public static func decodeList(from data: Data) throws -> [ContainerRecord] {
        guard !data.isEmpty else { return [] }
        let json = try JSONSerialization.jsonObject(with: data)
        if let array = json as? [[String: Any]] {
            return array.compactMap { parse($0) }
        }
        if let object = json as? [String: Any], let one = parse(object) {
            return [one]
        }
        return []
    }

    static func parse(_ raw: [String: Any]) -> ContainerRecord? {
        // Some shapes nest most fields under "configuration".
        let config = (raw["configuration"] as? [String: Any]) ?? raw

        let id = firstString(config["id"], raw["id"], config["name"], raw["name"])
        guard let id, !id.isEmpty else { return nil }
        let name = firstString(config["name"], raw["name"], config["hostname"]) ?? id

        let status = statusString(raw["status"] ?? config["status"] ?? raw["state"] ?? config["state"]) ?? "unknown"
        let labels = labelsDict(config["labels"] ?? raw["labels"])
        let image = imageString(config["image"] ?? raw["image"])
        let ip = firstIP(from: raw["networks"] ?? config["networks"] ?? raw["network"] ?? config["network"])
        let ports = parsePorts(config["publishedPorts"] ?? raw["publishedPorts"] ?? config["ports"] ?? raw["ports"])

        return ContainerRecord(id: id, name: name, status: status, labels: labels,
                               image: image, ipAddress: ip, publishedPorts: ports)
    }

    private static func firstString(_ values: Any?...) -> String? {
        for v in values { if let s = v as? String, !s.isEmpty { return s } }
        return nil
    }

    private static func statusString(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        if let dict = value as? [String: Any] {
            return firstString(dict["status"], dict["state"], dict["phase"])
        }
        return nil
    }

    private static func labelsDict(_ value: Any?) -> [String: String] {
        if let dict = value as? [String: String] { return dict }
        if let dict = value as? [String: Any] {
            var out: [String: String] = [:]
            for (k, v) in dict { if let s = v as? String { out[k] = s } }
            return out
        }
        // Sometimes labels come as an array of {key,value} or "k=v" strings.
        if let arr = value as? [[String: Any]] {
            var out: [String: String] = [:]
            for item in arr {
                if let k = item["key"] as? String, let v = item["value"] as? String { out[k] = v }
            }
            return out
        }
        if let arr = value as? [String] {
            var out: [String: String] = [:]
            for entry in arr {
                if let eq = entry.firstIndex(of: "=") {
                    out[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
                }
            }
            return out
        }
        return [:]
    }

    private static func imageString(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        if let dict = value as? [String: Any] {
            return firstString(dict["reference"], dict["name"], dict["image"], dict["tag"])
        }
        return nil
    }

    private static func firstIP(from value: Any?) -> String? {
        func extract(_ dict: [String: Any]) -> String? {
            // Prefer explicit address fields; strip any CIDR suffix.
            if let s = firstString(dict["address"], dict["ipAddress"], dict["ip"], dict["gateway"] as? String) {
                return s.split(separator: "/").first.map(String.init)
            }
            return nil
        }
        if let arr = value as? [[String: Any]] {
            for n in arr { if let ip = extract(n) { return ip } }
        }
        if let dict = value as? [String: Any] { return extract(dict) }
        if let s = value as? String { return s.split(separator: "/").first.map(String.init) }
        return nil
    }

    private static func parsePorts(_ value: Any?) -> [PublishedPort] {
        guard let arr = value as? [[String: Any]] else { return [] }
        return arr.map { item in
            PublishedPort(
                hostIP: item["hostIP"] as? String ?? item["hostAddress"] as? String,
                hostPort: intValue(item["hostPort"] ?? item["host"]),
                containerPort: intValue(item["containerPort"] ?? item["container"])
            )
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let s = value as? String { return Int(s) }
        if let d = value as? Double { return Int(d) }
        return nil
    }
}
