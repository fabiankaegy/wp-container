import XCTest
@testable import WPContainerKit

/// Coverage for the per-site web server: the FPM tag mapping, persistence
/// defaults, env inheritance, the nginx image recipe, and the wp container
/// args each server produces.
final class WebServerTests: XCTestCase {

    // MARK: - FPM tag mapping

    func testFPMTagMapsApacheShapedTags() {
        XCTAssertEqual(WordPressImageCatalog.fpmTag(for: "wordpress:latest"), "wordpress:fpm")
        XCTAssertEqual(WordPressImageCatalog.fpmTag(for: "wordpress:apache"), "wordpress:fpm")
        XCTAssertEqual(WordPressImageCatalog.fpmTag(for: "wordpress:php8.3-apache"), "wordpress:php8.3-fpm")
        XCTAssertEqual(WordPressImageCatalog.fpmTag(for: "wordpress:6.8-php8.2-apache"), "wordpress:6.8-php8.2-fpm")
        XCTAssertEqual(WordPressImageCatalog.fpmTag(for: "wordpress:6.8"), "wordpress:6.8-fpm")
        XCTAssertEqual(WordPressImageCatalog.fpmTag(for: "wordpress:6.8-php8.3"), "wordpress:6.8-php8.3-fpm")
        XCTAssertEqual(WordPressImageCatalog.fpmTag(for: "wordpress:php8.4"), "wordpress:php8.4-fpm")
    }

    func testFPMTagKeepsFPMTags() {
        XCTAssertEqual(WordPressImageCatalog.fpmTag(for: "wordpress:fpm"), "wordpress:fpm")
        XCTAssertEqual(WordPressImageCatalog.fpmTag(for: "wordpress:6.8-php8.3-fpm"), "wordpress:6.8-php8.3-fpm")
    }

    func testFPMTagRejectsTagsWithoutAnFPMVariant() {
        XCTAssertNil(WordPressImageCatalog.fpmTag(for: "wordpress:cli-php8.3"))
        XCTAssertNil(WordPressImageCatalog.fpmTag(for: "wordpress:php8.3-fpm-alpine"))
        XCTAssertNil(WordPressImageCatalog.fpmTag(for: "example/custom-wordpress:1.0"))
    }

    func testSupports() {
        XCTAssertTrue(WebServer.apache.supports(imageTag: "example/custom-wordpress:1.0"))
        XCTAssertTrue(WebServer.nginx.supports(imageTag: "wordpress:6.8-php8.2-apache"))
        XCTAssertFalse(WebServer.nginx.supports(imageTag: "example/custom-wordpress:1.0"))
    }

    // MARK: - Persistence

