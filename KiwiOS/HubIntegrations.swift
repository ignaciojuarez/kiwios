import Foundation

struct NativeConfirmation: Identifiable, Sendable {
    let id: UUID
    let operation: NativeOperation
    let title: String
    let expiresAt: Date
    let originPluginID: String?
}
struct NativeExecutionGrant: Sendable {
    let operation: NativeOperation
    let requestedBy: String
    let originPluginID: String?

    init(operation: NativeOperation, requestedBy: String, originPluginID: String?) {
        self.operation = operation
        self.requestedBy = requestedBy
        self.originPluginID = originPluginID
    }
}
struct HomebrewRemovalItem: Identifiable, Equatable, Sendable {
    var id: String { formula }
    let formula: String
    let canUninstall: Bool
    let detail: String
}
struct PluginRemovalReview: Identifiable, Sendable {
    var id: String { pluginID }
    let pluginID: String
    let name: String
    let homebrew: [HomebrewRemovalItem]
}
enum HomebrewCleanupPolicy {
    static func owns(_ formula: ManagedHomebrewFormula, currentReceiptIdentity: String?) -> Bool {
        guard let recorded = formula.receiptIdentity, let currentReceiptIdentity else { return false }
        return recorded == currentReceiptIdentity
    }

    static func item(
        formula: String,
        isInstalled: Bool,
        installedByKiwiOS: Bool,
        otherPluginNames: [String],
        installedDependents: [String]?
    ) -> HomebrewRemovalItem {
        if !isInstalled {
            return HomebrewRemovalItem(formula: formula, canUninstall: false, detail: "Already not installed")
        }
        if !installedByKiwiOS {
            return HomebrewRemovalItem(
                formula: formula, canUninstall: false,
                detail: "Kept because it was installed outside KiwiOS"
            )
        }
        if !otherPluginNames.isEmpty {
            return HomebrewRemovalItem(
                formula: formula, canUninstall: false,
                detail: "Kept because another plugin declares it: \(otherPluginNames.sorted().joined(separator: ", "))"
            )
        }
        guard let installedDependents else {
            return HomebrewRemovalItem(
                formula: formula, canUninstall: false,
                detail: "Kept because Homebrew dependency use could not be verified"
            )
        }
        if !installedDependents.isEmpty {
            return HomebrewRemovalItem(
                formula: formula, canUninstall: false,
                detail: "Kept because installed Homebrew packages require it: \(installedDependents.sorted().joined(separator: ", "))"
            )
        }
        return HomebrewRemovalItem(
            formula: formula, canUninstall: true,
            detail: "Installed by KiwiOS; no other plugin or installed Homebrew package currently requires it"
        )
    }
}
struct RemoteActionChallenge: Sendable {
    let identity: RemoteIdentity
    let confirmation: ActionConfirmation
}
struct RemoteNativeChallenge: Sendable {
    let identity: RemoteIdentity
    let operation: NativeOperation
    let expiresAt: Date
    let originPluginID: String?

    func isValid(for candidate: RemoteIdentity, now: Date = Date()) -> Bool {
        identity == candidate && expiresAt > now
    }
}

struct RemoteInstallationChallenge: Sendable {
    let identity: RemoteIdentity
    let review: InstallationReview
    let expiresAt: Date

    func isValid(for candidate: RemoteIdentity, now: Date = Date()) -> Bool {
        identity == candidate && expiresAt > now
    }
}

struct RemotePluginEnableChallenge: Sendable {
    let identity: RemoteIdentity
    let review: PluginReview
    let expiresAt: Date

    func isValid(for candidate: RemoteIdentity, now: Date = Date()) -> Bool {
        identity == candidate && expiresAt > now
    }
}

struct RemoteRemovalChallenge: Sendable {
    let identity: RemoteIdentity
    let review: PluginRemovalReview
    let expiresAt: Date

    func isValid(for candidate: RemoteIdentity, now: Date = Date()) -> Bool {
        identity == candidate && expiresAt > now
    }
}

