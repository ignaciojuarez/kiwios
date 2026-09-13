import Foundation
import GRDB

enum JobKind: String, Codable, CaseIterable, Sendable {
    case check
    case action
}

enum JobStatus: String, Codable, CaseIterable, Sendable {
    case scheduled
    case queued
    case running
    case succeeded
    case warning
    case failed
    case timedOut = "timed-out"
    case canceled
    case interrupted
    case skipped

    var isTerminal: Bool {
        switch self {
        case .succeeded, .warning, .failed, .timedOut, .canceled, .interrupted, .skipped:
            true
        case .scheduled, .queued, .running:
            false
        }
    }
}

struct PluginRecord: Equatable, Sendable {
    let id: String
    var name: String
    var version: String
    var sourceRepository: String?
    var sourceCommit: String?
    var manifestDigest: String
    var contentDigest: String
    var enabled: Bool
    var lifecycleState: String
    var updatedAt: Date
}

struct ApprovalRecord: Equatable, Sendable {
    let pluginID: String
    let manifestDigest: String
    let contentDigest: String
    let disclosureDigest: String
    let sourceRepository: String?
    let sourceCommit: String?
    let approvedBy: String
    let approvedAt: Date
}

struct StoredJob: Equatable, Sendable {
    let id: UUID
    let pluginID: String
    let contributionID: String
    let kind: JobKind
    let resource: String
    var status: JobStatus
    let requestedBy: String
    let createdAt: Date
    var scheduledAt: Date?
    var startedAt: Date?
    var finishedAt: Date?
    var summary: String?
    var resultJSON: Data?
}

struct AuditEntry: Equatable, Sendable {
    let occurredAt: Date
    let actor: String
    let event: String
    let pluginID: String?
    let jobID: UUID?
}

struct LatestResultRecord: Equatable, Sendable {
    let pluginID: String
    let contributionID: String
    let kind: JobKind
    let jobID: UUID
    let status: JobStatus
    let summary: String?
    let resultJSON: Data?
    let updatedAt: Date
}

struct StoredPluginConfig: Equatable, Sendable {
    let json: Data
    let revision: Int64
}

struct ManagedHomebrewFormula: Equatable, Sendable {
    let name: String
    let receiptIdentity: String?
}

struct PendingPluginRemoval: Equatable, Sendable {
    let pluginID: String
    let secretFields: [String]
    let requestedBy: String
}

struct RuntimePersistenceSnapshot: Sendable {
    let jobs: [StoredJob]
    let latestResults: [LatestResultRecord]
}

enum PersistenceError: LocalizedError {
    case newerSchema
    case missingJob(UUID)
    case duplicateJob(UUID)
    case configConflict
    case invalidStoredValue(table: String, column: String, value: String)

    var errorDescription: String? {
        switch self {
        case .newerSchema: "This database was created by a newer KiwiOS version; open it with that version"
        case .missingJob(let id): "Job not found: \(id.uuidString)"
        case .duplicateJob(let id): "Job ID already exists: \(id.uuidString)"
        case .configConflict: "Configuration changed elsewhere; reload it and apply your changes again"
        case .invalidStoredValue(let table, let column, let value):
            "Invalid \(table).\(column) value in database: \(value)"
        }
    }
}

