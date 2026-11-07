import XCTest
@testable import WPContainerKit

/// A share ends in the store when its instance starts or stops, so a proxy host that did
/// not see the stop never reopens it.
final class ShareLifecycleTests: XCTestCase {

    private var tempRoot: URL!
    private var persistence: StorePersistence!

    override func setUp() async throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShareLifecycleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        persistence = StorePersistence(fileURL: tempRoot.appendingPathComponent("sites.json"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testEndShareClearsActiveAndNoAuthAndKeepsTheRest() async throws {
        let site = makeSite(share: activeShare())
        let env = makeEnv(share: activeShare())
        try await persistence.save(StoreEnvelope(sites: [site], envs: [env]))

        try await persistence.endShare(instanceID: site.id)
        try await persistence.endShare(instanceID: env.id)

        let envelope = try await persistence.load()
        for share in [envelope.sites[0].share, envelope.envs[0].share] {
            XCTAssertEqual(share?.active, false)
            XCTAssertEqual(share?.authDisabled, false)
            XCTAssertEqual(share?.password, "secret-one")
            XCTAssertEqual(share?.hostname, "share.example.com")
            XCTAssertEqual(share?.allow.map(\.description), ["/wp-json/example/webhook"])
        }
    }

    func testEndShareWritesNothingWhenTheShareIsInactive() async throws {
        var share = activeShare()
        share.active = false
        share.authDisabled = false
        try await persistence.save(StoreEnvelope(sites: [makeSite(share: share), makeSite(slug: "other-site", share: nil)]))
        let file = tempRoot.appendingPathComponent("sites.json")
        let before = try Data(contentsOf: file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: file.path)

        let envelope = try await persistence.load()
        for site in envelope.sites {
            try await persistence.endShare(instanceID: site.id)
        }
        try await persistence.endShare(instanceID: UUID())

        let modified = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        XCTAssertEqual(modified, Date(timeIntervalSince1970: 0))
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testStoppingAnInstanceEndsItsShare() async throws {
        let env = makeEnv(share: activeShare())
        try await persistence.save(StoreEnvelope(envs: [env]))
        let lifecycle = SiteLifecycle(cli: ContainerCLI(binaryPath: try fakeContainer().path), persistence: persistence)

        let stopped = await lifecycle.stop(env, verifyTeardown: false)

        XCTAssertTrue(stopped)
        let share = try await persistence.load().envs.first?.share
        XCTAssertEqual(share?.active, false)
        XCTAssertEqual(share?.authDisabled, false)
        XCTAssertEqual(share?.password, "secret-one")
    }

    // MARK: - Helpers

    /// A `container` stand-in that succeeds and lists nothing.
    private func fakeContainer() throws -> URL {
        let script = tempRoot.appendingPathComponent("container")
        try "#!/bin/sh\necho '[]'\nexit 0\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    private func activeShare() -> ShareSettings {
        ShareSettings(provider: "ngrok", hostname: "share.example.com", username: "share", password: "secret-one",
                      allow: [try! ShareException(parsing: "/wp-json/example/webhook")], active: true,
                      authDisabled: true, requestID: UUID())
    }

    private func makeSite(slug: String = "my-site", share: ShareSettings?) -> Site {
        Site(name: slug, slug: slug, path: tempRoot.appendingPathComponent(slug, isDirectory: true),
             port: 8881, imageTag: SiteRecipe.defaultWordPressImage, share: share)
    }

    /// A shared-database env: stopping it touches no database container or lock file.
    private func makeEnv(share: ShareSettings?) -> WorktreeEnv {
        WorktreeEnv(parentSiteID: UUID(), parentSlug: "my-site", envSlug: "my-site-wt-feature",
                    repoRelPath: "wp-content/plugins/example", branch: "feature",
                    worktreePath: tempRoot.appendingPathComponent("checkouts/feature", isDirectory: true),
                    envPath: tempRoot.appendingPathComponent("my-site/.envs/feature", isDirectory: true),
                    port: 8882, imageTag: SiteRecipe.defaultWordPressImage, sharedDatabase: true,
                    databaseSchema: "wp_feature", share: share)
    }
}