extension HubRuntime {
    func restoreIntegrations() async {
        guard let store, let configuration, !stopped, !Task.isCancelled else { return }
        do {
            let legacyLogs = storageRoot.appendingPathComponent("Logs", isDirectory: true)
            try await Task.detached {
                if FileManager.default.fileExists(atPath: legacyLogs.path) {
                    try FileManager.default.removeItem(at: legacyLogs)
                }
            }.value
        } catch { operationError = "Legacy log cleanup failed: \(error.localizedDescription)" }
        installer = PluginInstaller(applicationSupportRoot: storageRoot,
            validateConfiguration: { plugin in
                if try await store.plugin(id: plugin.manifest.id) != nil {
                    try await configuration.validateForUpdate(plugin)
                }
            }, existingPlugin: { [weak self] id in await self?.loaded[id] })
        startPluginUpdateChecks()
        if let installer {
            for record in installedRecords.values {
                guard let commit = record.sourceCommit else { continue }
                do { try await installer.pruneSnapshots(pluginID: record.id, activeCommit: commit) }
                catch { operationError = "Installed snapshot cleanup failed: \(error.localizedDescription)" }
            }
        }
        do {
            let removals = try await store.pendingPluginRemovals()
            for removal in removals {
                try await finishRemoval(removal, store: store, configuration: configuration)
            }
            if !removals.isEmpty { await reload() }
        } catch { operationError = "Plugin removal needs recovery: \(error.localizedDescription)" }
        do { curatedEntries = try await pluginCatalog.curatedEntries() }
        catch { operationError = "Curated catalog unavailable: \(error.localizedDescription)" }
        do {
            if let data = try await store.layout(key: "ssh-peers") {
                native.peers = try JSONDecoder().decode([NamedSSHPeer].self, from: data)
            }
            try await nativeCapabilities.setNamedSSHPeers(native.peers)
        } catch { operationError = error.localizedDescription }
        // A malformed saved peer must not prevent independent remote recovery.
        guard !stopped, !Task.isCancelled else { return }
        refreshNativeToolsIfNeeded()
        await restoreRemoteAccess()
        guard !stopped, !Task.isCancelled else { return }
    }

    func refreshNativeToolsIfNeeded(now: Date = Date()) {
        guard NativeToolsRefreshPolicy.needsRefresh(
            sampledAt: native.toolsSnapshot?.sampledAt,
            isRefreshing: native.toolsRefreshing,
            now: now
        ) else { return }
        startNativeToolsRefresh()
    }

