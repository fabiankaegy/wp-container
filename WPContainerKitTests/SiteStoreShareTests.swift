import XCTest
@testable import WPContainerKit

/// Upserts from the app keep the share state on disk, so a record held across a long
/// operation never brings back an older share.
@MainActor
final class SiteStoreShareTests: XCTestCase {

    private var tempRoot: URL!
    private var persistence: StorePersistence!

    override func setUp() async throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SiteStoreShareTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        persistence = StorePersistence(fileURL: tempRoot.appendingPathComponent("sites.json"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testUpsertWithAStaleSiteKeepsTheStoredShare() async throws {
        let live = ShareSettings(username: "share", password: "secret-one", active: true, authDisabled: true,
                                 requestID: UUID())
        var stale = Site(name: "my-site", slug: "my-site", path: tempRoot.appendingPathComponent("my-site", isDirectory: true),
                         port: 8881, imageTag: SiteRecipe.defaultWordPressImage, share: live)
        try await persistence.save(StoreEnvelope(sites: [stale], shareDefaultProvider: "cloudflared"))
        let stopped = ShareSettings(username: "share", password: "secret-two", requestID: live.requestID)
        try await persistence.mutate { $0.sites[0].share = stopped }
        let store = SiteStore(persistence: persistence)
        await store.reload()

        stale.httpsEnabled = true
        await store.upsertSite(stale)

        let envelope = try await persistence.load()
        XCTAssertEqual(envelope.sites[0].share, stopped)
        XCTAssertTrue(envelope.sites[0].httpsEnabled)
        XCTAssertEqual(envelope.shareDefaultProvider, "cloudflared")
        XCTAssertEqual(store.site(id: stale.id)?.share, stopped)
    }

    func testUpsertWithAStaleEnvKeepsTheStoredShare() async throws {
        let live = ShareSettings(username: "share", password: "secret-one", active: true, requestID: UUID())
        var stale = WorktreeEnv(parentSiteID: UUID(), parentSlug: "my-site", envSlug: "my-site-wt-feature",
                                repoRelPath: "wp-content/plugins/example", branch: "feature",
                                worktreePath: tempRoot.appendingPathComponent("checkouts/feature", isDirectory: true),
                                envPath: tempRoot.appendingPathComponent("my-site/.envs/feature", isDirectory: true),
                                port: 8882, imageTag: SiteRecipe.defaultWordPressImage, share: live)
        try await persistence.save(StoreEnvelope(envs: [stale]))
        try await persistence.mutate { $0.envs[0].share = nil }
        let store = SiteStore(persistence: persistence)

        stale.xdebugEnabled = true
        await store.upsertEnv(stale)

        let env = try await persistence.load().envs[0]
        XCTAssertNil(env.share)
        XCTAssertTrue(env.xdebugEnabled)
    }

    func testUpsertOfANewSiteSavesItsShare() async throws {
        let share = ShareSettings(username: "share", password: "secret-one")
        let site = Site(name: "my-site", slug: "my-site", path: tempRoot.appendingPathComponent("my-site", isDirectory: true),
                        port: 8881, imageTag: SiteRecipe.defaultWordPressImage, share: share)
        let store = SiteStore(persistence: persistence)

        await store.upsertSite(site)

        let stored = try await persistence.load().sites.first?.share
        XCTAssertEqual(stored, share)
    }
}
