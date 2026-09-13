import Foundation
import Combine

struct PluginState: Identifiable, Equatable, Sendable {
    var id: String { manifest.id }
    let manifest: PluginManifest
    var message = "Review source and disclosures before adding"
    var lifecycle: PluginLifecycle = .installed
    var results: [String: WatchRunResult] = [:]
    var resultDates: [String: Date] = [:]
    var liveResults: [String: WatchLiveSnapshot] = [:]
}

struct HomeLayout: Codable, Sendable {
    var widgets: [String] = []
    var hiddenWidgets: Set<String> = []
    var wideWidgets: Set<String> = []
    var sidebar: [String] = []
    var initialized = false
}

@MainActor
final class HubRuntime: ObservableObject {
    @Published var plugins: [PluginState] = []
    @Published var jobs: [StoredJob] = []
    @Published var discoveryError: String?
    @Published var operationError: String?
    @Published var mode: OperationMode = .setup
    @Published var doctorFindings: [DoctorFinding] = []
    @Published var layout = HomeLayout()
    @Published var developmentDirectory: URL?
    @Published var pendingReview: PluginReview?
    @Published var pendingConfirmation: ActionConfirmation?
    @Published var native = NativeToolsState()
    @Published var remote = RemoteAccessState()
    @Published var marketplaceBusy = false
    @Published var marketplaceResults: [PluginCatalogResult] = []
    @Published var curatedEntries: [CuratedPluginEntry] = []
    @Published var pendingInstallation: InstallationReview?
    @Published var pendingRemoval: PluginRemovalReview?

    let explicitRoot: URL?
    let storageRoot: URL
    let runner: CommandRunner
    var store: PersistenceStore?
    var configuration: PluginConfiguration?
    var queue: JobQueue?
    var loaded: [String: LoadedPlugin] = [:]
    var fingerprints: [String: PluginFingerprint] = [:]
    var dependencyIssues: [String: [PluginDependencyIssue]] = [:]
    var schedules: [String: [UUID]] = [:]
    var liveOutput: [UUID: (stdout: Data, stderr: Data)] = [:]
    var startup: Task<Void, Never>?
    var refreshTask: Task<Void, Never>?
    var doctorTask: Task<Void, Never>?
    var remoteRetryTask: Task<Void, Never>?
    var doctorRevision = 0
    var modeTransitioning = false
    var policyOperations = 0
    var pluginTransitions = Set<String>()
    var pendingRemovalIDs = Set<String>()
    var lifecycleVersions: [String: Int] = [:]
    var stateGeneration = 0
    var reloading = false
    var reloadInProgress = false
    var stopped = false
    var confirmationGrants: [UUID: ActionConfirmation] = [:]
    var consecutiveFailures: [String: Int] = [:]
    var installedRecords: [String: PluginRecord] = [:]
    let nativeCapabilities = NativeCapabilities()
    let tailscaleService: TailscaleService
    let remoteServer: RemoteServer
    let pluginCatalog = PluginCatalog()
    var installer: PluginInstaller?
    var nativeGrants: [UUID: NativeExecutionGrant] = [:]
    var nativeOperationOrigins: [UUID: String] = [:]
    static let capabilities = ["native.jobs": 1, "native.watcher": 1, "native.secrets": 1,
        "native.processes": 1, "native.launchd": 1,
        "native.brew": 1, "native.ssh": 1, "native.power": 1, "native.notify": 1,
        "native.tailscale": 1, "native.http": 1, "native.auth": 1]

    init(
        pluginRoot: URL? = nil,
        runner: CommandRunner = CommandRunner(),
        storageRoot: URL? = nil,
        tailscaleService: TailscaleService = TailscaleService(),
        remoteServer: RemoteServer = RemoteServer()
    ) {
        explicitRoot = pluginRoot
        let root = storageRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KiwiOS", isDirectory: true)
        self.storageRoot = root
        self.tailscaleService = tailscaleService
        self.remoteServer = remoteServer
        self.runner = CommandRunner(timeout: runner.timeout, maximumOutputBytes: runner.maximumOutputBytes,
            pluginDataRoot: runner.pluginDataRoot ?? root.appendingPathComponent("PluginData", isDirectory: true))
        startup = Task { [weak self] in await self?.initialize() }
    }

    func waitUntilReady() async { await startup?.value }