    func refreshNativeTools() async {
        guard !stopped, !Task.isCancelled, !native.toolsRefreshing else { return }
        native.toolsRefreshing = true
        await finishNativeToolsRefresh()
    }
    func startNativeToolsRefresh() {
        guard !stopped, !native.toolsRefreshing else { return }
        native.toolsRefreshing = true
        Task { [weak self] in await self?.finishNativeToolsRefresh() }
    }
    private func finishNativeToolsRefresh() async {
        defer { native.toolsRefreshing = false }
        while !stopped, !Task.isCancelled {
            let generation = native.generation
            let snapshot = await nativeCapabilities.toolsSnapshot()
            guard !stopped, !Task.isCancelled else { return }
            if generation == native.generation { native.toolsSnapshot = snapshot; return }
            // An operation completed during inspection; do not publish its stale result.
        }
    }
    func isNativeBusy(_ operation: NativeOperation) -> Bool {
        jobs.contains {
            $0.pluginID == "@native"
                && $0.resource == JobRequest.namespacedResource(pluginID: "@native", resource: operation.resource)
                && !$0.status.isTerminal
        }
    }
    func requestNativeOperation(_ operation: NativeOperation, originPluginID: String? = nil) {
        Task {
            do {
                try await validateNativeOperation(operation, requestedBy: "local", originPluginID: originPluginID)
                if let title = operation.confirmationTitle {
                    native.pendingConfirmation = NativeConfirmation(id: UUID(), operation: operation,
                        title: title, expiresAt: Date().addingTimeInterval(60), originPluginID: originPluginID)
                } else {
                    try await enqueueNativeOperation(operation, requestedBy: "local", originPluginID: originPluginID)
                }
            } catch {
                operationError = error.localizedDescription
                if let originPluginID {
                    try? await disableApprovedPlugin(pluginID: originPluginID, requestedBy: "local")
                }
            }
        }
    }
    func requestBrewInstallation(packages: [String], pluginID: String) {
        let missing = packages.filter { !BrewFormulaStatus.isInstalled($0) }
        guard !missing.isEmpty else { return }
        requestNativeOperation(.homebrewInstall(packages: missing), originPluginID: pluginID)
    }
    func requestManagedHomebrewCleanup() {
        guard !marketplaceBusy else { return }
        Task { await prepareManagedHomebrewCleanup() }
    }
    private func prepareManagedHomebrewCleanup() async {
        guard !marketplaceBusy, let store else { return }
        marketplaceBusy = true
        defer { marketplaceBusy = false }
        do {
            let managed = try await store.managedHomebrewFormulae()
            var removable: [String] = []
            var staleOwnership: [String] = []
            for formula in managed.sorted(by: { $0.name < $1.name }) {
                let installed = BrewFormulaStatus.isInstalled(formula.name)
                let owned = HomebrewCleanupPolicy.owns(
                    formula, currentReceiptIdentity: BrewFormulaStatus.receiptIdentity(formula.name)
                )
                guard installed, owned else { staleOwnership.append(formula.name); continue }
                guard try await enabledPluginsDeclaring(formula.name).isEmpty else { continue }
                let dependents = try await nativeCapabilities.installedHomebrewDependents(of: formula.name)
                if dependents.isEmpty { removable.append(formula.name) }
            }
            if !staleOwnership.isEmpty { try await store.forgetManagedHomebrewFormulae(staleOwnership) }
            guard !removable.isEmpty else {
                throw PolicyError.blocked("No unused KiwiOS-installed Homebrew packages are ready for cleanup")
            }
            let operation = NativeOperation.homebrewUninstall(packages: Array(removable.prefix(50)))
            try await validateNativeOperation(operation, requestedBy: "local")
            native.pendingConfirmation = NativeConfirmation(
                id: UUID(), operation: operation, title: operation.confirmationTitle!,
                expiresAt: Date().addingTimeInterval(60), originPluginID: nil
            )
        } catch { operationError = error.localizedDescription }
    }
    func confirmNativeOperation(_ confirmation: NativeConfirmation) async {
        guard native.pendingConfirmation?.id == confirmation.id else { return }
        native.pendingConfirmation = nil
        do {
            guard confirmation.expiresAt > Date() else { throw PolicyError.blocked("Native action confirmation expired") }
            try await enqueueNativeOperation(confirmation.operation, requestedBy: "local",
                originPluginID: confirmation.originPluginID)
        } catch {
            operationError = error.localizedDescription
            if let pluginID = confirmation.originPluginID {
                try? await disableApprovedPlugin(pluginID: pluginID, requestedBy: "local")
            }
        }
    }
    func cancelNativeConfirmation(_ confirmation: NativeConfirmation) async {
        guard native.pendingConfirmation?.id == confirmation.id else { return }
        native.pendingConfirmation = nil
        if let pluginID = confirmation.originPluginID {
            do { try await disableApprovedPlugin(pluginID: pluginID, requestedBy: "local") }
            catch { operationError = error.localizedDescription }
        }
    }
    func validateNativeOperation(
        _ operation: NativeOperation, requestedBy: String, originPluginID: String? = nil
    ) async throws {
        try requireAdmissionsOpen()
        if let originPluginID {
            let dependencyInstall: Bool
            if case .homebrewInstall = operation { dependencyInstall = true } else { dependencyInstall = false }
            guard let record = try await store?.plugin(id: originPluginID),
                  record.enabled || dependencyInstall,
                  let lifecycle = plugins.first(where: { $0.id == originPluginID })?.lifecycle,
                  [.active, .needsSetup, .missingDependency].contains(lifecycle)
                    || (dependencyInstall && [.disabled, .error].contains(lifecycle)) else {
                throw PolicyError.blocked("The plugin requesting this dependency is no longer added")
            }
        }
        if case .probeSSH(let peerName) = operation, !native.peers.contains(where: { $0.name == peerName }) {
            throw PolicyError.blocked("Choose a peer saved in KiwiOS Settings")
        }
        if case .homebrewUninstall(let packages) = operation {
            guard let store else { throw PolicyError.blocked("KiwiOS storage is unavailable") }
            let managed = try await store.managedHomebrewFormulae()
            let managedByName = Dictionary(uniqueKeysWithValues: managed.map { ($0.name, $0) })
            for package in packages {
                guard let formula = managedByName[package], HomebrewCleanupPolicy.owns(
                    formula, currentReceiptIdentity: BrewFormulaStatus.receiptIdentity(package)
                ) else {
                    throw PolicyError.blocked(
                        "KiwiOS retained \(package) because its Homebrew installation changed after KiwiOS installed it"
                    )
                }
            }
            for package in packages {
                let users = try await enabledPluginsDeclaring(package)
                guard users.isEmpty else {
                    throw PolicyError.blocked(
                        "Homebrew package \(package) is still declared by: \(users.map(\.manifest.name).sorted().joined(separator: ", "))"
                    )
                }
            }
        }
        let effectiveMode: OperationMode = requestedBy.hasPrefix("tailscale:") ? .remote : mode
        try await nativeCapabilities.validate(operation, mode: effectiveMode)
        try requireAdmissionsOpen()
        guard effectiveMode == (requestedBy.hasPrefix("tailscale:") ? .remote : mode) else {
            throw PolicyError.blocked("Policy changed during native validation; retry the operation")
        }
    }
    func enqueueNativeOperation(
        _ operation: NativeOperation, requestedBy: String, originPluginID: String? = nil
    ) async throws {
        guard let queue else { throw PolicyError.blocked("The job queue is unavailable") }
        try await validateNativeOperation(operation, requestedBy: requestedBy, originPluginID: originPluginID)
        let id = UUID()
        nativeGrants[id] = NativeExecutionGrant(operation: operation,
            requestedBy: requestedBy, originPluginID: originPluginID)
        if let originPluginID { nativeOperationOrigins[id] = originPluginID }
        do {
            let admission = try await queue.submit(JobRequest(id: id, pluginID: "@native", contributionID: operation.contributionID,
                kind: .action, resource: operation.resource, requestedBy: requestedBy))
            if case .skipped = admission {
                nativeGrants.removeValue(forKey: id)
                nativeOperationOrigins.removeValue(forKey: id)
                throw PolicyError.blocked("Another Homebrew operation is already active")
            }
            await refreshResults()
        } catch {
            nativeGrants.removeValue(forKey: id)
            nativeOperationOrigins.removeValue(forKey: id)
            throw error
        }
    }
    func executeNative(_ context: JobExecutionContext) async throws -> JobExecutionResult {
        guard let grant = nativeGrants.removeValue(forKey: context.jobID),
              grant.requestedBy == context.request.requestedBy else {
            throw PolicyError.blocked("Native action approval is missing")
        }
        defer { nativeOperationOrigins.removeValue(forKey: context.jobID) }
        var attemptedExecution = false
        do {
            try await validateNativeOperation(grant.operation, requestedBy: grant.requestedBy,
                originPluginID: grant.originPluginID)
            try Task.checkCancellation()
            attemptedExecution = true
            let result = try await nativeCapabilities.execute(grant.operation)
            try await reconcileManagedHomebrewFormulae(after: grant.operation)
            native.generation += 1
            native.toolsSnapshot = nil
            await refreshNativeTools()
            if case .homebrewInstall(let packages) = grant.operation,
               result.status != .succeeded || packages.contains(where: { !BrewFormulaStatus.isInstalled($0) }) {
                if let pluginID = grant.originPluginID {
                    nativeOperationOrigins.removeValue(forKey: context.jobID)
                    try? await disableApprovedPlugin(pluginID: pluginID, requestedBy: "local")
                }
                await refreshDoctor()
                if result.status == .succeeded {
                    return JobExecutionResult(status: .failed,
                        summary: "Homebrew completed, but a required package is still missing")
                }
                return result
            }
            if case .homebrewInstall = grant.operation { await refreshDoctor() }
            if case .homebrewUninstall = grant.operation { await refreshDoctor() }
            return result
        } catch {
            operationError = error.localizedDescription
            if attemptedExecution {
                do { try await reconcileManagedHomebrewFormulae(after: grant.operation) }
                catch {
                    operationError = "Homebrew changed, but KiwiOS could not update its ownership record: \(error.localizedDescription)"
                }
            }
            // A command can fail after changing host state. Invalidate on both paths.
            native.generation += 1
            native.toolsSnapshot = nil
            await refreshNativeTools()
            if case .homebrewInstall = grant.operation, let pluginID = grant.originPluginID {
                nativeOperationOrigins.removeValue(forKey: context.jobID)
                try? await disableApprovedPlugin(pluginID: pluginID, requestedBy: "local")
            }
            throw error
        }
    }

