import Foundation

/// File and folder names inside a site archive.
public enum SiteArchiveLayout {
    public static let manifestName = "wpc-site.json"
    public static let databaseName = "database.sql"
    public static let wordpressFolder = "wordpress"
    public static let schemaVersion = 1
}

/// The environment-level settings of a site that travel with an archive.
/// Identity, ports, mounts, and bookkeeping stay with the destination site.
public struct SiteArchiveSettings: Codable, Sendable, Equatable {
    public var imageTag: String
    public var phpVersion: String?
    public var networkType: NetworkType
    public var httpsEnabled: Bool
    public var xdebugEnabled: Bool
    public var redisEnabled: Bool
    public var elasticsearchEnabled: Bool
    public var mailpitEnabled: Bool
    public var cpuLimit: Int?
    public var memoryLimitMB: Int?
    public var idleStopMinutes: Int?
    public var customDomain: String?
    public var lastImportSourceURL: String?

    public init(site: Site) {
        imageTag = site.imageTag
        phpVersion = site.phpVersion
        networkType = site.networkType
        httpsEnabled = site.httpsEnabled
        xdebugEnabled = site.xdebugEnabled
        redisEnabled = site.redisEnabled
        elasticsearchEnabled = site.elasticsearchEnabled
        mailpitEnabled = site.mailpitEnabled
        cpuLimit = site.cpuLimit
        memoryLimitMB = site.memoryLimitMB
        idleStopMinutes = site.idleStopMinutes
        customDomain = site.customDomain
        lastImportSourceURL = site.lastImportSourceURL
    }

    /// Copies the settings onto `site`. `mailpitEnabled` is left for the
    /// importer to enable through `setSidecar`, which also assigns its port.
    public func apply(to site: inout Site) {
        site.imageTag = imageTag
        site.phpVersion = phpVersion
        site.networkType = networkType
        site.httpsEnabled = httpsEnabled
        site.xdebugEnabled = xdebugEnabled
        site.redisEnabled = redisEnabled
        site.elasticsearchEnabled = elasticsearchEnabled
        site.cpuLimit = cpuLimit
        site.memoryLimitMB = memoryLimitMB
        site.idleStopMinutes = idleStopMinutes
        site.customDomain = customDomain
        site.lastImportSourceURL = lastImportSourceURL
        site.provisioned = true
        site.mounts = []
    }
}

/// The `wpc-site.json` document at the root of a site archive.
public struct SiteArchiveManifest: Codable, Sendable, Equatable {
    public struct Source: Codable, Sendable, Equatable {
        public var name: String
        public var slug: String
        public var url: String
        public var localURL: String

        public init(name: String, slug: String, url: String, localURL: String) {
            self.name = name
            self.slug = slug
            self.url = url
            self.localURL = localURL
        }
    }

    public var schemaVersion: Int
    public var wpcVersion: String
    public var exportedAt: Date
    public var source: Source
    public var wordpressVersion: String?
    public var tablePrefix: String?
    public var database: String
    public var excludes: [String]
    public var mountsInlined: [String]
    public var settings: SiteArchiveSettings

    public init(
        schemaVersion: Int = SiteArchiveLayout.schemaVersion,
        wpcVersion: String = WPContainerVersion.marketing,
        exportedAt: Date = Date(),
        source: Source,
        wordpressVersion: String? = nil,
        tablePrefix: String? = nil,
        database: String = SiteArchiveLayout.databaseName,
        excludes: [String] = [],
        mountsInlined: [String] = [],
        settings: SiteArchiveSettings
    ) {
        self.schemaVersion = schemaVersion
        self.wpcVersion = wpcVersion
        self.exportedAt = exportedAt
        self.source = source
        self.wordpressVersion = wordpressVersion
        self.tablePrefix = tablePrefix
        self.database = database
        self.excludes = excludes
        self.mountsInlined = mountsInlined
        self.settings = settings
    }

    public static func decode(_ data: Data) throws -> SiteArchiveManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(SiteArchiveManifest.self, from: data)
        if manifest.schemaVersion > SiteArchiveLayout.schemaVersion {
            throw SiteArchiveError.unsupportedSchema(manifest.schemaVersion)
        }
        return manifest
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

public enum SiteArchiveError: Error, Equatable, CustomStringConvertible {
    case unsupportedSchema(Int)
    case notAWPCExport
    case unsafeEntry(String)
    case insufficientDiskSpace(needed: Int64, available: Int64)
    case siteNotRunning
    case outputExists(String)
    case toolFailed(tool: String, detail: String)
    case domainInUse(String)
    case invalidDomain(String)
    case noFreePort

    public var description: String {
        switch self {
        case .unsupportedSchema(let version):
            return "This archive uses format version \(version), which this version of wpc cannot read."
        case .notAWPCExport:
            return "This file is not a wpc site export."
        case .unsafeEntry(let path):
            return "The archive contains an unsafe path: \(path)."
        case .insufficientDiskSpace(let needed, let available):
            return "Not enough disk space: \(needed) bytes needed, \(available) bytes available."
        case .siteNotRunning:
            return "The site must be running to export its database."
        case .outputExists(let path):
            return "A file already exists at \(path)."
        case .toolFailed(let tool, let detail):
            return "\(tool) failed: \(detail)"
        case .domainInUse(let domain):
            return "The domain \(domain) is already used by another site."
        case .invalidDomain(let domain):
            return "The domain \(domain) is not valid."
        case .noFreePort:
            return "No free port is available for the new site."
        }
    }
}
