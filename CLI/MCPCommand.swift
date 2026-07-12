import ArgumentParser
import Foundation
import MCP
import WPContainerKit

// MARK: - `wp-container mcp --site <slug>`

/// Runs a stdio MCP server exposing agent tools for a site (PLAN.md §2d).
/// Mirrors 10up/localwp-agent-tools, adapted to the Apple `container` stack, and
/// adds our worktree-environment tools. Site-specific tools bind to `--site`;
/// `list_sites` and `worktree_*` may address other sites explicitly.
struct MCPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Run a stdio MCP server exposing WordPress agent tools for a site."
    )
    @Option(name: .long, help: "Site slug this server is scoped to.") var site: String

    func run() async throws {
        // IMPORTANT: stdout is reserved for the MCP JSON-RPC stream — never print.
        let runner = MCPServerRunner(scopedSlug: site)
        try await runner.run()
    }
}

// MARK: - Server

final class MCPServerRunner: @unchecked Sendable {
    let scopedSlug: String
    let ctx = CLIContext()

    init(scopedSlug: String) { self.scopedSlug = scopedSlug }

    func run() async throws {
        let server = Server(
            name: "wp-container",
            version: "0.1.0",
            capabilities: .init(tools: .init(listChanged: false))
        )

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: MCPTools.all)
        }

        let ctx = self.ctx
        let scoped = self.scopedSlug
        await server.withMethodHandler(CallTool.self) { params in
            await MCPToolDispatch.handle(params, ctx: ctx, scopedSlug: scoped)
        }

        let transport = StdioTransport()
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
    }
}

// MARK: - Result helpers

enum MCPResult {
    static func text(_ s: String, isError: Bool = false) -> CallTool.Result {
        .init(content: [.text(text: s, annotations: nil, _meta: nil)], isError: isError)
    }
    static func json(_ value: Any, isError: Bool = false) -> CallTool.Result {
        text(MCPJSON.string(value), isError: isError)
    }
    static func failure(_ message: String) -> CallTool.Result {
        text(message, isError: true)
    }
}

/// Minimal JSON stringifier for the loosely-typed dictionaries the tools return.
enum MCPJSON {
    static func string(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let s = String(data: data, encoding: .utf8) else {
            return "\(value)"
        }
        return s
    }
}