    private func enabledPluginsDeclaring(
        _ formula: String, excluding excludedID: String? = nil
    ) async throws -> [LoadedPlugin] {
        guard let store else { throw PolicyError.blocked("KiwiOS storage is unavailable") }
        let records = try await store.plugins()
        let enabledIDs = Set(records.filter(\.enabled).map(\.id))
        return loaded.values.filter {
            $0.manifest.id != excludedID && enabledIDs.contains($0.manifest.id)
                && $0.manifest.brew.contains(formula)
        }
    }

    private func reconcileManagedHomebrewFormulae(after operation: NativeOperation) async throws {
        guard let store else { throw PolicyError.blocked("KiwiOS storage is unavailable") }
        switch operation {
        case .homebrewInstall(let packages):
            let installed = packages.compactMap { formula -> ManagedHomebrewFormula? in
                guard BrewFormulaStatus.isInstalled(formula),
                      let identity = BrewFormulaStatus.receiptIdentity(formula) else { return nil }
                return ManagedHomebrewFormula(name: formula, receiptIdentity: identity)
            }
            if !installed.isEmpty { try await store.recordManagedHomebrewFormulae(installed) }
        case .homebrewUninstall(let packages):
            let absent = packages.filter { !BrewFormulaStatus.isInstalled($0) }
            if !absent.isEmpty { try await store.forgetManagedHomebrewFormulae(absent) }
        case .homebrewUpgrade(let packages):
            let managedNames = Set(try await store.managedHomebrewFormulae().map(\.name))
            let upgraded = packages.compactMap { formula -> ManagedHomebrewFormula? in
                guard managedNames.contains(formula),
                      let identity = BrewFormulaStatus.receiptIdentity(formula) else { return nil }
                return ManagedHomebrewFormula(name: formula, receiptIdentity: identity)
            }
            if !upgraded.isEmpty { try await store.recordManagedHomebrewFormulae(upgraded) }
        default: break
        }
    }
    @discardableResult
    func addSSHPeer(_ peer: NamedSSHPeer) async -> Bool {
        do {
            try requireAdmissionsOpen()
            guard !native.editingPeers else { throw PolicyError.blocked("Another SSH peer edit is being saved") }
            native.editingPeers = true
            policyOperations += 1
            defer { native.editingPeers = false; policyOperations -= 1 }
            guard mode == .setup else { throw PolicyError.blocked("Configure SSH peers in attended setup") }
            guard !native.peers.contains(where: { $0.name == peer.name }) else { throw PolicyError.blocked("A peer with this name already exists") }
            var updated = native.peers
            updated.append(peer)
            try await nativeCapabilities.setNamedSSHPeers(updated)
            do { try await store?.setLayout(key: "ssh-peers", json: JSONEncoder().encode(updated)) }
            catch { try? await nativeCapabilities.setNamedSSHPeers(native.peers); throw error }
            native.peers = updated
            do { try await audit("ssh.peer-added", pluginID: nil) }
            catch { operationError = "Peer saved; audit write failed: \(error.localizedDescription)" }
            return true
        } catch { operationError = error.localizedDescription; return false }
    }
    func removeSSHPeer(_ peer: NamedSSHPeer) async {
        do {
            try requireAdmissionsOpen()
            guard !native.editingPeers else { throw PolicyError.blocked("Another SSH peer edit is being saved") }
            native.editingPeers = true
            policyOperations += 1
            defer { native.editingPeers = false; policyOperations -= 1 }
            guard mode == .setup else { throw PolicyError.blocked("Configure SSH peers in attended setup") }
            let updated = native.peers.filter { $0.name != peer.name }
            try await nativeCapabilities.setNamedSSHPeers(updated)
            do { try await store?.setLayout(key: "ssh-peers", json: JSONEncoder().encode(updated)) }
            catch { try? await nativeCapabilities.setNamedSSHPeers(native.peers); throw error }
            native.peers = updated
            try await audit("ssh.peer-removed", pluginID: nil)
        } catch { operationError = error.localizedDescription }
    }

