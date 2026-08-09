import Foundation

/// A disposable clone of a parent site bound to a git worktree of one repo
/// inside it. See PLAN.md §2b.
public struct WorktreeEnv: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public var parentSiteID: UUID
    /// Parent site slug (used for the `dev.wpcontainer.site` reconciliation label).
    public var parentSlug: String
    /// `<site-slug>-wt-<branch-slug>` — basis for container names and the
    /// `dev.wpcontainer.env` label.
    public var envSlug: String
    /// Repo path relative to `wordpress/`, e.g. `wp-content/plugins/my-plugin`.
    public var repoRelPath: String
    public var branch: String
    /// Git worktree checkout: `<site>/.worktrees/<branch-slug>/`.
    public var worktreePath: URL
    /// Cloned site+db root: `<site>/.envs/<branch-slug>/`.
    public var envPath: URL
    public var port: Int
    public var imageTag: String
    public var createdAt: Date
    public var provisioned: Bool
    /// Inherited from the parent site at creation (PLAN.md §2c): the env runs its
    /// own Xdebug image / Elasticsearch sidecar when the parent has them enabled.
    public var xdebugEnabled: Bool
    public var elasticsearchEnabled: Bool
    /// Inherited from the parent site (issue #10): the env runs its own Mailpit
    /// container when the parent has it enabled, catching its mail separately.
    public var mailpitEnabled: Bool
    /// The env's own auto-allocated Mailpit web-UI port (issue #10).
    public var mailpitPort: Int?
    /// Inherited per-site resource caps (issue #11); nil = `container` defaults.
    public var cpuLimit: Int?
    public var memoryLimitMB: Int?
    /// Optional per-env auto-stop-when-idle timeout in minutes (issue #16).
    /// nil = the built-in default (`IdlePolicy.defaultEnvMinutes`, 180 minutes —
    /// envs are the many-of-them case this exists for, and the proxy owns their
    /// port so every request to them is observed); 0 = explicitly off;
    /// > 0 = stop after that many idle minutes. Deliberately NOT inherited from
    /// the parent site, whose own default is off. A freshly created env is
    /// additionally exempt from this timeout for its first
    /// `IdlePolicy.envCreationGraceMinutes`, measured from `createdAt`.
    public var idleStopMinutes: Int?
    /// Last time any process observed deliberate use of this env (issue #16) —
    /// wp-cli, an MCP tool call, a magic-login link, or an explicit start. This is
    /// what makes idle tracking usable for an AGENT-driven env, whose whole
    /// workflow can happen over wp-cli and MCP without a single proxied request.
    public var lastActivityAt: Date?
    /// Whether this env lives as an extra SCHEMA on the parent site's MariaDB
    /// container instead of running one of its own (issue #17). The default for
    /// newly created envs; `--isolated-db` opts out. Records written before
    /// issue #17 decode as `false`, so they keep their dedicated container.
    ///
    /// INVARIANT: only ever true together with a non-nil `databaseSchema` — both
    /// the memberwise init and `init(from:)` normalize it, so the derived
    /// `databaseName` can never silently fall back to the parent's `wordpress`
    /// schema (the one genuinely corrupting failure mode here).
    public private(set) var sharedDatabase: Bool
    /// The persisted `wpc_*` schema this env owns on the parent's server, or nil
    /// when the env has its own DB container. PERSISTED, never recomputed from
    /// the slug at use time (issue #17).
    public private(set) var databaseSchema: String?

    /// Runtime-derived; NOT persisted.
    public var status: SiteStatus = .stopped

    private enum CodingKeys: String, CodingKey {
        case id, parentSiteID, parentSlug, envSlug, repoRelPath, branch,
             worktreePath, envPath, port, imageTag, createdAt, provisioned,
             xdebugEnabled, elasticsearchEnabled, cpuLimit, memoryLimitMB,
             idleStopMinutes, lastActivityAt,
             mailpitEnabled, mailpitPort, sharedDatabase, databaseSchema
    }

    public init(
        id: UUID = UUID(),
        parentSiteID: UUID,
        parentSlug: String,
        envSlug: String,
        repoRelPath: String,
        branch: String,
        worktreePath: URL,
        envPath: URL,
        port: Int,
        imageTag: String,
        createdAt: Date = Date(),
        provisioned: Bool = false,
        xdebugEnabled: Bool = false,
        elasticsearchEnabled: Bool = false,
        mailpitEnabled: Bool = false,
        mailpitPort: Int? = nil,
        cpuLimit: Int? = nil,
        memoryLimitMB: Int? = nil,
        idleStopMinutes: Int? = nil,
        lastActivityAt: Date? = nil,
        sharedDatabase: Bool = false,
        databaseSchema: String? = nil,
        status: SiteStatus = .stopped
    ) {
        self.id = id
        self.parentSiteID = parentSiteID
        self.parentSlug = parentSlug
        self.envSlug = envSlug
        self.repoRelPath = repoRelPath
        self.branch = branch
        self.worktreePath = worktreePath
        self.envPath = envPath
        self.port = port
        self.imageTag = imageTag
        self.createdAt = createdAt
        self.provisioned = provisioned
        self.xdebugEnabled = xdebugEnabled
        self.elasticsearchEnabled = elasticsearchEnabled
        self.mailpitEnabled = mailpitEnabled
        self.mailpitPort = mailpitPort
        self.cpuLimit = cpuLimit
        self.memoryLimitMB = memoryLimitMB
        self.idleStopMinutes = idleStopMinutes
        self.lastActivityAt = lastActivityAt
        // Enforce the shared-DB invariant at the only two entry points.
        self.databaseSchema = databaseSchema
        self.sharedDatabase = sharedDatabase && databaseSchema != nil
        self.status = status
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.parentSiteID = try c.decode(UUID.self, forKey: .parentSiteID)
        self.parentSlug = try c.decode(String.self, forKey: .parentSlug)
        self.envSlug = try c.decode(String.self, forKey: .envSlug)
        self.repoRelPath = try c.decode(String.self, forKey: .repoRelPath)
        self.branch = try c.decode(String.self, forKey: .branch)
        self.worktreePath = try c.decode(URL.self, forKey: .worktreePath)
        self.envPath = try c.decode(URL.self, forKey: .envPath)
        self.port = try c.decode(Int.self, forKey: .port)
        self.imageTag = try c.decode(String.self, forKey: .imageTag)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.provisioned = (try? c.decode(Bool.self, forKey: .provisioned)) ?? false
        // Absent in envs written before §2c.
        self.xdebugEnabled = (try? c.decode(Bool.self, forKey: .xdebugEnabled)) ?? false
        self.elasticsearchEnabled = (try? c.decode(Bool.self, forKey: .elasticsearchEnabled)) ?? false
        // Absent in envs written before issue #10.
        self.mailpitEnabled = (try? c.decode(Bool.self, forKey: .mailpitEnabled)) ?? false
        self.mailpitPort = try? c.decodeIfPresent(Int.self, forKey: .mailpitPort)
        // Absent in envs written before issue #11.
        self.cpuLimit = try? c.decodeIfPresent(Int.self, forKey: .cpuLimit)
        self.memoryLimitMB = try? c.decodeIfPresent(Int.self, forKey: .memoryLimitMB)
        // Absent in envs written before issue #16 — nil means "use the default",
        // which for an env is 180 minutes (see `IdlePolicy`). Safe for an existing
        // record: an env's advertised URL now runs through the proxy, so the idle
        // clock sees browser traffic to it, and the next request wakes it.
        self.idleStopMinutes = try? c.decodeIfPresent(Int.self, forKey: .idleStopMinutes)
        self.lastActivityAt = try? c.decodeIfPresent(Date.self, forKey: .lastActivityAt)
        // Absent in envs written before issue #17 — they keep their own DB
        // container, so the default MUST be false/nil.
        let schema = try? c.decodeIfPresent(String.self, forKey: .databaseSchema)
        self.databaseSchema = schema
        self.sharedDatabase = ((try? c.decode(Bool.self, forKey: .sharedDatabase)) ?? false) && schema != nil
    }

    public var wordpressFolder: URL { envPath.appendingPathComponent("wordpress", isDirectory: true) }
    /// Where an ISOLATED env's mariadb data directory lives. A shared-database
    /// env never materializes this folder (issue #17) — `SiteFolders.ensure`
    /// skips it, and `SiteRecipe.runDatabaseArgs` is never called for the env.
    public var databaseFolder: URL { envPath.appendingPathComponent("database", isDirectory: true) }

    /// Compose the env slug from a parent slug + branch slug.
    public static func makeSlug(parentSlug: String, branch: String) -> String {
        "\(parentSlug)-wt-\(Slug.make(branch))"
    }

    /// Bind this env to `schema` on its parent site's DB server (issue #17), the
    /// only way to flip `sharedDatabase` on. Called once by
    /// `WorktreeEnvService.create` BEFORE the containers start, so the record the
    /// caller persists already carries the chosen schema. Refuses a name that
    /// isn't one of ours, keeping the invariant unbreakable from the outside.
    public mutating func adoptSharedDatabase(schema: String) {
        guard Self.isManagedSchemaName(schema) else { return }
        databaseSchema = schema
        sharedDatabase = true
    }

    // MARK: - Shared-database schema naming (issue #17)

    /// MySQL's identifier length cap.
    public static let maxSchemaNameLength = 64
    /// Prefix every managed env schema carries. The `DROP DATABASE` guard keys
    /// off it, so it must never be empty.
    public static let schemaPrefix = "wpc_"

    /// The schema name for a shared-database env: `wpc_` + the env slug with
    /// dashes turned into underscores. When that exceeds MySQL's 64-char
    /// identifier cap it is truncated and suffixed with `_<6-hex>`, a STABLE
    /// hash of the full env slug, so two long slugs sharing a prefix can't
    /// collide. Result is always ≤ 64 chars.
    ///
    /// Call this ONCE, at creation, and persist the result (`databaseSchema`) —
    /// never recompute it from the slug at use time.
    public static func schemaName(forEnvSlug slug: String) -> String {
        let sanitized = String(slug.map { ch in
            (ch.isASCII && (ch.isLetter || ch.isNumber)) ? ch : Character("_")
        })
        let full = schemaPrefix + sanitized
        guard full.count > maxSchemaNameLength else { return full }
        // Built by hand rather than `String(format: "%06x", …)`: `%x` reads only
        // 32 bits off the vararg list, so feeding it a UInt64 is a trap.
        let digits = String(stableHash(slug) & 0xFF_FFFF, radix: 16)
        let hash = String(repeating: "0", count: max(0, 6 - digits.count)) + digits
        let keep = maxSchemaNameLength - hash.count - 1 // "_" + hash
        return String(full.prefix(keep)) + "_" + hash
    }

    /// Whether a name is one of OUR managed env schemas — the blast-radius guard
    /// in front of every `DROP DATABASE` (never `wordpress`, never a sibling
    /// site's anything). Prefix + charset + length, all three.
    public static func isManagedSchemaName(_ name: String) -> Bool {
        guard name.hasPrefix(schemaPrefix), name.count > schemaPrefix.count,
              name.count <= maxSchemaNameLength else { return false }
        return name.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "_" }
    }

    /// FNV-1a (64-bit). Deterministic across processes and releases — Swift's
    /// `Hasher` is per-process seeded and therefore unusable for a name that
    /// gets written to disk.
    static func stableHash(_ s: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}

