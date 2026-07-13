import Foundation
import os

/// The WP × PHP version matrix offered by the setup guide (PLAN.md §2k).
///
/// `wordPressVersions` and PHP lists are ordered newest-first. `phpByWordPress`
/// narrows the PHP picker to combinations that actually publish an official
/// `wordpress:<wp>-php<php>-apache` tag.
public struct WordPressVersionMatrix: Sendable, Codable, Equatable {
    public var wordPressVersions: [String]
    public var phpByWordPress: [String: [String]]
    public var allPHPVersions: [String]

    public init(wordPressVersions: [String], phpByWordPress: [String: [String]], allPHPVersions: [String]) {
        self.wordPressVersions = wordPressVersions
        self.phpByWordPress = phpByWordPress
        self.allPHPVersions = allPHPVersions
    }

    /// PHP versions published for a given WordPress version (newest first).
    public func phpVersions(for wordpress: String) -> [String] {
        phpByWordPress[wordpress] ?? allPHPVersions
    }

    /// Whether a WP×PHP pairing is expected to resolve to a published tag.
    public func isValid(wp: String, php: String) -> Bool {
        phpVersions(for: wp).contains(php)
    }

    /// A sensible default PHP for a WP version: the catalog default when
    /// published for it, else the newest published one.
    public func defaultPHP(for wordpress: String) -> String {
        let options = phpVersions(for: wordpress)
        if options.contains(WordPressImageCatalog.defaultPHP) { return WordPressImageCatalog.defaultPHP }
        return options.first ?? WordPressImageCatalog.defaultPHP
    }
}

/// Live WordPress × PHP version discovery from Docker Hub (PLAN.md §2k
/// follow-up): instead of a hardcoded version matrix that rots, query the
/// official library's published tags, cache the result on disk, and fall back
/// to `WordPressImageCatalog.fallbackMatrix` offline.
///
/// Endpoint (verified empirically 2026-07-13):
///   https://hub.docker.com/v2/repositories/library/wordpress/tags
///     ?page_size=100&name=apache   → `<wp>-php<X>-apache` + `php<X>-apache`
///     ?page_size=100&name=cli      → `cli`, `cli-php<X>`
/// Results are ordered newest-updated-first, so one page of `apache` tags
/// covers every actively-published series (currently 7.0 and 6.9); older
/// series come from the static fallback via a union.
public actor WordPressVersionCatalog {
    public static let shared = WordPressVersionCatalog()

    private static let log = Logger(subsystem: "com.fabiankaegy.wpcontainer", category: "version-catalog")

    /// Refetch when the disk cache is older than this.
    private let maxCacheAge: TimeInterval
    private let cacheURL: URL

    private struct CacheEnvelope: Codable {
        var fetchedAt: Date
        var matrix: WordPressVersionMatrix
        var cliPHPVersions: [String]
    }

    private var memory: CacheEnvelope?

    public init(cacheURL: URL? = nil, maxCacheAge: TimeInterval = 24 * 3600) {
        self.maxCacheAge = maxCacheAge
        self.cacheURL = cacheURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WPContainer/version-catalog.json")
    }

    /// The best matrix available RIGHT NOW without hitting the network:
    /// fresh-or-stale disk cache, else the static fallback.
    public func cachedMatrix() -> WordPressVersionMatrix {
        if let cached = loadCache() { return cached.matrix }
        return WordPressImageCatalog.fallbackMatrix
    }

    /// The current matrix, refreshing from Docker Hub when the cache is
    /// missing or stale. Network failure degrades to the cached/static matrix —
    /// this never throws and never blocks the UI on an error path.
    public func matrix(forceRefresh: Bool = false) async -> WordPressVersionMatrix {
        if !forceRefresh, let cached = loadCache(),
           Date().timeIntervalSince(cached.fetchedAt) < maxCacheAge {
            WordPressImageCatalog.registerPublishedCLIPHPVersions(cached.cliPHPVersions)
            return cached.matrix
        }
        do {
            let (matrix, cliPHP) = try await fetchFromDockerHub()
            let envelope = CacheEnvelope(fetchedAt: Date(), matrix: matrix, cliPHPVersions: cliPHP)
            saveCache(envelope)
            WordPressImageCatalog.registerPublishedCLIPHPVersions(cliPHP)
            return matrix
        } catch {
            Self.log.warning("Docker Hub version discovery failed (\("\(error)", privacy: .public)); using cached/static matrix.")
            return cachedMatrix()
        }
    }

    // MARK: - Docker Hub fetch

    private struct TagsPage: Decodable {
        struct Tag: Decodable { let name: String }
        let results: [Tag]
    }

    private func fetchTags(nameFilter: String) async throws -> [String] {
        var comps = URLComponents(string: "https://hub.docker.com/v2/repositories/library/wordpress/tags")!
        comps.queryItems = [
            URLQueryItem(name: "page_size", value: "100"),
            URLQueryItem(name: "name", value: nameFilter),
        ]
        var request = URLRequest(url: comps.url!)
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(TagsPage.self, from: data).results.map(\.name)
    }

    /// Parse published tags into a matrix, then UNION with the static fallback
    /// so older-but-still-pullable series (no longer on the first page of
    /// newest-updated tags) stay offered.
    private func fetchFromDockerHub() async throws -> (WordPressVersionMatrix, cliPHP: [String]) {
        async let apacheTags = fetchTags(nameFilter: "apache")
        async let cliTags = fetchTags(nameFilter: "cli")

        var phpByWP: [String: Set<String>] = [:]
        let wpPHP = /^(\d+\.\d+)-php(\d+\.\d+)-apache$/
        let latestPHP = /^php(\d+\.\d+)-apache$/
        for tag in try await apacheTags {
            if let m = tag.wholeMatch(of: wpPHP) {
                phpByWP[String(m.1), default: []].insert(String(m.2))
            } else if let m = tag.wholeMatch(of: latestPHP) {
                phpByWP["latest", default: []].insert(String(m.1))
            }
        }
        guard phpByWP.count > 1 else { throw URLError(.cannotParseResponse) } // implausible ⇒ treat as failure

        // Union with the static fallback (older series + safety net).
        for (wp, phps) in WordPressImageCatalog.fallbackMatrix.phpByWordPress {
            phpByWP[wp, default: []].formUnion(phps)
        }

        let versionSort: (String, String) -> Bool = { a, b in
            a.compare(b, options: .numeric) == .orderedDescending
        }
        let wpVersions = ["latest"] + phpByWP.keys.filter { $0 != "latest" }.sorted(by: versionSort)
        let byWP = phpByWP.mapValues { Array($0).sorted(by: versionSort) }
        let allPHP = Array(Set(phpByWP.values.flatMap { $0 })).sorted(by: versionSort)

        let cliPHP = (try await cliTags).compactMap { tag -> String? in
            guard let m = tag.wholeMatch(of: /^cli-php(\d+\.\d+)$/) else { return nil }
            return String(m.1)
        }.sorted(by: versionSort)

        return (WordPressVersionMatrix(wordPressVersions: wpVersions, phpByWordPress: byWP, allPHPVersions: allPHP),
                cliPHP)
    }

    // MARK: - Disk cache

    private func loadCache() -> CacheEnvelope? {
        if let memory { return memory }
        guard let data = try? Data(contentsOf: cacheURL),
              let envelope = try? JSONDecoder().decode(CacheEnvelope.self, from: data) else { return nil }
        memory = envelope
        return envelope
    }

    private func saveCache(_ envelope: CacheEnvelope) {
        memory = envelope
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(envelope) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }
}