    func searchPlugins(_ query: String) async {
        guard !marketplaceBusy else { return }
        marketplaceBusy = true
        defer { marketplaceBusy = false }
        do { marketplaceResults = try await pluginCatalog.search(query) }
        catch { operationError = error.localizedDescription }
    }
    func startPluginUpdateChecks() {
        pluginUpdateTask?.cancel()
        pluginUpdateTask = Task { [weak self] in
            while !Task.isCancelled, let self, !self.stopped {
                await self.refreshPluginUpdates()
                do { try await Task.sleep(for: .seconds(15 * 60)) }
                catch { return }
            }
        }
    }
    private func refreshPluginUpdates() async {
        guard let installer else { return }
        let records = installedRecords.values.filter {
            $0.sourceRepository != nil && $0.sourceCommit != nil
        }
        var updates: [String: PluginUpdate] = [:]
        await withTaskGroup(of: (String, PluginUpdate?).self) { group in
            for record in records {
                group.addTask {
                    guard let repository = record.sourceRepository, let commit = record.sourceCommit else {
                        return (record.id, nil)
                    }
                    let update = try? await installer.availableUpdate(repository: repository,
                        currentCommit: commit, pluginPath: record.sourcePath ?? ".",
                        pluginID: record.id, currentVersion: record.version)
                    return (record.id, update)
                }
            }
            for await (id, update) in group {
                if let update { updates[id] = update }
            }
        }
        guard !Task.isCancelled, !stopped else { return }
        pluginUpdates = updates
    }
    func stageCuratedInstallation(_ entry: CuratedPluginEntry) async {
        await stageInstallation(repository: entry.repository, commit: entry.commit, path: entry.path, expectedEntry: entry)
    }
    func stageInstallation(repository: String, commit: String, path: String = ".", expectedEntry: CuratedPluginEntry? = nil) async {
        guard !marketplaceBusy, let installer else { return }
        marketplaceBusy = true
        defer { marketplaceBusy = false }
        do {
            guard mode == .setup else { throw PolicyError.blocked("Install plugin sources in attended setup") }
            if let old = pendingInstallation { await installer.cancel(reviewID: old.id); pendingInstallation = nil }
            let review = try await installer.stage(repository: repository, commit: commit, pluginPath: path)
            if let expectedEntry,
               review.repository != expectedEntry.repository || review.commit != expectedEntry.commit
                || review.pluginID != expectedEntry.id || review.version != expectedEntry.version
                || review.license != expectedEntry.license || review.loadedPlugin.manifest.kiwiosAPI != expectedEntry.kiwiosAPI {
                await installer.cancel(reviewID: review.id)
                throw PolicyError.blocked("The source manifest does not match the reviewed catalog entry")
            }
            if let existing = try await store?.plugin(id: review.pluginID), existing.sourceRepository != review.repository {
                await installer.cancel(reviewID: review.id)
                throw PolicyError.blocked("This plugin ID is bound to a different source; explicit removal is required before replacing it")
            }
            pendingInstallation = review
        } catch { operationError = error.localizedDescription }
    }
    func cancelInstallation() async {
        guard !marketplaceBusy else { return }
        if let review = pendingInstallation { await installer?.cancel(reviewID: review.id) }
        pendingInstallation = nil
    }
    func approveInstallation(_ review: InstallationReview) async {
        guard pendingInstallation?.id == review.id, !marketplaceBusy, let installer, let store else { return }
        marketplaceBusy = true
        defer { marketplaceBusy = false }
        setPluginTransition(review.pluginID, active: true)
        defer { setPluginTransition(review.pluginID, active: false) }
        do {
            guard mode == .setup else { throw PolicyError.blocked("Install plugin sources in attended setup") }
            let existing = try await store.plugin(id: review.pluginID)
            if let existing, existing.sourceRepository != review.repository { throw PolicyError.blocked("Plugin source changed while reviewing") }
            // Publication does not select a revision. The following database transaction does.
            let installed = try await installer.commit(reviewID: review.id)
            let record = PluginRecord(id: review.pluginID, name: installed.plugin.manifest.name,
                version: installed.plugin.manifest.version, sourceRepository: installed.repository,
                sourceCommit: installed.commit, sourcePath: review.pluginPath,
                manifestDigest: installed.manifestDigest,
                contentDigest: installed.contentDigest, enabled: true,
                lifecycleState: PluginLifecycle.needsSetup.rawValue, updatedAt: Date())
            let approval = ApprovalRecord(pluginID: review.pluginID, manifestDigest: installed.manifestDigest,
                contentDigest: installed.contentDigest, disclosureDigest: installed.manifestDigest,
                sourceRepository: installed.repository, sourceCommit: installed.commit,
                approvedBy: "local", approvedAt: Date())
            try await store.activateInstalledPlugin(record, approval: approval)
            pluginUpdates.removeValue(forKey: review.pluginID)
            pendingInstallation = nil
            await queue?.cancelPlugin(review.pluginID, requestedBy: "local")
            await queue?.waitForPluginToStop(review.pluginID)
            await stopChecks(review.pluginID)
            do { try await installer.complete(reviewID: review.id, activeCommit: installed.commit) }
            catch { operationError = "The revision is active, but snapshot cleanup failed: \(error.localizedDescription)" }
            await reload()
            requestBrewInstallation(packages: review.brew, pluginID: review.pluginID)
        } catch { operationError = error.localizedDescription }
    }
    func requestRemoval(pluginID: String) {
        guard !marketplaceBusy, loaded[pluginID] != nil || installedRecords[pluginID] != nil else { return }
        Task { await prepareRemoval(pluginID: pluginID) }
    }
    private func prepareRemoval(pluginID: String) async {
        guard !marketplaceBusy, let store else { return }
        marketplaceBusy = true
        defer { marketplaceBusy = false }
        do {
            guard let record = try await store.plugin(id: pluginID) else { return }
            let managed = try await store.managedHomebrewFormulae()
            let managedByName = Dictionary(uniqueKeysWithValues: managed.map { ($0.name, $0) })
            let formulae = loaded[pluginID]?.manifest.brew.sorted() ?? []
            var items: [HomebrewRemovalItem] = []
            var staleOwnership: [String] = []
            for formula in formulae {
                let installed = BrewFormulaStatus.isInstalled(formula)
                let managedFormula = managedByName[formula]
                let owned = managedFormula.map {
                    HomebrewCleanupPolicy.owns(
                        $0, currentReceiptIdentity: BrewFormulaStatus.receiptIdentity(formula)
                    )
                } ?? false
                if managedFormula != nil, !installed || !owned { staleOwnership.append(formula) }
                let otherNames = try await enabledPluginsDeclaring(formula, excluding: pluginID)
                    .map(\.manifest.name)
                var dependents: [String]?
                if installed, owned, otherNames.isEmpty {
                    do { dependents = try await nativeCapabilities.installedHomebrewDependents(of: formula) }
                    catch { dependents = nil }
                }
                items.append(HomebrewCleanupPolicy.item(
                    formula: formula, isInstalled: installed,
                    installedByKiwiOS: owned,
                    otherPluginNames: otherNames, installedDependents: dependents
                ))
            }
            if !staleOwnership.isEmpty { try await store.forgetManagedHomebrewFormulae(staleOwnership) }
            guard try await store.plugin(id: pluginID) != nil else { return }
            pendingRemoval = PluginRemovalReview(pluginID: pluginID, name: record.name, homebrew: items)
        } catch { operationError = "Could not prepare plugin removal: \(error.localizedDescription)" }
    }
    func removePlugin(_ review: PluginRemovalReview, homebrewFormulae: [String]) async {
        guard !marketplaceBusy, pendingRemoval?.id == review.id, let store, let configuration,
              (try? await store.plugin(id: review.pluginID)) != nil else { return }
        marketplaceBusy = true
        defer { marketplaceBusy = false }
        do {
            try requireAdmissionsOpen()
            guard mode == .setup else { throw PolicyError.blocked("Remove plugins in attended setup") }
            let allowedFormulae = Set(review.homebrew.filter(\.canUninstall).map(\.formula))
            let selectedFormulae = Set(homebrewFormulae)
            guard selectedFormulae.isSubset(of: allowedFormulae) else {
                throw PolicyError.blocked("The Homebrew cleanup selection changed; review removal again")
            }
            setPluginTransition(review.pluginID, active: true)
            defer { setPluginTransition(review.pluginID, active: false) }
            await queue?.cancelPlugin(review.pluginID, requestedBy: "local")
            await queue?.waitForPluginToStop(review.pluginID)
            let id = review.pluginID
            // Only app-owned, validated ID paths are eligible for removal.
            guard PluginLexicalValidator.pluginID(id) else {
                throw PolicyError.blocked("Invalid plugin ID")
            }
            if loaded[id] != nil {
                try await disableApprovedPlugin(pluginID: id, requestedBy: "local")
            }
            let declaredSecretFields = loaded[id]?.configSchema?.properties.compactMap {
                $0.value.writeOnly ? $0.key : nil
            } ?? []
            let secretFields = Array(Set(try await store.pluginSecretFields(pluginID: id))
                .union(declaredSecretFields)).sorted()
            try await store.beginPluginRemoval(id: id, secretFields: secretFields, requestedBy: "local")
            pendingRemovalIDs.insert(id)
            try await finishRemoval(PendingPluginRemoval(pluginID: id,
                secretFields: secretFields, requestedBy: "local"), store: store,
                configuration: configuration)
            pendingRemoval = nil
            await reload()
            if !selectedFormulae.isEmpty {
                do {
                    try await enqueueNativeOperation(
                        .homebrewUninstall(packages: selectedFormulae.sorted()), requestedBy: "local"
                    )
                } catch {
                    operationError = "\(review.name) was removed, but Homebrew cleanup was not queued: \(error.localizedDescription)"
                }
            }
        } catch { operationError = error.localizedDescription }
    }