extension WorktreeEnv: RunnableInstance {
    public var instanceID: UUID { id }
    public var containerSlug: String { envSlug }
    public var siteSlug: String { parentSlug }
    public var envLabel: String? { envSlug }
    public var displayName: String { branch }
    public var isProvisioned: Bool { provisioned }
    /// A shared-database env talks to the PARENT site's DB container (issue #17).
    public var dbContainerName: String {
        sharedDatabase ? "wpc-\(parentSlug)-db" : "wpc-\(envSlug)-db"
    }
    /// The env's own schema on the shared server, or the plain `wordpress`
    /// schema on its own server. The `sharedDatabase`/`databaseSchema` invariant
    /// makes the `??` unreachable.
    public var databaseName: String {
        sharedDatabase ? (databaseSchema ?? SiteRecipe.dbName) : SiteRecipe.dbName
    }
    /// A shared-database env must never create, stop or delete the container it
    /// borrows from its parent.
    public var ownsDatabaseContainer: Bool { !sharedDatabase }
    /// The worktree checkout shadows the primary checkout inside the env container.
    /// Mount construction is isolated in `SiteRecipe` so integration can adjust it.
    public var extraMounts: [Mount] {
        [SiteRecipe.shadowMount(worktreePath: worktreePath, repoRelPath: repoRelPath)]
    }
    /// An env's wp container does NOT publish a host port (issue #16
    /// follow-through). The reverse proxy binds `127.0.0.1:<port>` for it and
    /// relays to the container's vmnet IP, which is what makes the env's ONE
    /// advertised URL both idle-trackable and wakeable. See `publishesPort`.
    public var publishesPort: Bool { false }
}
