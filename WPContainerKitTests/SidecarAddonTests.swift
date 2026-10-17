import XCTest
@testable import WPContainerKit

/// Coverage for the sidecar addon registry: container names, the env vars the
/// wp container and wp-cli receive, host-port bookkeeping, env inheritance, and
/// the shared toggle.
final class SidecarAddonTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wpc-sidecar-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    // MARK: - Registry

    func testContainerNamesMatchTheInstanceNames() {
        let site = makeSite()
        XCTAssertEqual(SidecarAddons.elasticsearch.containerName(for: site), "wpc-example-es")
        XCTAssertEqual(SidecarAddons.mailpit.containerName(for: site), "wpc-example-mail")
        XCTAssertEqual(site.esContainerName, "wpc-example-es")
        XCTAssertEqual(site.mailContainerName, "wpc-example-mail")
    }

    func testIdentifiersAndSuffixesAreUnique() {
        XCTAssertEqual(Set(SidecarAddons.all.map(\.id)).count, SidecarAddons.all.count)
        XCTAssertEqual(Set(SidecarAddons.all.map(\.containerSuffix)).count, SidecarAddons.all.count)
    }

    func testEnabledFollowsTheInstanceFlags() {
        var site = makeSite()
        XCTAssertTrue(SidecarAddons.enabled(for: site).isEmpty)
        site.mailpitEnabled = true
        XCTAssertEqual(SidecarAddons.enabled(for: site).map(\.id), ["mailpit"])
        site.elasticsearchEnabled = true
        XCTAssertEqual(SidecarAddons.enabled(for: site).map(\.id), ["elasticsearch", "mailpit"])
    }

    // MARK: - Environment

    func testAssignmentsBuildValuesFromTheIP() {
        XCTAssertEqual(SidecarAddons.elasticsearch.assignments(ip: "10.0.0.5"),
                       ["ELASTICSEARCH_URL=http://10.0.0.5:9200", "EP_HOST=http://10.0.0.5:9200"])
        XCTAssertEqual(SidecarAddons.mailpit.assignments(ip: "10.0.0.6"), ["WPC_MAILPIT_HOST=10.0.0.6"])
    }

    func testWordPressContainerGetsSidecarEnvBeforeTheImage() throws {
        let site = makeSite()
        let env = SidecarAddons.elasticsearch.assignments(ip: "10.0.0.5") + SidecarAddons.mailpit.assignments(ip: "10.0.0.6")
        let args = SiteRecipe.runWordPressArgs(site, dbHost: "10.0.0.2", sidecarEnvironment: env)
        for assignment in env {
            let index = try XCTUnwrap(args.firstIndex(of: assignment))
            XCTAssertEqual(args[index - 1], "-e")
        }
        let imageIndex = try XCTUnwrap(args.lastIndex(of: site.imageTag))
        XCTAssertLessThan(try XCTUnwrap(args.firstIndex(of: env.last!)), imageIndex)
    }

    func testShellFlagsEscapeDoubleQuotedText() {
        let ref = SidecarRef(container: "wpc-x-demo", environment: [SidecarEnvVar("DEMO", prefix: "a\"$`\\", suffix: "")])
        XCTAssertEqual(WPCLIShim.sidecarEnvFlags([ref]),
                       [#"-e "DEMO=${SIDECAR_IP_1:+a\"\$\`\\${SIDECAR_IP_1}}""#])
    }

    // MARK: - Run args

    func testMailpitWaitsForItsPort() {
        var site = makeSite()
        site.mailpitEnabled = true
        XCTAssertNil(SidecarAddons.mailpit.runArgs(for: site))
        site.mailpitPort = 9001
        XCTAssertEqual(SidecarAddons.mailpit.runArgs(for: site), SiteRecipe.runMailpitArgs(site, webPort: 9001))
    }

    func testElasticsearchRunsItsRecipe() {
        let site = makeSite()
        XCTAssertEqual(SidecarAddons.elasticsearch.runArgs(for: site), SiteRecipe.runElasticsearchArgs(site))
        XCTAssertEqual(SidecarAddons.elasticsearch.dataFolders(for: site), [site.elasticsearchFolder])
    }

    func testSidecarIPErrorNamesTheSidecar() {
        XCTAssertEqual(LifecycleError.sidecarIPUnavailable(name: "Mailpit").description,
                       "Could not resolve the Mailpit container's IP address.")
    }

    // MARK: - Host ports and envs

    func testReservedHostPortsCoverSitesAndEnvs() {
        var site = makeSite()
        site.mailpitPort = 9001
        var envelope = StoreEnvelope(sites: [site])
        let env = WorktreeEnvService.reservedDescriptor(parent: withMailpit(site), repoRelPath: "wp-content/plugins/demo",
                                                        branch: "feature", port: 8890, into: &envelope)
        let ports = SidecarAddons.reservedHostPorts(sites: envelope.sites, envs: envelope.envs)
        XCTAssertTrue(ports.contains(9001))
        XCTAssertTrue(ports.contains(try XCTUnwrap(env.mailpitPort)))
    }

    func testEnvInheritsTheParentsSidecars() {
        var parent = makeSite()
        parent.elasticsearchEnabled = true
        let env = WorktreeEnvService.descriptor(parent: parent, repoRelPath: "wp-content/plugins/demo",
                                                branch: "feature", port: 8890)
        XCTAssertTrue(env.elasticsearchEnabled)
        XCTAssertFalse(env.mailpitEnabled)
    }

    func testEnvGetsItsOwnMailpitPort() throws {
        var envelope = StoreEnvelope(sites: [withMailpit(makeSite())])
        let env = WorktreeEnvService.reservedDescriptor(parent: withMailpit(makeSite()), repoRelPath: "wp-content/plugins/demo",
                                                        branch: "feature", port: 8890, into: &envelope)
        let port = try XCTUnwrap(env.mailpitPort)
        XCTAssertNotEqual(port, 8890)
        XCTAssertNotEqual(port, 9001)
    }

    // MARK: - Toggle

    func testEnablingMailpitReservesAPortAndWritesTheHandler() async throws {
        let (persistence, site) = try await makeStore()
        let result = try await persistence.setSidecar(SidecarAddons.mailpit, enabled: true, siteID: site.id)
        let updated = try XCTUnwrap(result?.site)
        XCTAssertTrue(updated.mailpitEnabled)
        let port = try XCTUnwrap(updated.mailpitPort)
        XCTAssertNotEqual(port, site.port)
        XCTAssertTrue(MailpitService.handler.isPresent(phpConfFolder: updated.phpConfFolder))
    }

    func testDisablingKeepsThePortAndRemovesTheHandler() async throws {
        let (persistence, site) = try await makeStore()
        let enabled = try await persistence.setSidecar(SidecarAddons.mailpit, enabled: true, siteID: site.id)
        let port = try XCTUnwrap(enabled?.site.mailpitPort)
        let result = try await persistence.setSidecar(SidecarAddons.mailpit, enabled: false, siteID: site.id)
        let disabled = try XCTUnwrap(result?.site)
        XCTAssertFalse(disabled.mailpitEnabled)
        XCTAssertEqual(disabled.mailpitPort, port)
        XCTAssertFalse(MailpitService.handler.isPresent(phpConfFolder: disabled.phpConfFolder))
    }

    func testEnablingElasticsearchReservesNoPort() async throws {
        let (persistence, site) = try await makeStore()
        let result = try await persistence.setSidecar(SidecarAddons.elasticsearch, enabled: true, siteID: site.id)
        let updated = try XCTUnwrap(result?.site)
        XCTAssertTrue(updated.elasticsearchEnabled)
        XCTAssertNil(updated.mailpitPort)
        XCTAssertTrue(ElasticsearchService.handler.isPresent(phpConfFolder: updated.phpConfFolder))
    }

    func testToggleForAMissingSiteReturnsNil() async throws {
        let (persistence, _) = try await makeStore()
        let result = try await persistence.setSidecar(SidecarAddons.mailpit, enabled: true, siteID: UUID())
        XCTAssertNil(result)
    }

    // MARK: - Helpers

    private func makeSite() -> Site {
        Site(name: "Example", slug: "example", path: tempRoot.appendingPathComponent("example", isDirectory: true),
             port: 8881, imageTag: SiteRecipe.defaultWordPressImage)
    }

    private func withMailpit(_ site: Site) -> Site {
        var site = site
        site.mailpitEnabled = true
        site.mailpitPort = 9001
        return site
    }

    private func makeStore() async throws -> (StorePersistence, Site) {
        let persistence = StorePersistence(fileURL: tempRoot.appendingPathComponent("sites.json"))
        let site = makeSite()
        _ = try await persistence.mutate { $0.sites.append(site) }
        return (persistence, site)
    }
}