    func finishRemoval(
        _ removal: PendingPluginRemoval, store: PersistenceStore,
        configuration: PluginConfiguration, mode: OperationMode = .setup,
        permitRemoteSecretCleanup: Bool = false
    ) async throws {
        guard PluginLexicalValidator.pluginID(removal.pluginID) else {
            throw PolicyError.blocked("Invalid plugin ID in pending removal record")
        }
        try await configuration.deleteWriteOnlySecrets(pluginID: removal.pluginID,
            fields: removal.secretFields, mode: mode,
            permitRemoteRemoval: permitRemoteSecretCleanup)
        let root = storageRoot
        let dataRoot = runner.pluginDataRoot!
        try await Task.detached {
            let code = root.appendingPathComponent("InstalledPlugins").appendingPathComponent(removal.pluginID)
            if FileManager.default.fileExists(atPath: code.path) { try FileManager.default.removeItem(at: code) }
            let data = dataRoot.appendingPathComponent(removal.pluginID)
            if FileManager.default.fileExists(atPath: data.path) { try FileManager.default.removeItem(at: data) }
        }.value
        let prefix = removal.pluginID + "/"
        layout.widgets.removeAll { $0.hasPrefix(prefix) }
        layout.sidebar.removeAll { $0.hasPrefix(prefix) }
        layout.hiddenWidgets = Set(layout.hiddenWidgets.filter { !$0.hasPrefix(prefix) })
        layout.wideWidgets = Set(layout.wideWidgets.filter { !$0.hasPrefix(prefix) })
        try await store.setLayout(key: "home", json: JSONEncoder().encode(layout))
        try await store.finishPluginRemoval(removal)
    }
}
