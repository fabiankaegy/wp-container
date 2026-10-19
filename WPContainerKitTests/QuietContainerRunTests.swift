import XCTest
@testable import WPContainerKit

/// Every `container run` recipe turns progress output off, so captured stderr
/// holds only the container's own output.
final class QuietContainerRunTests: XCTestCase {

    private let site = Site(name: "Example", slug: "example",
                            path: URL(fileURLWithPath: "/tmp/wpc-quiet-tests/example", isDirectory: true),
                            port: 8881, imageTag: SiteRecipe.defaultWordPressImage)

    func testEveryRunRecipeDisablesProgress() {
        let recipes: [String: [String]] = [
            "seedWordPress": SiteRecipe.seedWordPressArgs(site),
            "runDatabase": SiteRecipe.runDatabaseArgs(site),
            "createEnvDatabase": SiteRecipe.createEnvDatabaseArgs(dbHost: "10.0.0.2", schema: "wpc_example"),
            "cloneDatabase": SiteRecipe.cloneDatabaseArgs(dbHost: "10.0.0.2", from: "wordpress", to: "wpc_example"),
            "dropEnvDatabase": SiteRecipe.dropEnvDatabaseArgs(dbHost: "10.0.0.2", schema: "wpc_example"),
            "runWordPress": SiteRecipe.runWordPressArgs(site, dbHost: "10.0.0.2"),
            "runElasticsearch": SiteRecipe.runElasticsearchArgs(site),
            "runMailpit": SiteRecipe.runMailpitArgs(site, webPort: 8025),
            "wpProxy": SiteRecipe.wpProxyArgs(site, dbHost: "10.0.0.2", wpArgs: ["option", "get", "home"]),
            "wpCoreInstall": SiteRecipe.wpCoreInstallArgs(site, dbHost: "10.0.0.2"),
        ]
        for (name, args) in recipes {
            XCTAssertEqual(Array(args.prefix(3)), ["run", "--progress", "none"], name)
        }
    }

    func testImagePullIsUnchanged() {
        XCTAssertEqual(SiteRecipe.pullImageArgs("wordpress:latest"), ["image", "pull", "wordpress:latest"])
    }
}
