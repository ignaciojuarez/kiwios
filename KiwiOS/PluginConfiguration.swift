import Foundation
import Darwin

struct PluginConfigurationSnapshot: Equatable, Sendable {
    let values: [String: JSONValue]
    let revision: Int64
}

enum PluginConfigurationError: LocalizedError {
    case compensationFailed(String)

    var errorDescription: String? {
        switch self {
        case .compensationFailed(let detail):
            "Configuration could not be saved and Keychain rollback also failed: \(detail). Review the secret fields in attended setup"
        }
    }
}

actor PluginConfiguration {
    let store: PersistenceStore
    let dataRoot: URL
    private let secrets = SecretStore()
    private var lockedPlugins = Set<String>()
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    init(store: PersistenceStore, dataRoot: URL) {
        self.store = store
        self.dataRoot = dataRoot
    }

    func values(for plugin: LoadedPlugin) async throws -> [String: JSONValue] {
        (try await snapshot(for: plugin)).values
    }

    func snapshot(for plugin: LoadedPlugin) async throws -> PluginConfigurationSnapshot {
        let stored = try await store.storedConfig(pluginID: plugin.manifest.id)
        return PluginConfigurationSnapshot(
            values: try JSONDecoder().decode([String: JSONValue].self, from: stored.json),
            revision: stored.revision
        )
    }

    @discardableResult
    func save(
        _ patch: [String: JSONValue], expectedRevision: Int64,
        for plugin: LoadedPlugin, mode: OperationMode
    ) async throws -> PluginConfigurationSnapshot {
        await acquire(plugin.manifest.id)
        defer { release(plugin.manifest.id) }
        try Task.checkCancellation()
        guard let schema = plugin.configSchema else { throw PolicyError.blocked("This plugin has no config schema") }
        if let unknown = patch.keys.filter({ schema.properties[$0] == nil }).sorted().first {
            throw PluginLoadError.invalidConfigSchema("unknown config value \(unknown)")
        }
        let changesSecret = patch.keys.contains { schema.properties[$0]?.writeOnly == true }
        if changesSecret, case .remote = mode {
            throw PolicyError.blocked("Secret changes require attended setup mode")
        }
        if changesSecret {
            try await store.recordPluginSecretFields(pluginID: plugin.manifest.id,
                fields: schema.properties.compactMap { $0.value.writeOnly ? $0.key : nil })
        }
        let recoveryNeeded = try await store.configSecretRecoveryNeeded(pluginID: plugin.manifest.id)
        if recoveryNeeded {
            let secretFields = Set(schema.properties.compactMap { $0.value.writeOnly ? $0.key : nil })
            guard mode == .setup, changesSecret, !secretFields.isEmpty, secretFields.isSubset(of: Set(patch.keys)) else {
                throw PolicyError.blocked("A previous secret save was interrupted; review and resave every secret field in attended setup")
            }
        }
        let current = try await snapshot(for: plugin)
        guard current.revision == expectedRevision else { throw PersistenceError.configConflict }
        var merged = current.values.filter { schema.properties[$0.key] != nil }
        for (key, value) in patch { merged[key] = value }
        for (key, field) in schema.properties {
            if merged[key] == nil, field.writeOnly,
               let existing = try secrets.readIfPresent(Self.secretName(plugin.manifest.id, key)) {
                merged[key] = try JSONDecoder().decode(JSONValue.self, from: Data(existing.utf8))
            }
            if merged[key] == nil { merged[key] = field.defaultValue }
        }
        let validated = try schema.validated(values: merged)
        // Validate the complete form before writing either public values or Keychain items.
        var backups: [(name: String, value: String?)] = []
        do {
            if changesSecret { try await store.beginConfigSecretUpdate(pluginID: plugin.manifest.id) }
            for (key, field) in schema.properties.sorted(by: { $0.key < $1.key }) where field.writeOnly {
                if let value = patch[key] {
                    let name = Self.secretName(plugin.manifest.id, key)
                    backups.append((name, try secrets.readIfPresent(name)))
                    let encoded = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
                    try secrets.write(encoded, named: name, mode: mode)
                }
            }
            let publicValues = validated.filter { schema.properties[$0.key]?.writeOnly != true }
            let revision = try await store.setConfig(pluginID: plugin.manifest.id,
                json: JSONEncoder().encode(publicValues), expectedRevision: expectedRevision)
            // SQLite is authoritative. This derived launch file is repaired by prepare if this write fails.
            try? writeConfig(publicValues, pluginID: plugin.manifest.id)
            return PluginConfigurationSnapshot(values: publicValues, revision: revision)
        } catch {
            do {
                for backup in backups.reversed() {
                    if let value = backup.value { try secrets.write(value, named: backup.name, mode: .setup) }
                    else { try secrets.delete(backup.name, mode: .setup) }
                }
            } catch let rollbackError {
                throw PluginConfigurationError.compensationFailed(rollbackError.localizedDescription)
            }
            if changesSecret, !recoveryNeeded {
                try? await store.clearConfigSecretRecovery(pluginID: plugin.manifest.id)
            }
            throw error
        }
    }

    /// Called immediately before launch; Keychain is read without authentication UI.
    func prepare(_ plugin: LoadedPlugin) async throws -> [String: String] {
        await acquire(plugin.manifest.id)
        defer { release(plugin.manifest.id) }
        try Task.checkCancellation()
        if try await store.configSecretRecoveryNeeded(pluginID: plugin.manifest.id) {
            throw PolicyError.blocked("A previous secret configuration save was interrupted; review and save the secret fields again in attended setup")
        }
        var values = try await values(for: plugin)
        var delivered: [String: String] = [:]
        for name in plugin.manifest.permissions.secrets { delivered[name] = try secrets.read(name) }
        if let schema = plugin.configSchema {
            for (key, field) in schema.properties {
                if field.writeOnly {
                    let name = Self.secretName(plugin.manifest.id, key)
                    if let raw = try? secrets.read(name) {
                        let value = try JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))
                        values[key] = value
                        delivered[name] = try stableSecretText(value)
                    } else if field.required {
                        throw PolicyError.blocked("Save the required secret field \(field.title ?? key) in attended setup")
                    }
                } else if values[key] == nil {
                    values[key] = field.defaultValue
                }
            }
            values = try schema.validated(values: values)
            values = values.filter { schema.properties[$0.key]?.writeOnly != true }
        }
        try writeConfig(values, pluginID: plugin.manifest.id)
        return delivered
    }

    func saveNamedSecret(_ value: String, name: String, mode: OperationMode) throws {
        try secrets.write(value, named: name, mode: mode)
    }

    func deleteWriteOnlySecrets(pluginID: String, fields: [String], mode: OperationMode = .setup) async throws {
        await acquire(pluginID)
        defer { release(pluginID) }
        try Task.checkCancellation()
        _ = fields // Persisted field ownership remains part of the durable removal record.
        let installedIDs = Set((try await store.plugins()).map(\.id))
        let retainedOwnerIDs = Set(try await store.pluginSecretOwnerIDs())
        try secrets.deleteConfigSecrets(pluginID: pluginID,
            knownPluginIDs: installedIDs.union(retainedOwnerIDs), mode: mode)
    }

    private func acquire(_ pluginID: String) async {
        if lockedPlugins.insert(pluginID).inserted { return }
        await withCheckedContinuation { waiters[pluginID, default: []].append($0) }
    }

    private func release(_ pluginID: String) {
        if var queued = waiters[pluginID], !queued.isEmpty {
            let next = queued.removeFirst()
            waiters[pluginID] = queued.isEmpty ? nil : queued
            next.resume()
        } else { lockedPlugins.remove(pluginID) }
    }

    private func writeConfig(_ values: [String: JSONValue], pluginID: String) throws {
        let directory = dataRoot.appendingPathComponent(pluginID, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("config.json")
        let temporary = directory.appendingPathComponent(".config-\(UUID().uuidString).tmp")
        let data = try JSONEncoder().encode(values)
        guard FileManager.default.createFile(
            atPath: temporary.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else { throw CocoaError(.fileWriteUnknown) }
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard Darwin.rename(temporary.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func stableSecretText(_ value: JSONValue) throws -> String {
        switch value {
        case .string(let value): return value
        case .number, .bool:
            return String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        case .null, .array, .object:
            throw PolicyError.blocked("A config secret must be a string, number, integer, or boolean")
        }
    }

    static func secretName(_ pluginID: String, _ field: String) -> String { "\(pluginID).config.\(field)" }
}

extension JSONValue {
    var displayText: String {
        switch self {
        case .string(let value): value
        case .number(let value): String(value)
        case .bool(let value): value ? "true" : "false"
        case .null: "—"
        case .array, .object: "Unsupported value"
        }
    }
}

extension PluginConfiguration {
    /// Checks an update without writing files, moving values, or executing plugin code.
    func validateForUpdate(_ plugin: LoadedPlugin) async throws {
        await acquire(plugin.manifest.id)
        defer { release(plugin.manifest.id) }
        try Task.checkCancellation()
        if try await store.configSecretRecoveryNeeded(pluginID: plugin.manifest.id) {
            throw PolicyError.blocked("Repair the interrupted secret save before updating this plugin")
        }
        var current = try await values(for: plugin)
        guard let schema = plugin.configSchema else {
            guard current.isEmpty else { throw PolicyError.blocked("The new revision removes configuration; export and clear existing values before switching") }
            return
        }
        for (name, field) in schema.properties where field.writeOnly {
            if let existing = try? secrets.read(Self.secretName(plugin.manifest.id, name)) {
                current[name] = try JSONDecoder().decode(JSONValue.self, from: Data(existing.utf8))
            }
        }
        _ = try schema.validated(values: current)
    }
}