    func testSiteWithoutWebServerDecodesAsApache() throws {
        let site = makeSite(webServer: .nginx)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(site)) as? [String: Any])
        XCTAssertEqual(object["webServer"] as? String, "nginx")
        object.removeValue(forKey: "webServer")
        let decoded = try JSONDecoder().decode(Site.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.webServer, .apache)
    }

    func testSiteRoundTripsNginx() throws {
        let decoded = try JSONDecoder().decode(Site.self, from: JSONEncoder().encode(makeSite(webServer: .nginx)))
        XCTAssertEqual(decoded.webServer, .nginx)
    }

    func testEnvInheritsWebServerAndNetworkType() throws {
        var parent = makeSite(webServer: .nginx)
        parent.networkType = .subdirectory
        let env = WorktreeEnvService.descriptor(parent: parent, repoRelPath: "wp-content/plugins/example",
                                                branch: "feature", port: 8301)
        XCTAssertEqual(env.webServer, .nginx)
        XCTAssertEqual(env.networkType, .subdirectory)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(env)) as? [String: Any])
        object.removeValue(forKey: "webServer")
        object.removeValue(forKey: "networkType")
        let decoded = try JSONDecoder().decode(WorktreeEnv.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.webServer, .apache)
        XCTAssertEqual(decoded.networkType, .none)
    }

    func testArchiveSettingsCarryWebServer() throws {
        var target = makeSite(webServer: .apache)
        SiteArchiveSettings(site: makeSite(webServer: .nginx)).apply(to: &target)
        XCTAssertEqual(target.webServer, .nginx)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(SiteArchiveSettings(site: makeSite(webServer: .nginx)))) as? [String: Any])
        object.removeValue(forKey: "webServer")
        let older = try JSONDecoder().decode(SiteArchiveSettings.self, from: JSONSerialization.data(withJSONObject: object))
        var imported = makeSite(webServer: .nginx)
        older.apply(to: &imported)
        XCTAssertEqual(imported.webServer, .apache)
    }

    // MARK: - Images

    func testBaseImageTagFollowsTheWebServer() {
        XCTAssertEqual(SiteRecipe.baseImageTag(for: makeSite(webServer: .apache)), "wordpress:6.8-php8.3-apache")
        XCTAssertEqual(SiteRecipe.baseImageTag(for: makeSite(webServer: .nginx)), "wordpress:6.8-php8.3-fpm")
        XCTAssertNil(SiteRecipe.baseImageTag(for: makeSite(webServer: .nginx, imageTag: "example/custom-wordpress:1.0")))
    }

    func testDerivedTags() {
        let nginx = NginxImageService.derivedTag(forBase: "wordpress:6.8-php8.3-fpm")
        XCTAssertEqual(nginx, "wpc-wordpress-nginx:v\(NginxImageService.recipeVersion)-6.8-php8.3-fpm")
        XCTAssertEqual(XdebugImageService.derivedTag(forBase: nginx),
                       "wpc-wordpress-xdebug:v\(XdebugImageService.recipeVersion)-wpc-wordpress-nginx-v\(NginxImageService.recipeVersion)-6.8-php8.3-fpm")
    }

    func testNginxBuildContext() throws {
        let context = NginxImageService.buildContext(baseTag: "wordpress:6.8-php8.3-fpm")
        let dockerfile = try XCTUnwrap(context["Dockerfile"])
        XCTAssertTrue(dockerfile.hasPrefix("FROM wordpress:6.8-php8.3-fpm\n"))
        // Every file the Dockerfile copies is in the context.
        for line in dockerfile.split(separator: "\n") where line.hasPrefix("COPY ") {
            let source = String(line.split(separator: " ")[1])
            XCTAssertNotNil(context[source], "missing build-context file \(source)")
        }
        XCTAssertTrue(try XCTUnwrap(context["wpc-fastcgi.conf"]).contains("HTTP_HOST          $http_host;"))
        XCTAssertTrue(try XCTUnwrap(context["wpc-site.conf"]).contains("location ~ \\.php$ {"))
        XCTAssertTrue(try XCTUnwrap(context["wpc-entrypoint"]).contains("\"$WPC_NETWORK_TYPE\" = subdirectory"))
    }

    // MARK: - Container args

    func testNginxWordPressArgsCarryTheNetworkType() throws {
        var site = makeSite(webServer: .nginx)
        site.networkType = .subdirectory
        let image = NginxImageService.derivedTag(forBase: "wordpress:6.8-php8.3-fpm")
        let args = SiteRecipe.runWordPressArgs(site, dbHost: "10.0.0.2", imageOverride: image)
        let index = try XCTUnwrap(args.firstIndex(of: "WPC_NETWORK_TYPE=subdirectory"))
        XCTAssertEqual(args[index - 1], "-e")
        XCTAssertEqual(args.last, image)
    }

    func testApacheWordPressArgsOmitTheNetworkType() {
        let args = SiteRecipe.runWordPressArgs(makeSite(webServer: .apache), dbHost: "10.0.0.2")
        XCTAssertFalse(args.contains { $0.hasPrefix("WPC_NETWORK_TYPE=") })
        XCTAssertEqual(args.last, "wordpress:6.8-php8.3-apache")
    }

    func testSeedUsesTheBaseImage() {
        XCTAssertTrue(SiteRecipe.seedWordPressArgs(makeSite(webServer: .nginx)).contains("wordpress:6.8-php8.3-fpm"))
        XCTAssertTrue(SiteRecipe.seedWordPressArgs(makeSite(webServer: .apache)).contains("wordpress:6.8-php8.3-apache"))
    }

    // MARK: - Helpers

    private func makeSite(webServer: WebServer, imageTag: String = "wordpress:6.8-php8.3-apache") -> Site {
        Site(name: "Example", slug: "example", path: URL(fileURLWithPath: "/tmp/wpc-web-server-tests/example"),
             port: 8300, imageTag: imageTag, webServer: webServer)
    }
}
