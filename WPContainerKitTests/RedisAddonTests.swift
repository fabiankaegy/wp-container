import XCTest
@testable import WPContainerKit

/// Coverage for the Redis sidecar: its container recipe, the early handler that
/// defines `WP_REDIS_HOST` before the object-cache drop-in loads, and its wiring
/// through the registry, env inheritance, and the shim.
final class RedisAddonTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wpc-redis-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    // MARK: - Recipe

    func testRedisRunsEphemeralWithACappedLRUCache() throws {
        let site = makeSite()
        let args = SiteRecipe.runRedisArgs(site)
        XCTAssertTrue(containsPair(args, "--name", "wpc-example-redis"))
        let imageIndex = try XCTUnwrap(args.firstIndex(of: SiteRecipe.redisImage))
        XCTAssertEqual(Array(args[(imageIndex + 1)...]),
                       ["redis-server", "--save", "", "--appendonly", "no",
                        "--maxmemory", SiteRecipe.redisMaxMemory, "--maxmemory-policy", "allkeys-lru"])
    }

    func testRedisPublishesAndMountsNothing() {
        let args = SiteRecipe.runRedisArgs(makeSite())
        XCTAssertFalse(args.contains("-p"))
        XCTAssertFalse(args.contains("-v"))
        XCTAssertFalse(SidecarAddons.redis.publishesHostPort)
        XCTAssertTrue(SidecarAddons.redis.dataFolders(for: makeSite()).isEmpty)
    }

    // MARK: - Registry

    func testRedisFollowsItsFlag() {
        var site = makeSite()
        XCTAssertFalse(SidecarAddons.enabled(for: site).contains { $0.id == "redis" })
        site.redisEnabled = true
        XCTAssertEqual(SidecarAddons.enabled(for: site).map(\.id), ["redis"])
        XCTAssertEqual(SidecarAddons.redis.assignments(ip: "10.0.0.7"), ["WPC_REDIS_HOST=10.0.0.7"])
    }

    func testEnvInheritsRedis() {
        var parent = makeSite()
        parent.redisEnabled = true
        let env = WorktreeEnvService.descriptor(parent: parent, repoRelPath: "wp-content/plugins/demo",
                                                branch: "feature", port: 8890)
        XCTAssertTrue(env.redisEnabled)
    }

    func testLegacyRecordsDecodeWithRedisOff() throws {
        let encoded = try JSONEncoder().encode(makeSite())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "redisEnabled")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(Site.self, from: legacy)
        XCTAssertFalse(decoded.redisEnabled)
    }

    func testShimPassesTheRedisHost() {
        let wordpress = tempRoot.appendingPathComponent("example/wordpress", isDirectory: true)
        let script = WPCLIShim.shimScript(slug: "example", wordpressFolder: wordpress, cliImage: "wordpress:cli")
        XCTAssertTrue(script.contains(#"SIDECAR_IP_3="$(container_ip 'wpc-example-redis')""#))
        XCTAssertTrue(script.contains(#"-e "WPC_REDIS_HOST=${SIDECAR_IP_3:+${SIDECAR_IP_3}}""#))
    }

    // MARK: - Handler

    func testHandlerLoadsEarly() throws {
        let php = tempRoot.appendingPathComponent("php", isDirectory: true)
        try RedisService.handler.write(phpConfFolder: php)
        let url = php.appendingPathComponent("prepend.d/early/\(RedisService.handlerFileName)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(RedisService.handler.isPresent(phpConfFolder: php))

        RedisService.handler.remove(phpConfFolder: php)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testMasterLoaderIncludesEarlyHandlersAtPrependTime() {
        XCTAssertTrue(PrependService.masterContents.contains("glob( __DIR__ . '/prepend.d/early/*.php' )"))
        XCTAssertTrue(PrependService.masterContents.contains("wpc_prepend_load_early_handlers();"))
    }

    func testHandlerKeepsProjectConstantsAndHooksBeforeTheDropIn() {
        let contents = RedisService.handlerContents
        XCTAssertTrue(contents.contains("$GLOBALS['wp_filter']['enable_loading_object_cache_dropin']"))
        XCTAssertTrue(contents.contains("if ( ! defined( 'WP_REDIS_HOST' ) )"))
        XCTAssertTrue(contents.contains("if ( ! defined( 'WP_REDIS_PORT' ) )"))
        XCTAssertTrue(contents.contains("getenv( 'WPC_REDIS_HOST' )"))
        XCTAssertTrue(contents.contains("return $enabled;"))
    }

    // MARK: - Helpers

    private func makeSite() -> Site {
        Site(name: "Example", slug: "example", path: tempRoot.appendingPathComponent("example", isDirectory: true),
             port: 8881, imageTag: SiteRecipe.defaultWordPressImage)
    }

    private func containsPair(_ args: [String], _ flag: String, _ value: String) -> Bool {
        zip(args, args.dropFirst()).contains { $0 == flag && $1 == value }
    }
}