/// The durable KiwiOS state store. Callers should construct and access it away from the main actor.
actor PersistenceStore {
    private let database: DatabasePool

    init(url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        var configuration = Configuration()
        configuration.label = "KiwiOS"
        configuration.busyMode = .timeout(5)
        configuration.qos = .userInitiated
        let pool = try DatabasePool(path: url.path, configuration: configuration)
        let migrator = Self.migrator
        if try pool.read({ try migrator.hasBeenSuperseded($0) }) { throw PersistenceError.newerSchema }
        try migrator.migrate(pool)
        database = pool
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-durable-runtime") { db in
            try db.create(table: "plugins") { table in
                table.column("id", .text).primaryKey()
                table.column("name", .text).notNull()
                table.column("version", .text).notNull()
                table.column("sourceRepository", .text)
                table.column("sourceCommit", .text)
                table.column("manifestDigest", .text).notNull()
                table.column("contentDigest", .text).notNull()
                table.column("enabled", .boolean).notNull()
                table.column("lifecycleState", .text).notNull()
                table.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "approvals") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("pluginID", .text).notNull().references("plugins", onDelete: .cascade)
                table.column("manifestDigest", .text).notNull()
                table.column("contentDigest", .text).notNull()
                table.column("disclosureDigest", .text).notNull()
                table.column("sourceRepository", .text)
                table.column("sourceCommit", .text)
                table.column("approvedBy", .text).notNull()
                table.column("approvedAt", .datetime).notNull()
                table.uniqueKey(["pluginID", "manifestDigest", "contentDigest", "disclosureDigest"])
            }
            try db.create(table: "jobs") { table in
                table.column("id", .text).primaryKey()
                table.column("pluginID", .text).notNull()
                table.column("contributionID", .text).notNull()
                table.column("kind", .text).notNull()
                table.column("resource", .text).notNull()
                table.column("status", .text).notNull()
                table.column("requestedBy", .text).notNull()
                table.column("createdAt", .datetime).notNull()
                table.column("scheduledAt", .datetime)
                table.column("startedAt", .datetime)
                table.column("finishedAt", .datetime)
                table.column("summary", .text)
                table.column("logPath", .text)
                table.column("logTruncated", .boolean).notNull().defaults(to: false)
                table.column("resultJSON", .blob)
            }
            try db.create(index: "jobs_status_created", on: "jobs", columns: ["status", "createdAt"])
            try db.create(table: "auditEntries") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("occurredAt", .datetime).notNull()
                table.column("actor", .text).notNull()
                table.column("event", .text).notNull()
                table.column("pluginID", .text)
                table.column("jobID", .text)
                table.column("detailJSON", .blob)
            }
            try db.create(index: "audit_occurred", on: "auditEntries", columns: ["occurredAt"])
            try db.create(table: "latestResults") { table in
                table.column("pluginID", .text).notNull()
                table.column("contributionID", .text).notNull()
                table.column("kind", .text).notNull()
                table.column("jobID", .text).notNull()
                table.column("status", .text).notNull()
                table.column("summary", .text)
                table.column("resultJSON", .blob)
                table.column("updatedAt", .datetime).notNull()
                table.primaryKey(["pluginID", "contributionID", "kind"])
            }
            try db.create(table: "pluginConfig") { table in
                table.column("pluginID", .text).primaryKey()
                table.column("json", .blob).notNull()
                table.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "layouts") { table in
                table.column("key", .text).primaryKey()
                table.column("json", .blob).notNull()
                table.column("updatedAt", .datetime).notNull()
            }
        }
        migrator.registerMigration("v2-config-revisions-and-removals") { db in
            try db.alter(table: "pluginConfig") { $0.add(column: "revision", .integer).notNull().defaults(to: 0) }
            try db.create(table: "pendingPluginRemovals") { table in
                table.column("pluginID", .text).primaryKey().references("plugins", onDelete: .cascade)
                table.column("retainData", .boolean).notNull()
                table.column("secretFieldsJSON", .blob).notNull()
                table.column("requestedBy", .text).notNull()
                table.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "pluginConfigRecovery") { table in
                table.column("pluginID", .text).primaryKey()
                table.column("startedAt", .datetime).notNull()
            }
            try db.create(table: "pluginSecretFields") { table in
                table.column("pluginID", .text).notNull()
                table.column("field", .text).notNull()
                table.primaryKey(["pluginID", "field"])
            }
        }
        migrator.registerMigration("v3-managed-homebrew-formulae") { db in
            try db.create(table: "managedHomebrewFormulae") { table in
                table.column("name", .text).primaryKey()
                table.column("installedAt", .datetime).notNull()
            }
        }
        migrator.registerMigration("v4-compact-check-history") { db in
            try db.execute(sql: """
                DELETE FROM auditEntries
                WHERE jobID IN (SELECT id FROM jobs WHERE kind = 'check')
                """)
            try db.execute(sql: "DELETE FROM jobs WHERE kind = 'check'")
        }
        migrator.registerMigration("v5-homebrew-receipt-identity") { db in
            try db.alter(table: "managedHomebrewFormulae") {
                $0.add(column: "receiptIdentity", .text)
            }
        }
        return migrator
    }

    func journalMode() async throws -> String {
        try await database.read { db in
            try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? ""
        }
    }

    func upsertPlugin(_ record: PluginRecord) async throws {
        try await database.write { db in
            try db.execute(sql: """
                INSERT INTO plugins
                  (id, name, version, sourceRepository, sourceCommit, manifestDigest, contentDigest,
                   enabled, lifecycleState, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  name=excluded.name, version=excluded.version,
                  sourceRepository=excluded.sourceRepository, sourceCommit=excluded.sourceCommit,
                  manifestDigest=excluded.manifestDigest, contentDigest=excluded.contentDigest,
                  enabled=excluded.enabled, lifecycleState=excluded.lifecycleState,
                  updatedAt=excluded.updatedAt
                """, arguments: [record.id, record.name, record.version, record.sourceRepository,
                    record.sourceCommit, record.manifestDigest, record.contentDigest, record.enabled,
                    record.lifecycleState, record.updatedAt])
        }
    }

    func plugin(id: String) async throws -> PluginRecord? {
        try await database.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM plugins WHERE id = ?", arguments: [id]).map(Self.plugin)
        }
    }

    func plugins() async throws -> [PluginRecord] {
        try await database.read { db in try Row.fetchAll(db, sql: "SELECT * FROM plugins ORDER BY id").map(Self.plugin) }
    }

    func recordManagedHomebrewFormulae(
        _ formulae: [ManagedHomebrewFormula], installedAt: Date = Date()
    ) async throws {
        var unique: [String: ManagedHomebrewFormula] = [:]
        for formula in formulae { unique[formula.name] = formula }
        let records = unique.values.sorted(by: { $0.name < $1.name })
        try await database.write { db in
            for formula in records {
                try db.execute(sql: """
                    INSERT INTO managedHomebrewFormulae (name, installedAt, receiptIdentity) VALUES (?, ?, ?)
                    ON CONFLICT(name) DO UPDATE SET installedAt=excluded.installedAt,
                      receiptIdentity=excluded.receiptIdentity
                    """, arguments: [formula.name, installedAt, formula.receiptIdentity])
            }
        }
    }

    func managedHomebrewFormulae() async throws -> [ManagedHomebrewFormula] {
        try await database.read { db in
            try Row.fetchAll(db, sql: "SELECT name, receiptIdentity FROM managedHomebrewFormulae ORDER BY name").map {
                ManagedHomebrewFormula(name: $0["name"], receiptIdentity: $0["receiptIdentity"])
            }
        }
    }

    func forgetManagedHomebrewFormulae(_ formulae: [String]) async throws {
        try await database.write { db in
            for formula in Set(formulae) {
                try db.execute(sql: "DELETE FROM managedHomebrewFormulae WHERE name = ?", arguments: [formula])
            }
        }
    }

    func recordApproval(_ record: ApprovalRecord) async throws {
        try await database.write { db in
            try db.execute(sql: """
                INSERT INTO approvals
                  (pluginID, manifestDigest, contentDigest, disclosureDigest, sourceRepository,
                   sourceCommit, approvedBy, approvedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(pluginID, manifestDigest, contentDigest, disclosureDigest) DO UPDATE SET
                  sourceRepository=excluded.sourceRepository, sourceCommit=excluded.sourceCommit,
                  approvedBy=excluded.approvedBy, approvedAt=excluded.approvedAt
                """, arguments: [record.pluginID, record.manifestDigest, record.contentDigest,
                    record.disclosureDigest, record.sourceRepository, record.sourceCommit,
                    record.approvedBy, record.approvedAt])
        }
    }

    func hasApproval(
        pluginID: String,
        manifestDigest: String,
        contentDigest: String,
        disclosureDigest: String,
        sourceRepository: String? = nil,
        sourceCommit: String? = nil
    ) async throws -> Bool {
        try await database.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS(
                  SELECT 1 FROM approvals
                  WHERE pluginID = ? AND manifestDigest = ? AND contentDigest = ? AND disclosureDigest = ?
                    AND (? IS NULL OR sourceRepository = ?) AND (? IS NULL OR sourceCommit = ?)
                )
                """, arguments: [pluginID, manifestDigest, contentDigest, disclosureDigest,
                    sourceRepository, sourceRepository, sourceCommit, sourceCommit]) ?? false
        }
    }


    func storedConfig(pluginID: String) async throws -> StoredPluginConfig {
        try await database.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT json, revision FROM pluginConfig WHERE pluginID = ?", arguments: [pluginID]) else {
                return StoredPluginConfig(json: Data("{}".utf8), revision: 0)
            }
            return StoredPluginConfig(json: row["json"], revision: row["revision"])
        }
    }

    func setConfig(pluginID: String, json: Data, expectedRevision: Int64, updatedAt: Date = Date()) async throws -> Int64 {
        try await database.write { db in
            let current = try Int64.fetchOne(db,
                sql: "SELECT revision FROM pluginConfig WHERE pluginID = ?", arguments: [pluginID]) ?? 0
            guard current == expectedRevision, current >= 0, current < 9_007_199_254_740_991 else { throw PersistenceError.configConflict }
            let next = current + 1
            try db.execute(sql: """
                INSERT INTO pluginConfig (pluginID, json, updatedAt, revision) VALUES (?, ?, ?, ?)
                ON CONFLICT(pluginID) DO UPDATE SET json=excluded.json, updatedAt=excluded.updatedAt,
                  revision=excluded.revision
                """, arguments: [pluginID, json, updatedAt, next])
            try db.execute(sql: "DELETE FROM pluginConfigRecovery WHERE pluginID = ?", arguments: [pluginID])
            return next
        }
    }

    func beginConfigSecretUpdate(pluginID: String) async throws {
        try await database.write { db in
            try db.execute(sql: """
                INSERT INTO pluginConfigRecovery (pluginID, startedAt) VALUES (?, ?)
                ON CONFLICT(pluginID) DO UPDATE SET startedAt=excluded.startedAt
                """, arguments: [pluginID, Date()])
        }
    }

    func clearConfigSecretRecovery(pluginID: String) async throws {
        try await database.write { db in
            try db.execute(sql: "DELETE FROM pluginConfigRecovery WHERE pluginID = ?", arguments: [pluginID])
        }
    }

    func configSecretRecoveryNeeded(pluginID: String) async throws -> Bool {
        try await database.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM pluginConfigRecovery WHERE pluginID = ?)",
                arguments: [pluginID]) ?? false
        }
    }

    func recordPluginSecretFields(pluginID: String, fields: [String]) async throws {
        try await database.write { db in
            for field in fields {
                try db.execute(sql: "INSERT OR IGNORE INTO pluginSecretFields (pluginID, field) VALUES (?, ?)",
                    arguments: [pluginID, field])
            }
        }
    }

    func pluginSecretFields(pluginID: String) async throws -> [String] {
        try await database.read { db in
            try String.fetchAll(db, sql: "SELECT field FROM pluginSecretFields WHERE pluginID = ? ORDER BY field",
                arguments: [pluginID])
        }
    }

    func pluginSecretOwnerIDs() async throws -> [String] {
        try await database.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT pluginID FROM pluginSecretFields ORDER BY pluginID")
        }
    }

    func setLayout(key: String, json: Data, updatedAt: Date = Date()) async throws {
        try await database.write { db in
            try Self.setLayout(key: key, json: json, updatedAt: updatedAt, db: db)
        }
    }

    func setLayouts(_ values: [String: Data], updatedAt: Date = Date()) async throws {
        try await database.write { db in
            for (key, json) in values.sorted(by: { $0.key < $1.key }) {
                try Self.setLayout(key: key, json: json, updatedAt: updatedAt, db: db)
            }
        }
    }

    func layout(key: String) async throws -> Data? {
        try await database.read { db in
            try Data.fetchOne(db, sql: "SELECT json FROM layouts WHERE key = ?", arguments: [key])
        }
    }

    private static func setLayout(key: String, json: Data, updatedAt: Date, db: Database) throws {
        try db.execute(sql: """
            INSERT INTO layouts (key, json, updatedAt) VALUES (?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET json=excluded.json, updatedAt=excluded.updatedAt
            """, arguments: [key, json, updatedAt])
    }


    func admitJob(_ job: StoredJob, event: String) async throws {
        try await database.write { db in
            let exists = try Bool.fetchOne(db,
                sql: "SELECT EXISTS(SELECT 1 FROM jobs WHERE id = ?)",
                arguments: [job.id.uuidString]) ?? false
            guard !exists else { throw PersistenceError.duplicateJob(job.id) }
            try Self.insertNew(job, db: db)
            if job.kind == .action {
                try db.execute(sql: """
                    INSERT INTO auditEntries (occurredAt, actor, event, pluginID, jobID, detailJSON)
                    VALUES (?, ?, ?, ?, ?, NULL)
                    """, arguments: [job.createdAt, job.requestedBy, event, job.pluginID, job.id.uuidString])
            }
        }
    }

    func job(id: UUID) async throws -> StoredJob? {
        try await database.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM jobs WHERE id = ?", arguments: [id.uuidString]).map(Self.job)
        }
    }

    func updateJob(
        id: UUID,
        status: JobStatus,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        summary: String? = nil,
        resultJSON: Data? = nil
    ) async throws {
        try await database.write { db in
            guard var current = try Row.fetchOne(
                db, sql: "SELECT * FROM jobs WHERE id = ?", arguments: [id.uuidString]
            ).map(Self.job) else { throw PersistenceError.missingJob(id) }
            current.status = status
            if let startedAt { current.startedAt = startedAt }
            if let finishedAt { current.finishedAt = finishedAt }
            if let summary { current.summary = summary }
            if let resultJSON { current.resultJSON = resultJSON }
            try Self.insert(current, db: db)
        }
    }

    @discardableResult
    func recoverInterruptedJobs(at date: Date = Date()) async throws -> [StoredJob] {
        try await database.write { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM jobs WHERE status IN (?, ?, ?)
                """, arguments: [JobStatus.running.rawValue, JobStatus.queued.rawValue,
                    JobStatus.scheduled.rawValue])
            let jobs = try rows.map(Self.job)
            try db.execute(sql: """
                UPDATE jobs SET status = ?, finishedAt = ?, summary = ? WHERE status IN (?, ?, ?)
                """, arguments: [JobStatus.interrupted.rawValue, date,
                    "KiwiOS stopped before this job completed", JobStatus.running.rawValue,
                    JobStatus.queued.rawValue, JobStatus.scheduled.rawValue])
            for job in jobs {
                if job.kind == .action {
                    try db.execute(sql: """
                        INSERT INTO auditEntries (occurredAt, actor, event, pluginID, jobID, detailJSON)
                        VALUES (?, ?, ?, ?, ?, NULL)
                        """, arguments: [date, "system", "job.interrupted", job.pluginID, job.id.uuidString])
                }
            }
            let latestInterrupted = Dictionary(grouping: jobs) {
                "\($0.pluginID)\u{0}\($0.contributionID)\u{0}\($0.kind.rawValue)"
            }.compactMap { $0.value.max(by: { $0.createdAt < $1.createdAt }) }
            for job in latestInterrupted {
                try db.execute(sql: """
                    INSERT INTO latestResults
                      (pluginID, contributionID, kind, jobID, status, summary, resultJSON, updatedAt)
                    VALUES (?, ?, ?, ?, ?, ?, NULL, ?)
                    ON CONFLICT(pluginID, contributionID, kind) DO UPDATE SET
                      jobID=excluded.jobID, status=excluded.status, summary=excluded.summary,
                      resultJSON=NULL, updatedAt=excluded.updatedAt
                    WHERE latestResults.jobID = excluded.jobID OR latestResults.updatedAt <= ?
                    """, arguments: [job.pluginID, job.contributionID, job.kind.rawValue,
                        job.id.uuidString, JobStatus.interrupted.rawValue,
                        "KiwiOS stopped before this job completed", date, job.createdAt])
            }
            try db.execute(sql: "DELETE FROM jobs WHERE kind = 'check'")
            return jobs
        }
    }

    func finishJob(
        id: UUID,
        status: JobStatus,
        summary: String,
        resultJSON: Data?,
        actor: String = "system",
        at date: Date = Date()
    ) async throws {
        try await database.write { db in
            guard var job = try Row.fetchOne(
                db, sql: "SELECT * FROM jobs WHERE id = ?", arguments: [id.uuidString]
            ).map(Self.job) else { throw PersistenceError.missingJob(id) }
            guard !job.status.isTerminal else { return }
            job.status = status
            job.finishedAt = date
            job.summary = summary
            job.resultJSON = resultJSON
            if job.kind == .action { try Self.insert(job, db: db) }
            if status != .skipped {
                try db.execute(sql: """
                    INSERT INTO latestResults
                      (pluginID, contributionID, kind, jobID, status, summary, resultJSON, updatedAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(pluginID, contributionID, kind) DO UPDATE SET
                      jobID=excluded.jobID, status=excluded.status, summary=excluded.summary,
                      resultJSON=excluded.resultJSON, updatedAt=excluded.updatedAt
                    """, arguments: [job.pluginID, job.contributionID, job.kind.rawValue,
                        id.uuidString, status.rawValue, summary, resultJSON, date])
            }
            if job.kind == .check {
                try db.execute(sql: "DELETE FROM jobs WHERE id = ?", arguments: [id.uuidString])
            } else {
                try db.execute(sql: """
                    INSERT INTO auditEntries (occurredAt, actor, event, pluginID, jobID, detailJSON)
                    VALUES (?, ?, ?, ?, ?, NULL)
                    """, arguments: [date, actor, "job.\(status.rawValue)", job.pluginID, id.uuidString])
            }
        }
    }

    func appendAudit(_ entry: AuditEntry) async throws {
        try await database.write { db in
            try db.execute(sql: """
                INSERT INTO auditEntries (occurredAt, actor, event, pluginID, jobID, detailJSON)
                VALUES (?, ?, ?, ?, ?, NULL)
                """, arguments: [entry.occurredAt, entry.actor, entry.event, entry.pluginID,
                    entry.jobID?.uuidString])
        }
    }

    func runtimeSnapshot() async throws -> RuntimePersistenceSnapshot {
        try await database.read { db in
            let jobs = try Row.fetchAll(db, sql: """
                SELECT * FROM jobs
                WHERE status IN ('scheduled', 'queued', 'running')
                ORDER BY createdAt DESC
                """).map(Self.job)
            let latestResults = try Row.fetchAll(db,
                sql: "SELECT * FROM latestResults ORDER BY pluginID, contributionID, kind").map(Self.latestResult)
            return RuntimePersistenceSnapshot(jobs: jobs, latestResults: latestResults)
        }
    }

    private static func insert(_ job: StoredJob, db: Database) throws {
        try db.execute(sql: """
            INSERT INTO jobs
              (id, pluginID, contributionID, kind, resource, status, requestedBy, createdAt,
               scheduledAt, startedAt, finishedAt, summary, resultJSON)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              status=excluded.status, scheduledAt=excluded.scheduledAt, startedAt=excluded.startedAt,
              finishedAt=excluded.finishedAt, summary=excluded.summary, resultJSON=excluded.resultJSON
            """, arguments: [job.id.uuidString, job.pluginID, job.contributionID, job.kind.rawValue,
                job.resource, job.status.rawValue, job.requestedBy, job.createdAt, job.scheduledAt,
                job.startedAt, job.finishedAt, job.summary, job.resultJSON])
    }

    private static func insertNew(_ job: StoredJob, db: Database) throws {
        try db.execute(sql: """
            INSERT INTO jobs
              (id, pluginID, contributionID, kind, resource, status, requestedBy, createdAt,
               scheduledAt, startedAt, finishedAt, summary, resultJSON)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [job.id.uuidString, job.pluginID, job.contributionID, job.kind.rawValue,
                job.resource, job.status.rawValue, job.requestedBy, job.createdAt, job.scheduledAt,
                job.startedAt, job.finishedAt, job.summary, job.resultJSON])
    }

    private static func plugin(_ row: Row) throws -> PluginRecord {
        PluginRecord(id: row["id"], name: row["name"], version: row["version"],
            sourceRepository: row["sourceRepository"], sourceCommit: row["sourceCommit"],
            manifestDigest: row["manifestDigest"], contentDigest: row["contentDigest"],
            enabled: row["enabled"], lifecycleState: row["lifecycleState"], updatedAt: row["updatedAt"])
    }

    private static func job(_ row: Row) throws -> StoredJob {
        let rawID: String = row["id"], rawKind: String = row["kind"], rawStatus: String = row["status"]
        guard let id = UUID(uuidString: rawID) else {
            throw PersistenceError.invalidStoredValue(table: "jobs", column: "id", value: rawID)
        }
        guard let kind = JobKind(rawValue: rawKind) else {
            throw PersistenceError.invalidStoredValue(table: "jobs", column: "kind", value: rawKind)
        }
        guard let status = JobStatus(rawValue: rawStatus) else {
            throw PersistenceError.invalidStoredValue(table: "jobs", column: "status", value: rawStatus)
        }
        return StoredJob(id: id, pluginID: row["pluginID"], contributionID: row["contributionID"],
            kind: kind, resource: row["resource"], status: status, requestedBy: row["requestedBy"],
            createdAt: row["createdAt"], scheduledAt: row["scheduledAt"], startedAt: row["startedAt"],
            finishedAt: row["finishedAt"], summary: row["summary"], resultJSON: row["resultJSON"])
    }

    private static func latestResult(_ row: Row) throws -> LatestResultRecord {
        let rawID: String = row["jobID"], rawKind: String = row["kind"], rawStatus: String = row["status"]
        guard let id = UUID(uuidString: rawID) else {
            throw PersistenceError.invalidStoredValue(table: "latestResults", column: "jobID", value: rawID)
        }
        guard let kind = JobKind(rawValue: rawKind) else {
            throw PersistenceError.invalidStoredValue(table: "latestResults", column: "kind", value: rawKind)
        }
        guard let status = JobStatus(rawValue: rawStatus) else {
            throw PersistenceError.invalidStoredValue(table: "latestResults", column: "status", value: rawStatus)
        }
        return LatestResultRecord(pluginID: row["pluginID"], contributionID: row["contributionID"],
            kind: kind, jobID: id, status: status, summary: row["summary"],
            resultJSON: row["resultJSON"], updatedAt: row["updatedAt"])
    }

    func activateInstalledPlugin(_ record: PluginRecord, approval: ApprovalRecord) async throws {
        try await database.write { db in
            try db.execute(sql: """
                INSERT INTO plugins
                  (id, name, version, sourceRepository, sourceCommit, manifestDigest, contentDigest,
                   enabled, lifecycleState, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  name=excluded.name, version=excluded.version, sourceRepository=excluded.sourceRepository,
                  sourceCommit=excluded.sourceCommit, manifestDigest=excluded.manifestDigest,
                  contentDigest=excluded.contentDigest, enabled=excluded.enabled,
                  lifecycleState=excluded.lifecycleState, updatedAt=excluded.updatedAt
                """, arguments: [record.id, record.name, record.version, record.sourceRepository,
                    record.sourceCommit, record.manifestDigest, record.contentDigest, record.enabled,
                    record.lifecycleState, record.updatedAt])
            try db.execute(sql: """
                INSERT INTO approvals
                  (pluginID, manifestDigest, contentDigest, disclosureDigest, sourceRepository,
                   sourceCommit, approvedBy, approvedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(pluginID, manifestDigest, contentDigest, disclosureDigest) DO UPDATE SET
                  sourceRepository=excluded.sourceRepository, sourceCommit=excluded.sourceCommit,
                  approvedBy=excluded.approvedBy, approvedAt=excluded.approvedAt
                """, arguments: [approval.pluginID, approval.manifestDigest, approval.contentDigest,
                    approval.disclosureDigest, approval.sourceRepository, approval.sourceCommit,
                    approval.approvedBy, approval.approvedAt])
            try db.execute(sql: """
                INSERT INTO auditEntries (occurredAt, actor, event, pluginID, jobID, detailJSON)
                VALUES (?, ?, 'plugin.revision-approved', ?, NULL, NULL)
                """, arguments: [Date(), approval.approvedBy, record.id])
        }
    }

    func beginPluginRemoval(id: String, secretFields: [String], requestedBy: String) async throws {
        let encodedFields = try JSONEncoder().encode(secretFields.sorted())
        try await database.write { db in
            if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM pendingPluginRemovals WHERE pluginID = ?)",
                arguments: [id]) == true { return }
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM plugins WHERE id = ?)",
                arguments: [id]) == true else { return }
            try db.execute(sql: "UPDATE plugins SET enabled = 0, lifecycleState = 'removing', updatedAt = ? WHERE id = ?",
                arguments: [Date(), id])
            try db.execute(sql: """
                INSERT INTO pendingPluginRemovals
                  (pluginID, retainData, secretFieldsJSON, requestedBy, createdAt)
                VALUES (?, 0, ?, ?, ?)
                """, arguments: [id, encodedFields, requestedBy, Date()])
            try db.execute(sql: """
                INSERT INTO auditEntries (occurredAt, actor, event, pluginID, jobID, detailJSON)
                VALUES (?, ?, 'plugin.removal-started', ?, NULL, NULL)
                """, arguments: [Date(), requestedBy, id])
        }
    }

    func pendingPluginRemovals() async throws -> [PendingPluginRemoval] {
        try await database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM pendingPluginRemovals ORDER BY createdAt").map { row in
                let data: Data = row["secretFieldsJSON"]
                return PendingPluginRemoval(pluginID: row["pluginID"],
                    secretFields: try JSONDecoder().decode([String].self, from: data), requestedBy: row["requestedBy"])
            }
        }
    }

    func finishPluginRemoval(_ removal: PendingPluginRemoval) async throws {
        try await database.write { db in
            try db.execute(sql: """
                DELETE FROM auditEntries
                WHERE pluginID = ? OR jobID IN (SELECT id FROM jobs WHERE pluginID = ?)
                """, arguments: [removal.pluginID, removal.pluginID])
            try db.execute(sql: "DELETE FROM latestResults WHERE pluginID = ?", arguments: [removal.pluginID])
            try db.execute(sql: "DELETE FROM jobs WHERE pluginID = ?", arguments: [removal.pluginID])
            try db.execute(sql: "DELETE FROM pluginConfig WHERE pluginID = ?", arguments: [removal.pluginID])
            try db.execute(sql: "DELETE FROM pluginConfigRecovery WHERE pluginID = ?", arguments: [removal.pluginID])
            try db.execute(sql: "DELETE FROM pluginSecretFields WHERE pluginID = ?", arguments: [removal.pluginID])
            try db.execute(sql: "DELETE FROM plugins WHERE id = ?", arguments: [removal.pluginID])
        }
    }
}