    func initialize() async {
        do {
            let root = storageRoot
            let database = try await Task.detached { try PersistenceStore(url: root.appendingPathComponent("KiwiOS.sqlite")) }.value
            try Task.checkCancellation()
            guard !stopped else { return }
            store = database
            configuration = PluginConfiguration(store: database, dataRoot: runner.pluginDataRoot!)
            if let data = try await database.layout(key: "mode"),
               let savedMode = try? JSONDecoder().decode(OperationMode.self, from: data) { mode = savedMode }
            if let data = try await database.layout(key: "home") {
                layout = try JSONDecoder().decode(HomeLayout.self, from: data)
            }
            if explicitRoot == nil, let data = try await database.layout(key: "development-directory"),
               let path = try? JSONDecoder().decode(String.self, from: data), !path.isEmpty {
                developmentDirectory = URL(fileURLWithPath: path)
            }
            try Task.checkCancellation()
            guard !stopped else { return }
            await reload()
            try Task.checkCancellation()
            guard !stopped else { return }
            await restoreIntegrations()
            try Task.checkCancellation()
            guard !stopped else { return }
            refreshTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled, let self else { return }
                    await self.refreshResults()
                }
            }
        } catch is CancellationError {
            // Shutdown owns cancellation of initialization.
        } catch { discoveryError = "Storage needs recovery: \(error.localizedDescription)" }
    }

    func reload() async {
        guard let store, !reloadInProgress, !stopped, !modeTransitioning else { return }
        reloadInProgress = true
        reloading = true
        stateGeneration += 1
        defer {
            reloading = false
            reloadInProgress = false
        }
        await queue?.shutdown()
        guard !stopped, !Task.isCancelled else { return }
        schedules.removeAll()
        pendingConfirmation = nil
        confirmationGrants.removeAll()
        nativeGrants.removeAll()
        nativeOperationOrigins.removeAll()
        remote.challenges.removeAll()
        remote.nativeChallenges.removeAll()
        native.pendingConfirmation = nil
        pendingReview = nil
        liveOutput.removeAll()
        loaded.removeAll()
        plugins.removeAll()
        fingerprints.removeAll()
        discoveryError = nil
        do {
            pendingRemovalIDs = Set(try await store.pendingPluginRemovals().map(\.pluginID))
            let storedPlugins = try await store.plugins()
            installedRecords = Dictionary(uniqueKeysWithValues: storedPlugins.filter { $0.sourceCommit != nil }.map { ($0.id, $0) })
            var sourceErrors: [String] = []
            let installedRoots = installedRecords.values.compactMap { record -> URL? in
                guard !pendingRemovalIDs.contains(record.id) else { return nil }
                guard PluginLexicalValidator.pluginID(record.id),
                      let commit = record.sourceCommit,
                      PluginLexicalValidator.commitSHA(commit) else {
                    sourceErrors.append("Invalid installed-plugin source record: \(record.id)")
                    return nil
                }
                return storageRoot.appendingPathComponent("InstalledPlugins").appendingPathComponent(record.id).appendingPathComponent(commit)
            }
            let explicitRoot = self.explicitRoot
            let development = developmentDirectory
            let resources = Bundle.main.resourceURL
            let capabilityVersions = Self.capabilities
            let discovered = try await Task.detached {
                let roots: [URL]
                if let explicitRoot { roots = [explicitRoot] }
                else if let resources {
                    let folder = resources.appendingPathComponent("plugins", isDirectory: true)
                    roots = [FileManager.default.fileExists(atPath: folder.path) ? folder : resources]
                } else { roots = [] }
                return try PluginDiscovery().discover(bundledPluginRoots: roots,
                    developmentDirectory: development, installedPluginRoots: installedRoots,
                    nativeCapabilities: capabilityVersions)
            }.value
            try Task.checkCancellation()
            guard !stopped else { return }
            sourceErrors += discovered.failures.map { "\($0.pluginID ?? URL(fileURLWithPath: $0.path).lastPathComponent): \($0.message)" }
            discoveryError = sourceErrors.isEmpty ? nil : sourceErrors.joined(separator: "\n")
            dependencyIssues = discovered.dependencyIssues
            for plugin in discovered.plugins {
                try Task.checkCancellation()
                guard !stopped else { return }
                loaded[plugin.manifest.id] = plugin
                var state = PluginState(manifest: plugin.manifest)
                do {
                    let fingerprint = try await Task.detached { try PluginFingerprint.read(root: plugin.rootURL) }.value
                    fingerprints[state.id] = fingerprint
                    let existing = try await store.plugin(id: state.id)
                    if let existing, !sourceMatches(existing, plugin: plugin, fingerprint: fingerprint) {
                        state.lifecycle = .error
                        state.message = "Source conflict: this ID is already bound to another plugin directory"
                    } else if let existing, existing.enabled, existing.lifecycleState == PluginLifecycle.error.rawValue {
                        state.lifecycle = .error
                        state.message = "Repeated execution failures; review and add again to retry"
                    } else if let existing, existing.enabled,
                              existing.manifestDigest == fingerprint.manifestDigest,
                              existing.contentDigest == fingerprint.contentDigest,
                              try await store.hasApproval(pluginID: state.id, manifestDigest: fingerprint.manifestDigest,
                                  contentDigest: fingerprint.contentDigest, disclosureDigest: fingerprint.manifestDigest,
                                  sourceRepository: approvalSourceIdentity(for: plugin, fingerprint: fingerprint),
                                  sourceCommit: installedRecords[state.id]?.sourceCommit) {
                        state.lifecycle = .needsSetup
                        state.message = "Checking setup prerequisites"
                    } else if let existing {
                        state.lifecycle = .disabled
                        state.message = existing.contentDigest == fingerprint.contentDigest
                            ? "Disabled" : "Source changed; review and approve the new contents"
                    }
                    if state.lifecycle != .error {
                        try await store.upsertPlugin(record(for: plugin, fingerprint: fingerprint, enabled: [.active, .needsSetup].contains(state.lifecycle),
                            lifecycle: state.lifecycle))
                    }
                } catch { state.lifecycle = .error; state.message = error.localizedDescription }
                if state.lifecycle != .error, let issues = dependencyIssues[state.id], !issues.isEmpty {
                    let enabledIntent = try await store.plugin(id: state.id)?.enabled ?? false
                    state.lifecycle = .missingDependency
                    state.message = issues.map(Self.describe).joined(separator: "; ")
                    if let fingerprint = fingerprints[state.id] {
                        try await store.upsertPlugin(record(for: plugin, fingerprint: fingerprint,
                            enabled: enabledIntent, lifecycle: .missingDependency))
                    }
                }
                plugins.append(state)
            }
            try Task.checkCancellation()
            guard !stopped else { return }
            let queue = JobQueue(store: store) { [weak self] context in
                guard let self else { throw CancellationError() }
                return try await self.execute(context)
            }
            self.queue = queue
            try await queue.start()
            try Task.checkCancellation()
            guard !stopped else { await queue.shutdown(); return }
            await doctorTask?.value
            doctorTask = nil
            await refreshDoctor()
            // Resolve the complete enabled dependency graph before admitting any work.
            var changed = true
            while changed {
                changed = false
                for plugin in plugins where plugin.lifecycle == .active {
                    if let reason = dependencyBlock(plugin.id) {
                        setLifecycle(plugin.id, .missingDependency, reason)
                        if let loadedPlugin = loaded[plugin.id], let fingerprint = fingerprints[plugin.id] {
                            try await store.upsertPlugin(record(for: loadedPlugin, fingerprint: fingerprint,
                                enabled: true, lifecycle: .missingDependency))
                        }
                        changed = true
                    }
                }
            }
            try Task.checkCancellation()
            guard !stopped else { return }
            reloading = false
            for plugin in plugins where plugin.lifecycle == .active { await startChecks(plugin.id) }
            if !layout.initialized {
                layout.widgets = plugins.flatMap { plugin in plugin.manifest.ui.widgets.map { "\(plugin.id)/\($0.id)" } }
                layout.wideWidgets = Set(plugins.flatMap { plugin in plugin.manifest.ui.widgets.filter { $0.size == "2x1" }.map { "\(plugin.id)/\($0.id)" } })
                layout.sidebar = plugins.flatMap { plugin in plugin.manifest.ui.sidebar.map { "\(plugin.id)/\($0.id)" } }
                layout.initialized = true
                await saveLayout()
            } else {
                await normalizeLayout()
            }
            await refreshResults()
        } catch { discoveryError = error.localizedDescription }
    }

    func requestEnable(pluginID: String) async {
        await waitUntilReady()
        guard let plugin = loaded[pluginID], let store, !pendingRemovalIDs.contains(pluginID) else { return }
        do {
            let fingerprint = try await Task.detached { try PluginFingerprint.read(root: plugin.rootURL) }.value
            if plugin.source == .installed, let installed = installedRecords[pluginID],
               installed.manifestDigest != fingerprint.manifestDigest || installed.contentDigest != fingerprint.contentDigest {
                throw PolicyError.blocked("The installed snapshot changed. Remove it in Discover, then install and review the exact revision again")
            }
            if let existing = try await store.plugin(id: pluginID), !sourceMatches(existing, plugin: plugin, fingerprint: fingerprint) {
                throw PolicyError.blocked("Source conflict: a plugin ID cannot silently move to another directory")
            }
            pendingReview = PluginReview(pluginID: pluginID, name: plugin.manifest.name,
                version: plugin.manifest.version, license: plugin.manifest.license,
                fingerprint: fingerprint, disclosures: plugin.manifest.permissions.disclosureLines)
        } catch { operationError = error.localizedDescription }
    }

    /// Browser callers can restore only source that was already approved locally and has not changed.
    func remoteEnablePrerequisites(pluginID: String) async throws -> [String] {
        guard let plugin = loaded[pluginID], let fingerprint = fingerprints[pluginID], let store,
              !pendingRemovalIDs.contains(pluginID),
              let state = plugins.first(where: { $0.id == pluginID }), [.disabled, .error].contains(state.lifecycle),
              let record = try await store.plugin(id: pluginID),
              (!record.enabled || state.lifecycle == .error),
              record.manifestDigest == fingerprint.manifestDigest,
              record.contentDigest == fingerprint.contentDigest,
              sourceMatches(record, plugin: plugin, fingerprint: fingerprint),
              try await store.hasApproval(pluginID: pluginID, manifestDigest: fingerprint.manifestDigest,
                  contentDigest: fingerprint.contentDigest, disclosureDigest: fingerprint.manifestDigest,
                  sourceRepository: approvalSourceIdentity(for: plugin, fingerprint: fingerprint),
                  sourceCommit: installedRecords[pluginID]?.sourceCommit) else {
            throw PolicyError.blocked("Enable unchanged, previously approved plugins from the web; review new or changed code in Attended Setup")
        }
        if let reason = dependencyBlock(pluginID) { throw PolicyError.blocked(reason) }
        let checks = await Task.detached { PluginDoctor().inspect(plugin.manifest) }.value
        if let issue = checks.first(where: { !$0.id.hasPrefix("brew-") && $0.status != .passed }) {
            throw PolicyError.blocked(issue.detail)
        }
        _ = try await configuration?.prepare(plugin)
        return plugin.manifest.brew.filter { !BrewFormulaStatus.isInstalled($0) }
    }

    func remoteEnableAvailable(pluginID: String) async -> Bool {
        guard let plugin = loaded[pluginID], let fingerprint = fingerprints[pluginID], let store,
              !pendingRemovalIDs.contains(pluginID),
              let state = plugins.first(where: { $0.id == pluginID }), [.disabled, .error].contains(state.lifecycle),
              let record = (try? await store.plugin(id: pluginID)) ?? nil,
              (!record.enabled || state.lifecycle == .error),
              record.manifestDigest == fingerprint.manifestDigest,
              record.contentDigest == fingerprint.contentDigest,
              sourceMatches(record, plugin: plugin, fingerprint: fingerprint) else { return false }
        return (try? await store.hasApproval(pluginID: pluginID, manifestDigest: fingerprint.manifestDigest,
            contentDigest: fingerprint.contentDigest, disclosureDigest: fingerprint.manifestDigest,
            sourceRepository: approvalSourceIdentity(for: plugin, fingerprint: fingerprint),
            sourceCommit: installedRecords[pluginID]?.sourceCommit)) == true
    }

    func remoteEnableBlocker(pluginID: String) async -> String? {
        guard let plugin = loaded[pluginID] else { return "Plugin source is unavailable" }
        let checks = await Task.detached { PluginDoctor().inspect(plugin.manifest) }.value
        return checks.first(where: { !$0.id.hasPrefix("brew-") && $0.status != .passed })?.detail
    }

    func enableApprovedPlugin(pluginID: String, requestedBy: String) async throws {
        let missing = try await remoteEnablePrerequisites(pluginID: pluginID)
        guard missing.isEmpty else {
            throw PolicyError.blocked("Install \(missing.sorted().joined(separator: ", ")) in Attended Setup before enabling this plugin")
        }
        guard let plugin = loaded[pluginID], let fingerprint = fingerprints[pluginID], let store else {
            throw PolicyError.blocked("Review the current setup requirements before enabling this plugin")
        }
        try await store.upsertPlugin(record(for: plugin, fingerprint: fingerprint, enabled: true, lifecycle: .needsSetup))
        consecutiveFailures = consecutiveFailures.filter { !$0.key.hasPrefix(pluginID + "/") }
        setLifecycle(pluginID, .needsSetup, "Checking setup prerequisites")
        try await audit("plugin.enabled", pluginID: pluginID, requestedBy: requestedBy)
        await refreshDoctor()
    }

    func approvePlugin(_ review: PluginReview) async {
        guard pendingReview?.id == review.id, pendingReview?.fingerprint == review.fingerprint,
              let plugin = loaded[review.pluginID], let store else { return }
        pendingReview = nil
        do {
            let fresh = try await Task.detached { () throws -> PluginFingerprint in
                let validated = try PluginLoader().load(from: plugin.rootURL)
                guard validated.manifest == plugin.manifest else { throw PolicyError.blocked("Manifest changed; reload plugins before approval") }
                return try PluginFingerprint.read(root: plugin.rootURL)
            }.value
            guard fresh == review.fingerprint else { throw PolicyError.blocked("Source changed during review; inspect it again") }
            if let reason = dependencyBlock(plugin.manifest.id) { throw PolicyError.blocked(reason) }
            if mode == .remote {
                let findings = await Task.detached { PluginDoctor().inspect(plugin.manifest) }.value
                guard findings.allSatisfy({ $0.status == .passed }) else {
                    throw PolicyError.blocked("Plugin enablement requires completed Doctor checks in remote mode")
                }
                _ = try await configuration?.prepare(plugin)
            }
            // Keep execution blocked until Doctor and configuration have both passed.
            try await store.upsertPlugin(record(for: plugin, fingerprint: fresh, enabled: true, lifecycle: .needsSetup))
            try await store.recordApproval(ApprovalRecord(pluginID: review.pluginID, manifestDigest: fresh.manifestDigest,
                contentDigest: fresh.contentDigest, disclosureDigest: fresh.manifestDigest,
                sourceRepository: sourceIdentity(for: plugin, fingerprint: fresh), sourceCommit: installedRecords[plugin.manifest.id]?.sourceCommit, approvedBy: "local", approvedAt: Date()))
            try await audit("plugin.approved", pluginID: review.pluginID)
            fingerprints[review.pluginID] = fresh
            consecutiveFailures = consecutiveFailures.filter { !$0.key.hasPrefix(review.pluginID + "/") }
            setLifecycle(review.pluginID, .needsSetup, "Checking setup prerequisites")
            await refreshDoctor()
            requestBrewInstallation(packages: plugin.manifest.brew, pluginID: review.pluginID)
            if plugins.first(where: { $0.id == review.pluginID })?.lifecycle == .active { await startChecks(review.pluginID) }
        } catch { operationError = error.localizedDescription }
    }

    func disable(pluginID: String, requestedBy: String = "local") async {
        do { try await disableApprovedPlugin(pluginID: pluginID, requestedBy: requestedBy) }
        catch { operationError = error.localizedDescription }
    }

    func disableApprovedPlugin(pluginID: String, requestedBy: String) async throws {
        guard let plugin = loaded[pluginID], let fingerprint = fingerprints[pluginID], let store else {
            throw PolicyError.blocked("Plugin is unavailable")
        }
        // Close every affected execution gate before any fallible or suspending operation.
        let affectedIDs = plugins.filter { dependsTransitively($0.id, on: pluginID) }.map(\.id)
        let dependents = plugins.filter { [.active, .needsSetup, .missingDependency].contains($0.lifecycle) && affectedIDs.contains($0.id) }
        setLifecycle(pluginID, .disabled, "Disabled")
        await cancelNativeOperations(for: pluginID, requestedBy: requestedBy)
        for dependent in dependents {
            setLifecycle(dependent.id, .missingDependency, "Required plugin \(pluginID) is disabled")
        }
        for id in [pluginID] + affectedIDs {
            await stopChecks(id)
            await queue?.cancelPlugin(id, requestedBy: requestedBy)
        }
        // Cancellation is complete even if saving intent or audit history fails.
        var failures: [String] = []
        do { try await store.upsertPlugin(record(for: plugin, fingerprint: fingerprint, enabled: false, lifecycle: .disabled)) }
        catch { failures.append(error.localizedDescription) }
        for dependent in dependents {
            if let loadedDependent = loaded[dependent.id], let dependentFingerprint = fingerprints[dependent.id] {
                do {
                    try await store.upsertPlugin(record(for: loadedDependent, fingerprint: dependentFingerprint,
                        enabled: true, lifecycle: .missingDependency))
                } catch { failures.append(error.localizedDescription) }
            }
        }
        do { try await audit("plugin.disabled", pluginID: pluginID, requestedBy: requestedBy) }
        catch { failures.append(error.localizedDescription) }
        await refreshDoctor()
        if !failures.isEmpty { throw PolicyError.blocked("Execution disabled; saving that state failed: " + failures.joined(separator: "; ")) }
    }

    func cancelNativeOperations(for pluginID: String, requestedBy: String) async {
        if native.pendingConfirmation?.originPluginID == pluginID { native.pendingConfirmation = nil }
        let jobIDs = nativeOperationOrigins.compactMap { $0.value == pluginID ? $0.key : nil }
        for id in jobIDs {
            nativeGrants.removeValue(forKey: id)
            nativeOperationOrigins.removeValue(forKey: id)
            do { try await queue?.cancel(id, requestedBy: requestedBy) }
            catch { operationError = error.localizedDescription }
        }
        for id in jobIDs { _ = await queue?.waitForCompletion(id) }
    }

    func runCheck(pluginID: String, checkID: String) async {
        await waitUntilReady()
        await submit(pluginID: pluginID, contributionID: checkID, kind: .check)
    }

    func runAction(pluginID: String, actionID: String) async {
        await waitUntilReady()
        guard let plugin = loaded[pluginID], let action = plugin.manifest.actions.first(where: { $0.id == actionID }) else { return }
        do {
            try requireEnabled(pluginID)
            if action.confirm {
                guard let fingerprint = fingerprints[pluginID] else { return }
                pendingConfirmation = ActionConfirmation(id: UUID(), pluginID: pluginID, actionID: actionID,
                    label: action.label, digest: fingerprint.contentDigest, expiresAt: Date().addingTimeInterval(60))
            } else { await submit(pluginID: pluginID, contributionID: actionID, kind: .action) }
        } catch { operationError = error.localizedDescription }
    }

    func confirmAction(_ confirmation: ActionConfirmation) async {
        guard pendingConfirmation?.id == confirmation.id else { return }
        pendingConfirmation = nil
        guard confirmation.expiresAt > Date(), fingerprints[confirmation.pluginID]?.contentDigest == confirmation.digest else {
            operationError = "Confirmation expired or the plugin changed; review the action again"
            return
        }
        let jobID = UUID()
        confirmationGrants[jobID] = confirmation
        await submit(pluginID: confirmation.pluginID, contributionID: confirmation.actionID, kind: .action, jobID: jobID)
        confirmationGrants.removeValue(forKey: jobID)
    }

    func submit(pluginID: String, contributionID: String, kind: JobKind, jobID: UUID = UUID()) async {
        guard let plugin = loaded[pluginID], let queue else { return }
        do {
            try requireEnabled(pluginID)
            let lock = kind == .action ? plugin.manifest.actions.first(where: { $0.id == contributionID })?.lock : nil
            let request = JobRequest(id: jobID, pluginID: pluginID, contributionID: contributionID,
                kind: kind, resource: lock ?? "\(kind.rawValue)-\(contributionID)", requestedBy: "local")
            let admission = try await queue.submit(request)
            await refreshResults()
            if case .accepted(let id) = admission {
                if await queue.waitForCompletion(id) == nil,
                   let failure = await queue.persistenceFailure(for: id) {
                    operationError = "Job storage failed: \(failure)"
                }
                await refreshResults()
            }
        } catch { operationError = error.localizedDescription }
    }

    func execute(_ context: JobExecutionContext) async throws -> JobExecutionResult {
        let request = context.request
        try Task.checkCancellation()
        if request.pluginID == "@native" { return try await executeNative(context) }
        if request.requestedBy.hasPrefix("tailscale:"), mode != .remote {
            throw PolicyError.blocked("Remote execution is disabled while attended setup is active")
        }
        try requireEnabled(request.pluginID)
        guard let plugin = loaded[request.pluginID], let approved = fingerprints[request.pluginID], let configuration else {
            throw PolicyError.blocked("Plugin is unavailable")
        }
        let command: [String]
        let timeout: TimeInterval
        if request.kind == .check {
            guard let check = plugin.manifest.checks.first(where: { $0.id == request.contributionID }) else {
                throw PolicyError.blocked("Check no longer exists")
            }
            command = check.command; timeout = check.timeout?.seconds ?? 30
        } else {
            guard let action = plugin.manifest.actions.first(where: { $0.id == request.contributionID }) else {
                throw PolicyError.blocked("Action no longer exists")
            }
            if action.confirm {
                guard let grant = confirmationGrants.removeValue(forKey: request.id),
                      grant.pluginID == request.pluginID, grant.actionID == request.contributionID,
                      grant.digest == approved.contentDigest, grant.expiresAt > Date() else {
                    throw PolicyError.blocked("This action requires a fresh KiwiOS confirmation")
                }
            }
            command = action.command; timeout = action.timeout?.seconds ?? 3_600
        }
        do {
            let current = try await Task.detached { () throws -> PluginFingerprint in
                let fresh = try PluginLoader().load(from: plugin.rootURL)
                guard fresh.manifest == plugin.manifest else { throw PolicyError.blocked("Manifest changed; reload and review the plugin") }
                return try PluginFingerprint.read(root: plugin.rootURL)
            }.value
            guard current == approved else { throw PolicyError.blocked("Approved plugin content changed; review it again") }
        } catch {
            await disable(pluginID: request.pluginID)
            throw error
        }
        let findings = await Task.detached { PluginDoctor().inspect(plugin.manifest) }.value
        guard findings.allSatisfy({ $0.status == .passed }) else {
            await markNeedsSetup(plugin, reason: "Complete attended setup; a declared prerequisite is unavailable or unknown")
            throw PolicyError.blocked("Doctor blocked execution: declared macOS prerequisites are not verified")
        }
        let secrets: [String: String]
        do { secrets = try await configuration.prepare(plugin) }
        catch {
            await markNeedsSetup(plugin, reason: error.localizedDescription)
            throw error
        }
        try requireEnabled(request.pluginID)
        try Task.checkCancellation()
        update(request.pluginID, message: "Running \(request.contributionID)…")
        liveOutput[request.id] = (Data(), Data())
        if let index = plugins.firstIndex(where: { $0.id == request.pluginID }) {
            plugins[index].liveResults["\(request.kind == .check ? "checks" : "actions").\(request.contributionID)"] = WatchResultBuilder().snapshot()
        }
        defer {
            liveOutput.removeValue(forKey: request.id)
            if let index = plugins.firstIndex(where: { $0.id == request.pluginID }) {
                plugins[index].liveResults.removeValue(forKey: "\(request.kind == .check ? "checks" : "actions").\(request.contributionID)")
            }
        }
        let result = try await runner.run(command: command, in: plugin.rootURL, pluginID: plugin.manifest.id,
            timeout: timeout, secrets: secrets, retainPartialResultOnCancellation: true) { [weak self] chunk in
                await self?.receive(chunk, request: request)
            }
        let typed = result.watchResult()
        let failureKey = "\(request.pluginID)/\(request.kind.rawValue)/\(request.contributionID)"
        if [.failed, .timedOut].contains(typed.outcome) {
            consecutiveFailures[failureKey, default: 0] += 1
            if consecutiveFailures[failureKey, default: 0] >= 3,
               plugins.first(where: { $0.id == request.pluginID })?.lifecycle == .active {
                setLifecycle(request.pluginID, .error, "Three consecutive failures; review and add again to retry")
                await stopChecks(request.pluginID)
                if plugins.first(where: { $0.id == request.pluginID })?.lifecycle == .error {
                    try await store?.upsertPlugin(record(for: plugin, fingerprint: approved, enabled: true, lifecycle: .error))
                }
            }
        } else if [.succeeded, .warning].contains(typed.outcome) {
            consecutiveFailures[failureKey] = 0
        }
        return JobExecutionResult(status: Self.jobStatus(typed.outcome), summary: typed.message,
            redactedPayloadJSON: try JSONEncoder().encode(typed))
    }

    func markNeedsSetup(_ plugin: LoadedPlugin, reason: String) async {
        guard plugins.first(where: { $0.id == plugin.manifest.id })?.lifecycle == .active else { return }
        setLifecycle(plugin.manifest.id, .needsSetup, reason)
        await stopChecks(plugin.manifest.id)
        if let fingerprint = fingerprints[plugin.manifest.id],
           plugins.first(where: { $0.id == plugin.manifest.id })?.lifecycle == .needsSetup {
            do { try await store?.upsertPlugin(record(for: plugin, fingerprint: fingerprint, enabled: true, lifecycle: .needsSetup)) }
            catch { operationError = error.localizedDescription }
        }
        await refreshDoctor()
    }

    func receive(_ chunk: CommandOutputChunk, request: JobRequest) {
        guard var output = liveOutput[request.id] else { return }
        switch chunk.stream {
        case .stdout: output.stdout.append(chunk.data.prefix(max(0, runner.maximumOutputBytes - output.stdout.count)))
        case .stderr: output.stderr.append(chunk.data.prefix(max(0, runner.maximumOutputBytes - output.stderr.count)))
        }
        liveOutput[request.id] = output
        var builder = WatchResultBuilder()
        // Incomplete JSONL is held until the next newline or final process result.
        if let lastNewline = output.stdout.lastIndex(of: 0x0A) {
            builder.append(WatchDecoder().decode(Data(output.stdout[...lastNewline])))
        }
        builder.appendStderr(output.stderr)
        if let index = plugins.firstIndex(where: { $0.id == request.pluginID }) {
            plugins[index].liveResults["\(request.kind == .check ? "checks" : "actions").\(request.contributionID)"] = builder.snapshot()
        }
    }

    func startChecks(_ pluginID: String) async {
        guard !modeTransitioning, !reloading, !stopped, !pluginTransitions.contains(pluginID), !pendingRemovalIDs.contains(pluginID),
              plugins.first(where: { $0.id == pluginID })?.lifecycle == .active,
              let plugin = loaded[pluginID], let queue, schedules[pluginID] == nil else { return }
        schedules[pluginID] = []
        do {
            for check in plugin.manifest.checks {
                try requireEnabled(pluginID)
                guard schedules[pluginID] != nil else { return }
                if let interval = check.every?.seconds {
                    let id = try await queue.scheduleCheck(pluginID: pluginID, contributionID: check.id,
                        resource: "check-\(check.id)", every: interval)
                    if schedules[pluginID] != nil, !stopped, !modeTransitioning,
                       plugins.first(where: { $0.id == pluginID })?.lifecycle == .active {
                        schedules[pluginID]?.append(id)
                    } else { await queue.cancelSchedule(id) }
                } else {
                    _ = try await queue.submit(JobRequest(pluginID: pluginID, contributionID: check.id,
                        kind: .check, resource: "check-\(check.id)", requestedBy: "enable"))
                }
            }
        } catch {
            await stopChecks(pluginID)
            if !modeTransitioning, !stopped { operationError = error.localizedDescription }
        }
    }

    func stopChecks(_ pluginID: String) async {
        for id in schedules.removeValue(forKey: pluginID) ?? [] { await queue?.cancelSchedule(id) }
    }

    func refreshResults() async {
        guard let store, !reloading, !stopped, !Task.isCancelled else { return }
        let generation = stateGeneration
        let now = Date()
        confirmationGrants = confirmationGrants.filter { $0.value.expiresAt > now }
        do {
            if let failure = await queue?.lastErrorMessage { operationError = "Job queue needs attention: \(failure)" }
            let snapshot = try await store.runtimeSnapshot()
            guard generation == stateGeneration, !stopped, !reloading, !Task.isCancelled else { return }
            if jobs != snapshot.jobs { jobs = snapshot.jobs }
            let latestByPlugin = Dictionary(grouping: snapshot.latestResults, by: \.pluginID)
            var updated = plugins
            for index in updated.indices {
                let plugin = updated[index]
                let sources = Set(plugin.manifest.checks.map { "checks.\($0.id)" } + plugin.manifest.actions.map { "actions.\($0.id)" })
                let latest = (latestByPlugin[plugin.id] ?? []).filter {
                    sources.contains("\($0.kind == .check ? "checks" : "actions").\($0.contributionID)")
                }
                for result in latest {
                    let source = "\(result.kind == .check ? "checks" : "actions").\(result.contributionID)"
                    guard !jobs.contains(where: { $0.pluginID == plugin.id && $0.contributionID == result.contributionID && $0.kind == result.kind && $0.status == .running }),
                          plugin.resultDates[source] != result.updatedAt else { continue }
                    updated[index].results[source] = result.resultJSON.flatMap { try? JSONDecoder().decode(WatchRunResult.self, from: $0) }
                        ?? Self.syntheticResult(result.status, message: result.summary ?? result.status.rawValue)
                    updated[index].resultDates[source] = result.updatedAt
                }
                if jobs.contains(where: { $0.pluginID == plugin.id && !$0.status.isTerminal }) {
                    if plugin.lifecycle == .active { updated[index].message = "Work in progress" }
                } else if let terminal = latest.filter({ $0.status.isTerminal && $0.status != .skipped }).max(by: { $0.updatedAt < $1.updatedAt }) {
                    if plugin.lifecycle == .active {
                        let source = "\(terminal.kind == .check ? "checks" : "actions").\(terminal.contributionID)"
                        let warnings = updated[index].results[source]?.protocolWarnings.isEmpty == false
                        updated[index].message = (warnings ? "Protocol warning: " : "") + (terminal.summary ?? terminal.status.rawValue)
                    }
                }
            }
            if plugins != updated { plugins = updated }
        } catch { operationError = "Storage needs recovery: \(error.localizedDescription)" }
    }

    func schema(pluginID: String) -> PluginConfigSchema? { loaded[pluginID]?.configSchema }
    func configSnapshot(pluginID: String) async -> PluginConfigurationSnapshot? {
        guard let plugin = loaded[pluginID], let configuration else { return nil }
        do { return try await configuration.snapshot(for: plugin) }
        catch { operationError = error.localizedDescription; return nil }
    }

    func saveConfig(pluginID: String, patch: [String: JSONValue], expectedRevision: Int64) async -> PluginConfigurationSnapshot? {
        guard let plugin = loaded[pluginID], let configuration else { return nil }
        do {
            try requireAdmissionsOpen()
            guard !pluginTransitions.contains(pluginID), !pendingRemovalIDs.contains(pluginID) else { throw PolicyError.blocked("Plugin installation is changing; retry after it completes") }
            policyOperations += 1
            defer { policyOperations -= 1 }
            let saved = try await configuration.save(patch, expectedRevision: expectedRevision, for: plugin, mode: mode)
            do { try await audit("plugin.config-saved", pluginID: pluginID) }
            catch { operationError = "Configuration saved; audit write failed: \(error.localizedDescription)" }
            await refreshDoctor()
            return saved
        } catch { operationError = error.localizedDescription; return nil }
    }
    func saveSecret(name: String, value: String) async {
        do {
            try requireAdmissionsOpen()
            policyOperations += 1
            defer { policyOperations -= 1 }
            try await configuration?.saveNamedSecret(value, name: name, mode: mode)
            do { try await audit("secret.saved", pluginID: nil) }
            catch { operationError = "Secret saved; audit write failed: \(error.localizedDescription)" }
            await refreshDoctor()
        } catch { operationError = error.localizedDescription }
    }
    func isBusy(pluginID: String, source: String) -> Bool {
        let parts = source.split(separator: ".", maxSplits: 1).map(String.init)
        let action = parts.count == 2 ? loaded[pluginID]?.manifest.actions.first(where: { $0.id == parts[1] }) : nil
        return jobs.contains { job in
            guard job.pluginID == pluginID, !job.status.isTerminal else { return false }
            if parts.count != 2 { return true }
            if parts[0] == "actions", let lock = action?.lock { return job.resource == "\(pluginID)/\(lock)" }
            return job.contributionID == parts[1] && job.kind == (parts[0] == "checks" ? .check : .action)
        }
    }

    func setMode(_ value: OperationMode) async {
        guard !stopped, !reloading, !modeTransitioning, value != mode, let queue, let store else { return }
        guard policyOperations == 0, !marketplaceBusy else {
            operationError = "Finish pending configuration or installation changes before changing policy mode"
            return
        }
        // Main-actor callers are gated before crossing to the queue's admission owner.
        modeTransitioning = true
        await queue.setAdmissionsPaused(true)
        for id in Array(schedules.keys) { await stopChecks(id) }
        do {
            guard !(await queue.hasAdmittedWork) else {
                throw PolicyError.blocked("Finish or cancel pending jobs before changing policy mode")
            }
            if value == .remote {
                await refreshDoctor()
                guard DoctorReadiness.hostIsReady(doctorFindings) else {
                    throw PolicyError.blocked("Resolve Doctor findings before entering remote mode")
                }
            }
            try Task.checkCancellation()
            guard !stopped, !(await queue.hasAdmittedWork) else { throw CancellationError() }
            if value == .setup { await stopRemoteAccess() }
            try await store.setLayout(key: "mode", json: JSONEncoder().encode(value))
            guard !stopped else { throw CancellationError() }
            mode = value
            pendingConfirmation = nil
            native.pendingConfirmation = nil
            confirmationGrants.removeAll()
            nativeGrants.removeAll()
            nativeOperationOrigins.removeAll()
            remote.challenges.removeAll()
            remote.nativeChallenges.removeAll()
            try await audit("mode.\(value.rawValue)", pluginID: nil)
        } catch { operationError = error.localizedDescription }
        modeTransitioning = false
        await queue.setAdmissionsPaused(false)
        if !stopped {
            for plugin in plugins where plugin.lifecycle == .active { await startChecks(plugin.id) }
        }
    }

    func refreshDoctor() async {
        guard !stopped else { return }
        doctorRevision &+= 1
        if let doctorTask { await doctorTask.value; return }
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            var completedRevision = -1
            while !self.stopped, !Task.isCancelled, completedRevision != self.doctorRevision {
                completedRevision = self.doctorRevision
                await self.reconcileReadiness()
            }
        }
        doctorTask = task
        await task.value
        doctorTask = nil
    }

    private func reconcileReadiness() async {
        let generation = stateGeneration
        var findings = await HostDoctor().inspect(storageRoot: storageRoot)
        guard !stopped, !Task.isCancelled, generation == stateGeneration else { return }
        do {
            let journalMode = try await store?.journalMode()
            findings.append(DoctorFinding(id: "database", title: "Database", status: journalMode == "wal" ? .passed : .blocked,
                detail: journalMode == "wal" ? "Persistent database is available in WAL mode" : "Database is unavailable or requires recovery"))
        } catch {
            findings.append(DoctorFinding(id: "database", title: "Database", status: .blocked, detail: error.localizedDescription))
        }
        var remaining = plugins.filter { [.active, .needsSetup, .missingDependency].contains($0.lifecycle) }.map(\.id)
        // Dependencies are promoted before their dependents, irrespective of discovery order.
        for _ in 0..<max(1, remaining.count) {
            var progressed = false
            for id in remaining {
                guard !stopped, !Task.isCancelled, generation == stateGeneration else { return }
                guard let plugin = loaded[id], let fingerprint = fingerprints[id],
                      let state = plugins.first(where: { $0.id == id }),
                      [.active, .needsSetup, .missingDependency].contains(state.lifecycle) else {
                    remaining.removeAll { $0 == id }; continue
                }
                let lifecycleVersion = lifecycleVersions[id, default: 0]
                if state.lifecycle == .missingDependency {
                    do {
                        guard let saved = try await store?.plugin(id: id), saved.enabled,
                              saved.contentDigest == fingerprint.contentDigest,
                              try await store?.hasApproval(pluginID: id, manifestDigest: fingerprint.manifestDigest,
                                contentDigest: fingerprint.contentDigest, disclosureDigest: fingerprint.manifestDigest,
                                sourceRepository: sourceIdentity(for: plugin, fingerprint: fingerprint),
                                sourceCommit: installedRecords[id]?.sourceCommit) == true else {
                            remaining.removeAll { $0 == id }; continue
                        }
                    } catch { operationError = error.localizedDescription; remaining.removeAll { $0 == id }; continue }
                }
                if dependencyBlock(id) != nil { continue }
                remaining.removeAll { $0 == id }
                let checks = await Task.detached { PluginDoctor().inspect(plugin.manifest) }.value
                var issue = checks.first(where: { $0.status != .passed })?.detail
                if issue == nil {
                    do { _ = try await configuration?.prepare(plugin) }
                    catch { issue = error.localizedDescription }
                }
                guard !stopped, generation == stateGeneration,
                      let current = plugins.first(where: { $0.id == id }), current.lifecycle == state.lifecycle,
                      lifecycleVersions[id, default: 0] == lifecycleVersion else { continue }
                if let reason = dependencyBlock(id) {
                    setLifecycle(id, .missingDependency, reason)
                    await stopChecks(id)
                    findings.append(DoctorFinding(id: "\(id)/dependency", title: plugin.manifest.name, status: .blocked, detail: reason))
                    continue
                }
                findings += checks.map { DoctorFinding(id: "\(id)/\($0.id)", title: "\(plugin.manifest.name): \($0.title)", status: $0.status, detail: $0.detail) }
                if let issue {
                    findings.append(DoctorFinding(id: "\(id)/setup", title: plugin.manifest.name, status: .blocked, detail: issue))
                    setLifecycle(id, .needsSetup, issue)
                    await stopChecks(id)
                } else {
                    setLifecycle(id, .active, "Setup complete")
                    progressed = true
                }
                if let current = plugins.first(where: { $0.id == id }), [.active, .needsSetup].contains(current.lifecycle) {
                    do { try await store?.upsertPlugin(record(for: plugin, fingerprint: fingerprint, enabled: true, lifecycle: current.lifecycle)) }
                    catch { operationError = error.localizedDescription }
                }
            }
            if !progressed { break }
        }
        for id in remaining {
            guard let reason = dependencyBlock(id), let plugin = loaded[id] else { continue }
            setLifecycle(id, .missingDependency, reason)
            await stopChecks(id)
            findings.append(DoctorFinding(id: "\(id)/dependency", title: plugin.manifest.name, status: .blocked, detail: reason))
        }
        guard !stopped, generation == stateGeneration else { return }
        doctorFindings = findings
        if !reloading, !modeTransitioning {
            for plugin in plugins where plugin.lifecycle == .active { await startChecks(plugin.id) }
        }
    }

    func setDevelopmentDirectory(_ url: URL?) async {
        guard mode == .setup else { operationError = "Change development sources in attended setup mode"; return }
        do {
            developmentDirectory = url
            try await store?.setLayout(key: "development-directory", json: JSONEncoder().encode(url?.path ?? ""))
            await reload()
        } catch { operationError = error.localizedDescription }
    }
    func clearError() { operationError = nil }
    func changeLayout(_ changed: HomeLayout) async { layout = changed; await saveLayout() }
    func normalizeLayout() async {
        let widgetKeys = Set(plugins.flatMap { plugin in
            plugin.manifest.ui.widgets.map { "\(plugin.id)/\($0.id)" }
        })
        let sidebarKeys = Set(plugins.flatMap { plugin in
            plugin.manifest.ui.sidebar.map { "\(plugin.id)/\($0.id)" }
        })
        let normalized = RemoteLayoutPolicy.normalized(
            layout, validWidgetKeys: widgetKeys, validSidebarKeys: sidebarKeys
        )
        guard normalized.widgets != layout.widgets || normalized.hiddenWidgets != layout.hiddenWidgets
                || normalized.wideWidgets != layout.wideWidgets || normalized.sidebar != layout.sidebar else { return }
        layout = normalized
        await saveLayout()
    }
    func saveLayout() async {
        do { try await store?.setLayout(key: "home", json: JSONEncoder().encode(layout)) }
        catch { operationError = error.localizedDescription }
    }
    func shutdown() async {
        stopped = true
        stateGeneration += 1
        startup?.cancel()
        doctorTask?.cancel()
        remoteRetryTask?.cancel()
        nativeGrants.removeAll()
        nativeOperationOrigins.removeAll()
        confirmationGrants.removeAll()
        remote.challenges.removeAll()
        remote.nativeChallenges.removeAll()
        refreshTask?.cancel()
        await startup?.value
        await doctorTask?.value
        await remoteRetryTask?.value
        // Initialization cannot create new tasks after these final cancellation/drain steps.
        refreshTask?.cancel()
        await refreshTask?.value
        await remoteServer.stop()
        do { try await tailscaleService.stop() }
        catch { operationError = "Backend stopped; Serve configuration needs attention: \(error.localizedDescription)" }
        await queue?.shutdown()
    }

    func setPluginTransition(_ id: String, active: Bool) {
        if active { pluginTransitions.insert(id) }
        else {
            pluginTransitions.remove(id)
            if !stopped {
                Task { [weak self] in await self?.startChecks(id) }
            }
        }
    }

    func requireAdmissionsOpen() throws {
        try Task.checkCancellation()
        guard !reloading, !stopped, !modeTransitioning else {
            throw PolicyError.blocked("The runtime is changing policy or stopping; retry when ready")
        }
    }

    func requireEnabled(_ id: String) throws {
        try requireAdmissionsOpen()
        guard !pluginTransitions.contains(id), !pendingRemovalIDs.contains(id), plugins.first(where: { $0.id == id })?.lifecycle == .active else {
            throw PolicyError.blocked("Plugin is not active; review its source and complete setup first")
        }
        if let reason = dependencyBlock(id) { throw PolicyError.blocked(reason) }
    }
    func dependencyBlock(_ id: String) -> String? {
        if let issues = dependencyIssues[id], !issues.isEmpty { return issues.map(Self.describe).joined(separator: "; ") }
        guard let plugin = loaded[id] else { return "Plugin is unavailable" }
        for dependency in plugin.manifest.depends.keys where !dependency.hasPrefix("native.") {
            if plugins.first(where: { $0.id == dependency })?.lifecycle != .active { return "Required plugin \(dependency) is not active" }
        }
        return nil
    }
    func dependsTransitively(_ id: String, on dependency: String, visited: Set<String> = []) -> Bool {
        guard !visited.contains(id), let plugin = loaded[id] else { return false }
        let required = plugin.manifest.depends.keys.filter { !$0.hasPrefix("native.") }
        return required.contains(dependency) || required.contains { dependsTransitively($0, on: dependency, visited: visited.union([id])) }
    }
    func sourceIdentity(for plugin: LoadedPlugin, fingerprint: PluginFingerprint) -> String {
        if plugin.source == .installed { return installedRecords[plugin.manifest.id]?.sourceRepository ?? fingerprint.source }
        if plugin.source == .bundled, explicitRoot == nil { return "kiwios-bundled:\(plugin.manifest.id)" }
        return fingerprint.source
    }
    func approvalSourceIdentity(for plugin: LoadedPlugin, fingerprint: PluginFingerprint) -> String? {
        plugin.source == .bundled && explicitRoot == nil ? nil : sourceIdentity(for: plugin, fingerprint: fingerprint)
    }
    func sourceMatches(_ existing: PluginRecord, plugin: LoadedPlugin, fingerprint: PluginFingerprint) -> Bool {
        if existing.sourceRepository == sourceIdentity(for: plugin, fingerprint: fingerprint) { return true }
        guard plugin.source == .bundled, explicitRoot == nil, existing.sourceCommit == nil,
              let legacy = existing.sourceRepository else { return false }
        let parts = URL(fileURLWithPath: legacy).standardizedFileURL.pathComponents
        guard parts.count >= 5 else { return false }
        return parts.suffix(4) == ["Contents", "Resources", "plugins", plugin.manifest.id]
            && parts[parts.count - 5].hasSuffix(".app")
    }
    func record(for plugin: LoadedPlugin, fingerprint: PluginFingerprint, enabled: Bool, lifecycle: PluginLifecycle) -> PluginRecord {
        // Only the install transaction may change the content bound to a Git revision.
        // Discovery or disable must never bless changed bytes under the recorded SHA.
        if plugin.source == .installed, var installed = installedRecords[plugin.manifest.id] {
            installed.enabled = enabled
            installed.lifecycleState = lifecycle.rawValue
            installed.updatedAt = Date()
            return installed
        }
        return PluginRecord(id: plugin.manifest.id, name: plugin.manifest.name, version: plugin.manifest.version,
            sourceRepository: sourceIdentity(for: plugin, fingerprint: fingerprint), sourceCommit: nil, manifestDigest: fingerprint.manifestDigest,
            contentDigest: fingerprint.contentDigest, enabled: enabled, lifecycleState: lifecycle.rawValue, updatedAt: Date())
    }
    func audit(_ event: String, pluginID: String?, requestedBy: String = "local") async throws {
        try await store?.appendAudit(AuditEntry(occurredAt: Date(), actor: requestedBy,
            event: event, pluginID: pluginID, jobID: nil))
    }
    func setLifecycle(_ id: String, _ lifecycle: PluginLifecycle, _ message: String) {
        lifecycleVersions[id, default: 0] += 1
        guard let index = plugins.firstIndex(where: { $0.id == id }) else { return }
        plugins[index].lifecycle = lifecycle; plugins[index].message = message
    }
    func update(_ id: String, message: String) {
        guard let index = plugins.firstIndex(where: { $0.id == id }) else { return }
        if plugins[index].lifecycle == .active { plugins[index].message = message }
    }
    static func describe(_ issue: PluginDependencyIssue) -> String {
        switch issue {
        case .missing(let id): "Missing dependency \(id)"
        case .incompatible(let id, let required, let actual): "Dependency \(id) requires \(required); found \(actual)"
        case .cycle(let ids): "Dependency cycle: \(ids.joined(separator: " → "))"
        }
    }
    static func jobStatus(_ outcome: WatchRunOutcome) -> JobStatus {
        switch outcome {
        case .succeeded: .succeeded
        case .warning: .warning
        case .failed: .failed
        case .timedOut: .timedOut
        case .canceled: .canceled
        case .interrupted: .interrupted
        }
    }
    static func syntheticResult(_ status: JobStatus, message: String) -> WatchRunResult {
        let outcome: WatchRunOutcome = switch status {
        case .succeeded: .succeeded
        case .warning: .warning
        case .timedOut: .timedOut
        case .canceled: .canceled
        case .interrupted: .interrupted
        default: .failed
        }
        return WatchRunResult(outcome: outcome, message: message, state: nil, progress: nil,
            logs: [], protocolWarnings: [], exitCode: nil, outputTruncated: false)
    }
}
