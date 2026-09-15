import Foundation
import Hummingbird

extension HubRuntime {
    func inspectRemoteReadiness() async -> TailscaleServeState {
        // Restore only in-memory ownership here; readiness never changes Serve.
        // This permits a local retry after Tailscale was offline during app startup.
        if !remote.enabled, let data = try? await store?.layout(key: "remote-trust"),
           let trust = try? JSONDecoder().decode(ManagedServeTrust.self, from: data) {
            _ = try? await tailscaleService.restore(trust)
        }
        return await tailscaleService.inspect()
    }

    func restoreRemoteAccess() async {
        do {
            try await recoverRemotePublication()
            let desired = try await store?.layout(key: "remote-enabled")
                .map { try JSONDecoder().decode(Bool.self, from: $0) } ?? false
            remote.desired = desired
            guard desired else {
                if let data = try await store?.layout(key: "remote-trust"),
                   let trust = try? JSONDecoder().decode(ManagedServeTrust.self, from: data),
                   (try? await tailscaleService.restore(trust)) != nil {
                    try await tailscaleService.stop()
                }
                return
            }
            guard mode == .remote else { return }
            await connectRemoteAccess(scheduleRetry: true)
        } catch {
            remote.message = "Remote access unavailable: \(error.localizedDescription)"
        }
    }

    func startRemoteAccess() async {
        guard !remote.starting, !remote.stopping, !remote.enabled, !stopped, let store else { return }
        do {
            if mode != .remote { await setMode(.remote) }
            guard mode == .remote else { throw PolicyError.blocked("Complete Doctor and choose remote policy before publishing") }
            try await store.setLayout(key: "remote-enabled", json: JSONEncoder().encode(true))
            remote.desired = true
            let previousRetry = remoteRetryTask
            remoteRetryTask = nil
            previousRetry?.cancel()
            await previousRetry?.value
            await connectRemoteAccess(scheduleRetry: true)
        } catch {
            remote.message = "Could not enable remote access: \(error.localizedDescription)"
        }
    }

    private func connectRemoteAccess(scheduleRetry: Bool) async {
        guard !remote.starting, !remote.stopping, !remote.enabled, !stopped, mode == .remote,
              let store else { return }
        remote.starting = true
        defer { remote.starting = false }
        do {
            try await recoverRemotePublication()
            let desired = try await store.layout(key: "remote-enabled")
                .map { try JSONDecoder().decode(Bool.self, from: $0) } ?? false
            guard desired else { return }
            if let data = try await store.layout(key: "remote-trust"),
               let trust = try? JSONDecoder().decode(ManagedServeTrust.self, from: data),
               (try? await tailscaleService.validate(trust)) == true {
                let plan = try await tailscaleService.restore(trust)
                try await startRemoteServer(plan: plan)
                try await activateRemoteServer(trust)
            } else {
                // Bind loopback first, then journal before publishing Serve.
                let plan = try await tailscaleService.prepare()
                try await startRemoteServer(plan: plan)
                try await store.setLayout(key: "remote-publication-attempt", json: JSONEncoder().encode(plan))
                let trust = try await tailscaleService.start(plan: plan)
                try await store.setLayouts([
                    "remote-enabled": try JSONEncoder().encode(true),
                    "remote-publication-attempt": try JSONEncoder().encode(Optional<RemotePublicationPlan>.none),
                    "remote-trust": try JSONEncoder().encode(trust),
                ])
                try await activateRemoteServer(trust)
            }
            try await audit("remote.enabled", pluginID: nil)
        } catch {
            remote.enabled = false
            remote.origin = nil
            remote.challenges.removeAll()
            remote.nativeChallenges.removeAll()
            await cancelRemotePluginChallenges()
            await remoteServer.stop()
            do {
                try await tailscaleService.stop()
                try await clearRemotePublicationAttempt()
            } catch { operationError = "Remote cleanup needs attention: \(error.localizedDescription)" }
            remote.message = "Remote access unavailable: \(error.localizedDescription). KiwiOS will retry while it remains enabled."
            if scheduleRetry { scheduleRemoteRetry() }
        }
    }

    private func recoverRemotePublication() async throws {
        guard let store, let data = try await store.layout(key: "remote-publication-attempt"),
              let plan = try JSONDecoder().decode(RemotePublicationPlan?.self, from: data) else { return }
        try await tailscaleService.recoverPublicationAttempt(plan)
        try await clearRemotePublicationAttempt()
    }

    private func clearRemotePublicationAttempt() async throws {
        try await store?.setLayout(key: "remote-publication-attempt",
            json: JSONEncoder().encode(Optional<RemotePublicationPlan>.none))
    }

    func startRemoteServer(plan: RemotePublicationPlan) async throws {
        guard !stopped, !remote.stopping, mode == .remote else { throw CancellationError() }
        try await remoteServer.start(plan: plan, snapshot: { [weak self] identity, deadline in
            guard let self else { throw CancellationError() }
            return try await self.remoteSnapshot(for: identity, deadline: deadline)
        }, mutate: { [weak self] mutation, identity, deadline in
            guard let self else { throw CancellationError() }
            return try await self.remoteMutate(mutation, identity: identity, deadline: deadline)
        }, artifact: { [weak self] token, resource in
            guard let self else { throw CancellationError() }
            return try await self.artifactResponse(token: token, resource: resource)
        }, onTermination: { [weak self] in
            await self?.remoteServerTerminated()
        })
    }
    func activateRemoteServer(_ trust: ManagedServeTrust) async throws {
        guard !stopped, !remote.stopping, mode == .remote else { throw CancellationError() }
        let tailscale = tailscaleService
        try await remoteServer.activate(trust: trust) { current in try await tailscale.validate(current) }
        guard !stopped, !remote.stopping, mode == .remote else { throw CancellationError() }
        remote.enabled = true
        remote.origin = trust.origin
        remote.message = "Available on your tailnet after login"
    }
    func remoteServerTerminated() async {
        remote.enabled = false
        remote.origin = nil
        remote.message = "Remote backend stopped; KiwiOS will retry"
        remote.challenges.removeAll()
        remote.nativeChallenges.removeAll()
        await cancelRemotePluginChallenges()
        guard !remote.stopping, !remote.starting, !stopped else { return }
        do { try await tailscaleService.stop() }
        catch { operationError = "Serve cleanup needs attention: \(error.localizedDescription)" }
        scheduleRemoteRetry()
    }

    private func scheduleRemoteRetry() {
        guard remoteRetryTask == nil, !remote.stopping, !stopped else { return }
        remoteRetryTask = Task { [weak self] in
            guard let self else { return }
            for delay in [1, 2, 4, 8, 16] {
                do { try await Task.sleep(for: .seconds(delay)) }
                catch { break }
                guard !self.stopped, !self.remote.stopping, self.mode == .remote,
                      let desiredData = try? await self.store?.layout(key: "remote-enabled"),
                      (try? JSONDecoder().decode(Bool.self, from: desiredData)) == true else { break }
                let state = await self.tailscaleService.inspect()
                if case .conflict = state.status { break }
                if state.unavailability == .httpsUnavailable { break }
                await self.connectRemoteAccess(scheduleRetry: false)
                if self.remote.enabled { break }
            }
            self.remoteRetryTask = nil
        }
    }
    func stopRemoteAccess() async {
        guard !remote.stopping else { return }
        let previousRetry = remoteRetryTask
        remoteRetryTask = nil
        previousRetry?.cancel()
        await previousRetry?.value
        remote.stopping = true
        defer { remote.stopping = false }
        // Start/restore sees remote.stopping and rolls back before this teardown begins.
        // Finish cleanup even if the caller's UI task was canceled.
        while remote.starting {
            await Task.detached { try? await Task.sleep(for: .milliseconds(25)) }.value
        }
        remote.enabled = false
        remote.desired = false
        remote.origin = nil
        remote.challenges.removeAll()
        remote.nativeChallenges.removeAll()
        await cancelRemotePluginChallenges()
        await remoteServer.stop()
        do {
            try await store?.setLayout(key: "remote-enabled", json: JSONEncoder().encode(false))
            try await audit("remote.disabled", pluginID: nil)
        } catch { operationError = "Could not persist remote disable: \(error.localizedDescription)" }
        do {
            try await tailscaleService.stop()
            try await clearRemotePublicationAttempt()
            remote.message = "Remote access is off"
        } catch { remote.message = "Backend stopped; Serve configuration needs attention: \(error.localizedDescription)" }
    }

    func remoteSnapshot(for identity: RemoteIdentity, deadline: RemoteRequestDeadline) async throws -> Data {
        guard remote.enabled, mode == .remote, !stopped, !reloadInProgress else {
            throw PolicyError.blocked("Remote access is unavailable")
        }
        try deadline.check()
        refreshNativeToolsIfNeeded()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var pluginValues: [JSONValue] = []
        for plugin in plugins {
            try deadline.check()
            let missingBrew = plugin.manifest.brew.filter { !BrewFormulaStatus.isInstalled($0) }
            let canEnableRemotely = await remoteEnableAvailable(pluginID: plugin.id)
            let requiresWebReview = canEnableRemotely ? !(await remoteEnableIsApproved(pluginID: plugin.id)) : false
            let enableBlocker = canEnableRemotely ? await remoteEnableBlocker(pluginID: plugin.id) : plugin.message
            let configSchema = loaded[plugin.id]?.configSchema
            let canConfigureRemotely = configSchema?.properties.values.contains(where: { $0.writeOnly }) == false
            var value: [String: JSONValue] = [
                "id": .string(plugin.id), "name": .string(plugin.manifest.name),
                "description": plugin.manifest.description.map(JSONValue.string) ?? .null,
                "version": .string(plugin.manifest.version), "lifecycle": .string(plugin.lifecycle.rawValue),
                "setup": .string(plugin.setupRequirement.rawValue),
                "configuration": .object([
                    "available": .bool(configSchema != nil), "remote": .bool(canConfigureRemotely),
                ]),
                "message": .string(plugin.message), "results": try Self.wire(plugin.results, encoder: encoder),
                "resultDates": try Self.wire(plugin.resultDates, encoder: encoder),
                "liveResults": try Self.wire(plugin.liveResults, encoder: encoder),
                "watch": plugin.manifest.watch.map { watch in .object([
                    "status": .string(watch.status),
                    "start": watch.start.map(JSONValue.string) ?? .null,
                ]) } ?? .null,
                "checks": .array(plugin.manifest.checks.map { check in .object([
                    "id": .string(check.id), "label": .string(check.label),
                    "every": check.every.map { .number($0.seconds) } ?? .null]) }),
                "actions": .array(plugin.manifest.actions.map { .object([
                    "id": .string($0.id), "label": .string($0.label), "confirm": .bool($0.confirm),
                    "resource": .string("\(plugin.id)/\($0.lock ?? "action-\($0.id)")")]) }),
                "pages": .array(plugin.manifest.ui.pages.map { .object([
                    "id": .string($0.id), "title": .string($0.title), "kind": .string($0.kind.rawValue), "source": .string($0.source)]) }),
                "widgets": .array(plugin.manifest.ui.widgets.map { .object([
                    "id": .string($0.id), "title": .string($0.title), "kind": .string($0.kind.rawValue), "source": .string($0.source), "size": .string($0.size)]) }),
                "sidebar": .array(plugin.manifest.ui.sidebar.map { .object([
                    "id": .string($0.id), "label": .string($0.label), "page": .string($0.page)]) }),
                "missingBrew": .array(missingBrew.map(JSONValue.string)),
                "sourceRepository": installedRecords[plugin.id]?.sourceRepository.map(JSONValue.string) ?? .null,
                "canEnableRemotely": .bool(canEnableRemotely),
                "requiresWebReview": .bool(requiresWebReview),
                "enableBlocker": enableBlocker.map(JSONValue.string) ?? .null,
                "update": pluginUpdates[plugin.id].map { .object([
                    "commit": .string($0.commit), "version": .string($0.version),
                ]) } ?? .null,
            ]
            if let schema = configSchema {
                var properties: [String: JSONValue] = [:]
                for (key, field) in schema.properties {
                    properties[key] = .object([
                        "type": .string(field.type.rawValue), "title": .string(field.title ?? key),
                        "description": field.description.map(JSONValue.string) ?? .null,
                        "warning": field.warning.map(JSONValue.string) ?? .null,
                        "writeOnly": .bool(field.writeOnly), "required": .bool(field.required),
                        "enumValues": field.writeOnly ? .null : field.enumValues.map(JSONValue.array) ?? .null,
                        "defaultValue": field.writeOnly ? .null : field.defaultValue ?? .null,
                    ])
                }
                value["configSchema"] = .object(["properties": .object(properties),
                    "title": .string(schema.title ?? "Configuration"), "description": .string(schema.description ?? "")])
                guard let loadedPlugin = loaded[plugin.id], let configuration else {
                    throw PolicyError.blocked("Plugin configuration is unavailable")
                }
                let snapshot = try await configuration.snapshot(for: loadedPlugin)
                try deadline.check()
                value["config"] = .object(snapshot.values.filter { schema.properties[$0.key]?.writeOnly == false })
                value["configRevision"] = .number(Double(snapshot.revision))
            }
            pluginValues.append(.object(value))
        }
        let visibleJobs = jobs
        try deadline.check()
        let jobValues: [JSONValue] = visibleJobs.map { job in
            let value: [String: JSONValue] = [
                "id": .string(job.id.uuidString), "pluginID": .string(job.pluginID),
                "contributionID": .string(job.contributionID), "kind": .string(job.kind.rawValue),
                "status": .string(job.status.rawValue),
                "resource": .string(job.resource),
            ]
            return .object(value)
        }
        let nativeTools = try native.toolsSnapshot.map {
            try Self.remoteNativeTools($0, sshPeerNames: native.peers.map(\.name), encoder: encoder)
        } ?? .null
        let catalogValues: [JSONValue] = curatedEntries.map { entry in
            .object([
                "id": .string(entry.id), "name": .string(entry.name),
                "description": entry.description.map(JSONValue.string) ?? .null,
                "repository": .string(entry.repository), "commit": .string(entry.commit),
                "path": .string(entry.path), "version": .string(entry.version),
                "kiwiosAPI": .string(entry.kiwiosAPI), "license": .string(entry.license),
            ])
        }
        var searchResults: [JSONValue] = []
        searchResults.reserveCapacity(pluginSearchResults.count)
        for result in pluginSearchResults {
            searchResults.append(.object([
                "name": .string(result.name), "repository": .string(result.repository),
                "description": result.description.map(JSONValue.string) ?? .null,
                "stars": .number(Double(result.stars)),
                "updatedAt": try Self.wire(result.updatedAt, encoder: encoder),
                "owner": .string(result.owner),
            ]))
        }
        let snapshot: [String: JSONValue] = [
            "api": .string("kiwios.remote/1"), "mode": .string(mode.rawValue),
            "viewer": .object(["loginName": .string(identity.login), "displayName": .string(identity.displayName)]),
            "availability": .string("Available only after the owning Mac user logs in and unlocks FileVault"),
            "plugins": .array(pluginValues), "jobs": .array(jobValues),
            "installingPluginIDs": .array(pluginTransitions.sorted().map(JSONValue.string)),
            "catalog": .array(catalogValues),
            "pluginSearch": .object([
                "query": .string(pluginSearchQuery),
                "error": pluginSearchError.map(JSONValue.string) ?? .null,
                "searchedAt": try pluginSearchSearchedAt.map { try Self.wire($0, encoder: encoder) } ?? .null,
                "results": .array(searchResults),
            ]),
            "nativeTools": nativeTools, "nativeToolsRefreshing": .bool(native.toolsRefreshing),
            "layout": try Self.wire(layout, encoder: encoder),
            "settings": .object([
                "operationMode": .object([
                    "value": .string(mode.rawValue),
                    "guidance": .string("Attended setup mode can only be selected on the Mac because it permits system prompts."),
                ]),
                "launchAtLogin": .object([
                    "status": .string(doctorFindings.first(where: { $0.id == "launch-at-login" })?.status.rawValue ?? "unknown"),
                    "detail": .string(doctorFindings.first(where: { $0.id == "launch-at-login" })?.detail ?? "Refresh Doctor to inspect launch-at-login status."),
                    "guidance": .string("Change launch-at-login on the Mac; macOS may require approval in System Settings."),
                ]),
                "remoteAccess": .object([
                    "enabled": .bool(remote.enabled), "desired": .bool(remote.desired),
                    "message": .string(remote.message),
                    "guidance": .string("Enable, disable, and recover Tailscale Serve from the Mac so the local recovery path remains available."),
                ]),
                "developmentPlugins": .object([
                    "configured": .bool(developmentDirectory != nil),
                    "guidance": .string("Choose or remove the development plugin directory in attended setup on the Mac."),
                ]),
                "namedSecrets": .object([
                    "guidance": .string("Save or replace Keychain secrets in attended setup on the Mac. KiwiOS never exposes their values remotely."),
                ]),
            ]),
            "doctor": .array(doctorFindings.map { .object(["id": .string($0.id), "title": .string($0.title),
                "status": .string($0.status.rawValue), "detail": .string($0.detail)]) }),
        ]
        let encoded = try encoder.encode(JSONValue.object(snapshot))
        try deadline.check()
        guard encoded.count <= 8 * 1024 * 1024 else { throw PolicyError.blocked("Remote snapshot exceeds its size limit; narrow plugin results") }
        return encoded
    }

    func remoteMutate(_ mutation: RemoteMutation, identity: RemoteIdentity,
                      deadline: RemoteRequestDeadline) async throws -> Data {
        guard remote.enabled, mode == .remote, !stopped, !reloadInProgress, !reloading, let queue else {
            throw PolicyError.blocked("Remote mutations require the active remote runtime")
        }
        try requireAdmissionsOpen()
        policyOperations += 1
        defer { policyOperations -= 1 }
        try deadline.check()
        let actor = identity.auditActor
        await pruneRemotePluginChallenges()
        remote.challenges = remote.challenges.filter { $0.value.confirmation.expiresAt > Date() }
        remote.nativeChallenges = remote.nativeChallenges.filter { $0.value.expiresAt > Date() }
        remote.artifactChallenges = remote.artifactChallenges.filter { $0.value.expiresAt > Date() }
        remote.artifactGrants = remote.artifactGrants.filter { $0.value.expiresAt > Date() }
        switch mutation.operation {
        case .refreshCheck:
            guard let id = mutation.pluginID, let check = mutation.contributionID,
                  loaded[id]?.manifest.checks.contains(where: { $0.id == check }) == true else { throw PolicyError.blocked("Unknown check") }
            try requireEnabled(id)
            return try await remoteAdmission(JobRequest(id: mutation.requestID, pluginID: id,
                contributionID: check, kind: .check, resource: "check-\(check)", requestedBy: actor), deadline: deadline)
        case .requestAction:
            guard let id = mutation.pluginID, let actionID = mutation.contributionID,
                  let action = loaded[id]?.manifest.actions.first(where: { $0.id == actionID }),
                  let fingerprint = fingerprints[id] else { throw PolicyError.blocked("Unknown action") }
            try requireEnabled(id)
            if action.confirm {
                guard remote.challenges.count < 64 else { throw PolicyError.blocked("Too many pending confirmations") }
                let token = try RemoteSecurity.randomToken()
                let confirmation = ActionConfirmation(id: UUID(), pluginID: id, actionID: actionID,
                    label: action.label, digest: fingerprint.contentDigest, expiresAt: Date().addingTimeInterval(60))
                remote.challenges[token] = RemoteActionChallenge(identity: identity, confirmation: confirmation)
                try await audit("action.confirmation-issued", pluginID: id, requestedBy: actor)
                return try JSONEncoder().encode(JSONValue.object(["confirmationToken": .string(token),
                    "label": .string(action.label), "expiresIn": .number(60)]))
            }
            return try await remoteAdmission(JobRequest(id: mutation.requestID, pluginID: id,
                contributionID: actionID, kind: .action, resource: action.lock ?? "action-\(actionID)", requestedBy: actor), deadline: deadline)
        case .confirmAction:
            guard let token = mutation.confirmationToken,
                  let challenge = remote.challenges.removeValue(forKey: token), challenge.identity == identity,
                  challenge.confirmation.expiresAt > Date() else { throw PolicyError.blocked("Confirmation expired, consumed, or belongs to another identity") }
            let confirmation = challenge.confirmation
            try requireEnabled(confirmation.pluginID)
            guard fingerprints[confirmation.pluginID]?.contentDigest == confirmation.digest,
                  let action = loaded[confirmation.pluginID]?.manifest.actions.first(where: { $0.id == confirmation.actionID }) else {
                throw PolicyError.blocked("Action or approved source changed")
            }
            confirmationGrants[mutation.requestID] = confirmation
            do {
                return try await remoteAdmission(JobRequest(id: mutation.requestID, pluginID: confirmation.pluginID,
                    contributionID: confirmation.actionID, kind: .action,
                    resource: action.lock ?? "action-\(confirmation.actionID)", requestedBy: actor), deadline: deadline)
            } catch { confirmationGrants.removeValue(forKey: mutation.requestID); throw error }
        case .cancelJob:
            guard let id = mutation.jobID else { throw PolicyError.blocked("Missing job ID") }
            try deadline.check()
            nativeGrants.removeValue(forKey: id)
            confirmationGrants.removeValue(forKey: id)
            try await queue.cancel(id, requestedBy: actor)
        case .disablePlugin:
            guard let id = mutation.pluginID else { throw PolicyError.blocked("Missing plugin ID") }
            try deadline.check()
            try await disableApprovedPlugin(pluginID: id, requestedBy: actor)
        case .enablePlugin:
            guard let id = mutation.pluginID else { throw PolicyError.blocked("Missing plugin ID") }
            try deadline.check()
            if await remoteEnableIsApproved(pluginID: id) {
                try await enableApprovedPlugin(pluginID: id, requestedBy: actor)
            } else {
                return try await stageRemotePluginEnableReview(pluginID: id, identity: identity,
                    requestedBy: actor, deadline: deadline)
            }
        case .requestPluginDependencies:
            guard let id = mutation.pluginID, let plugin = loaded[id] else {
                throw PolicyError.blocked("Missing plugin ID")
            }
            let packages = try await remoteMissingBrew(pluginID: id)
            guard !packages.isEmpty else { throw PolicyError.blocked("All declared Homebrew packages are already installed") }
            let operation = NativeOperation.homebrewInstall(packages: packages)
            try await validateNativeOperation(operation, requestedBy: actor, originPluginID: id)
            try deadline.check()
            guard remote.nativeChallenges.count < 64 else {
                throw PolicyError.blocked("Too many pending confirmations")
            }
            let token = try RemoteSecurity.randomToken()
            remote.nativeChallenges[token] = RemoteNativeChallenge(identity: identity, operation: operation,
                expiresAt: Date().addingTimeInterval(60), originPluginID: id)
            try await audit("plugin.dependencies-confirmation-issued", pluginID: id, requestedBy: actor)
            return try JSONEncoder().encode(JSONValue.object([
                "confirmationToken": .string(token),
                "label": .string(operation.confirmationTitle ?? "Install Homebrew packages?"),
                "expiresIn": .number(60),
                "confirmationOperation": .string(RemoteMutation.Operation.confirmNativeOperation.rawValue),
                "review": .object([
                    "pluginID": .string(id), "name": .string(plugin.manifest.name),
                    "brew": .array(packages.sorted().map(JSONValue.string)),
                    "warning": .string("KiwiOS will run Homebrew locally on this Mac. The exact declared packages are checked again before installation."),
                ]),
            ]))
        case .confirmPluginEnable:
            guard let token = mutation.confirmationToken,
                  let challenge = remote.pluginEnableChallenges[token],
                  challenge.isValid(for: identity) else {
                throw PolicyError.blocked("Source review expired, was consumed, or belongs to another identity")
            }
            remote.pluginEnableChallenges.removeValue(forKey: token)
            try deadline.check()
            try await approvePluginReview(challenge.review, requestedBy: actor, installBrew: false)
        case .requestPluginInstall:
            guard let repository = mutation.repository else { throw PolicyError.blocked("Missing plugin source") }
            if let catalogID = mutation.catalogID {
                guard let commit = mutation.commit, let pluginPath = mutation.pluginPath else {
                    throw PolicyError.blocked("Catalog install requires commit, pluginPath, and catalogID")
                }
                guard let entry = curatedEntries.first(where: { $0.id == catalogID }) else {
                    throw PolicyError.blocked("Unknown catalog plugin")
                }
                guard entry.repository == repository, entry.commit == commit, entry.path == pluginPath else {
                    throw PolicyError.blocked("Catalog install fields do not match the bundled catalog entry")
                }
                return try await stageRemotePluginInstallation(
                    repository: entry.repository, commit: entry.commit, path: entry.path,
                    expectedEntry: entry, identity: identity, requestedBy: actor, deadline: deadline)
            }
            return try await stageRemotePluginInstallation(repository: repository,
                identity: identity, requestedBy: actor, deadline: deadline)
        case .searchPlugins:
            let query = mutation.query ?? ""
            try deadline.check()
            do {
                let results = try await pluginCatalog.search(query)
                try deadline.check()
                pluginSearchQuery = query
                pluginSearchResults = results
                pluginSearchError = nil
                pluginSearchSearchedAt = Date()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                pluginSearchQuery = query
                pluginSearchResults = []
                pluginSearchError = error.localizedDescription
                pluginSearchSearchedAt = Date()
            }
            return Data("{}".utf8)
        case .requestPluginUpdate:
            guard let id = mutation.pluginID, let record = installedRecords[id],
                  let repository = record.sourceRepository, let update = pluginUpdates[id] else {
                throw PolicyError.blocked("No plugin update is available")
            }
            return try await stageRemotePluginInstallation(repository: repository, commit: update.commit,
                path: record.sourcePath ?? ".", identity: identity, requestedBy: actor, deadline: deadline)
        case .confirmPluginInstall:
            guard let token = mutation.confirmationToken,
                  let challenge = remote.installationChallenges[token],
                  challenge.isValid(for: identity) else {
                throw PolicyError.blocked("Installation review expired, was consumed, or belongs to another identity")
            }
            remote.installationChallenges.removeValue(forKey: token)
            try deadline.check()
            try await installRemotelyApprovedPlugin(
                challenge.review, missingBrew: challenge.missingBrew, requestedBy: actor, deadline: deadline)
        case .requestPluginRemoval:
            guard let id = mutation.pluginID else { throw PolicyError.blocked("Missing plugin ID") }
            return try await requestRemotePluginRemoval(pluginID: id, identity: identity,
                requestedBy: actor, deadline: deadline)
        case .confirmPluginRemoval:
            guard let token = mutation.confirmationToken,
                  let challenge = remote.removalChallenges[token],
                  challenge.isValid(for: identity) else {
                throw PolicyError.blocked("Removal review expired, was consumed, or belongs to another identity")
            }
            remote.removalChallenges.removeValue(forKey: token)
            try deadline.check()
            try await removeRemotelyApprovedPlugin(challenge.review, requestedBy: actor, deadline: deadline)
        case .saveConfig:
            guard let id = mutation.pluginID, let values = mutation.values, let revision = mutation.configRevision,
                  let plugin = loaded[id], let configuration else { throw PolicyError.blocked("Unknown plugin configuration") }
            try deadline.check()
            guard !pluginTransitions.contains(id), !pendingRemovalIDs.contains(id) else { throw PolicyError.blocked("Plugin installation is changing") }
            _ = try await configuration.save(values, expectedRevision: revision, for: plugin, mode: .remote)
            try await audit("plugin.config-saved", pluginID: id, requestedBy: actor)
            await refreshDoctor()
        case .refreshDoctor:
            try deadline.check()
            await refreshDoctor()
        case .saveLayout:
            guard let widgets = mutation.widgets, let hiddenWidgets = mutation.hiddenWidgets,
                  let wideWidgets = mutation.wideWidgets, let sidebar = mutation.sidebar else {
                throw PolicyError.blocked("Missing layout values")
            }
            try deadline.check()
            let changed = try remoteLayout(widgets: widgets, hiddenWidgets: hiddenWidgets,
                wideWidgets: wideWidgets, sidebar: sidebar)
            try await store?.setLayout(key: "home", json: JSONEncoder().encode(changed))
            layout = changed
            try await audit("layout.saved", pluginID: nil, requestedBy: actor)
        case .reloadPlugins:
            try deadline.check()
            await reload()
        case .refreshNativeTools:
            try deadline.check()
            native.generation += 1
            native.toolsSnapshot = nil
            startNativeToolsRefresh()
        case .requestProcessTermination:
            guard let pid = mutation.pid else { throw PolicyError.blocked("Missing process ID") }
            let operation = NativeOperation.terminateProcess(try await nativeCapabilities.terminableProcess(pid: pid))
            try await validateNativeOperation(operation, requestedBy: actor)
            try deadline.check()
            guard remote.nativeChallenges.count < 64 else {
                throw PolicyError.blocked("Too many pending confirmations")
            }
            let token = try RemoteSecurity.randomToken()
            remote.nativeChallenges[token] = RemoteNativeChallenge(
                identity: identity, operation: operation, expiresAt: Date().addingTimeInterval(60), originPluginID: nil
            )
            try await audit("native.confirmation-issued", pluginID: nil, requestedBy: actor)
            return try JSONEncoder().encode(JSONValue.object([
                "confirmationToken": .string(token),
                "label": .string(operation.confirmationTitle ?? "Quit process?"),
                "expiresIn": .number(60),
                "confirmationOperation": .string(RemoteMutation.Operation.confirmNativeOperation.rawValue),
            ]))
        case .requestLaunchAgentRestart:
            guard let label = mutation.launchAgentLabel else {
                throw PolicyError.blocked("Missing LaunchAgent label")
            }
            let operation = NativeOperation.kickstartLaunchAgent(label: label)
            try await validateNativeOperation(operation, requestedBy: actor)
            try deadline.check()
            guard remote.nativeChallenges.count < 64 else {
                throw PolicyError.blocked("Too many pending confirmations")
            }
            let token = try RemoteSecurity.randomToken()
            remote.nativeChallenges[token] = RemoteNativeChallenge(
                identity: identity, operation: operation, expiresAt: Date().addingTimeInterval(60), originPluginID: nil
            )
            try await audit("native.confirmation-issued", pluginID: nil, requestedBy: actor)
            return try JSONEncoder().encode(JSONValue.object([
                "confirmationToken": .string(token),
                "label": .string(operation.confirmationTitle ?? "Restart LaunchAgent?"),
                "expiresIn": .number(60),
                "confirmationOperation": .string(RemoteMutation.Operation.confirmNativeOperation.rawValue),
            ]))
        case .confirmNativeOperation:
            guard let token = mutation.confirmationToken,
                  let challenge = remote.nativeChallenges[token], challenge.isValid(for: identity) else {
                throw PolicyError.blocked("Confirmation expired, consumed, or belongs to another identity")
            }
            remote.nativeChallenges.removeValue(forKey: token)
            try deadline.check()
            try await validateNativeOperation(challenge.operation, requestedBy: actor,
                originPluginID: challenge.originPluginID)
            try deadline.check()
            try await enqueueNativeOperation(challenge.operation, requestedBy: actor,
                originPluginID: challenge.originPluginID)
        case .probeSSH:
            guard let peerName = mutation.peerName else { throw PolicyError.blocked("Missing SSH peer name") }
            try deadline.check()
            try await enqueueNativeOperation(.probeSSH(peerName: peerName), requestedBy: actor)
        case .deliverNotification:
            guard let title = mutation.title, let body = mutation.body else {
                throw PolicyError.blocked("Missing notification content")
            }
            try deadline.check()
            try await enqueueNativeOperation(.deliverNotification(title: title, body: body), requestedBy: actor)
        case .requestArtifactInstall:
            return try await requestArtifactInstall(mutation, identity: identity, requestedBy: actor)
        case .confirmArtifactInstall:
            return try await confirmArtifactInstall(mutation, identity: identity, requestedBy: actor)
        }
        await refreshResults()
        return try JSONEncoder().encode(JSONValue.object(["ok": .bool(true)]))
    }

    private func requestArtifactInstall(
        _ mutation: RemoteMutation, identity: RemoteIdentity, requestedBy: String
    ) async throws -> Data {
        guard let pluginID = mutation.pluginID, let artifactID = mutation.artifactID else {
            throw PolicyError.blocked("Missing install target")
        }
        try requireEnabled(pluginID)
        let item = try await validatedArtifact(pluginID: pluginID, artifactID: artifactID)
        guard remote.artifactChallenges.count < 8 else {
            throw PolicyError.blocked("Too many pending install confirmations")
        }
        let token = try RemoteSecurity.randomToken()
        let label = "Install \(item.project) \(item.version) (\(item.build)) on this iPhone?"
        remote.artifactChallenges[token] = ArtifactInstallChallenge(
            identity: identity, pluginID: pluginID, artifactID: artifactID, sha256: item.sha256,
            label: label, expiresAt: Date().addingTimeInterval(60)
        )
        try await audit("artifact.confirmation-issued", pluginID: pluginID, requestedBy: requestedBy)
        return try JSONEncoder().encode(JSONValue.object([
            "confirmationToken": .string(token),
            "label": .string(label),
            "expiresIn": .number(60),
            "confirmationOperation": .string(RemoteMutation.Operation.confirmArtifactInstall.rawValue),
            "review": .object([
                "pluginID": .string(pluginID),
                "warning": .string(
                    "Open KiwiOS in iPhone Safari (not the Home Screen web app). iOS will ask to install. Signing and device registration are Apple's. Cleanup can delete this file after you tap; the file is checked again before download."
                ),
            ]),
        ]))
    }

    private func confirmArtifactInstall(
        _ mutation: RemoteMutation, identity: RemoteIdentity, requestedBy: String
    ) async throws -> Data {
        guard let token = mutation.confirmationToken,
              let challenge = remote.artifactChallenges.removeValue(forKey: token),
              challenge.identity == identity, challenge.expiresAt > Date() else {
            throw PolicyError.blocked("Confirmation expired, consumed, or belongs to another identity")
        }
        try requireEnabled(challenge.pluginID)
        guard let origin = remote.origin else { throw PolicyError.blocked("Remote access is not published") }
        remote.artifactGrants = remote.artifactGrants.filter { $0.value.expiresAt > Date() }
        guard remote.artifactGrants.count < ArtifactDelivery.maximumConcurrentGrants else {
            throw PolicyError.blocked("Too many installs in progress; wait for one to finish")
        }
        let item = try await validatedArtifact(pluginID: challenge.pluginID, artifactID: challenge.artifactID)
        guard item.sha256 == challenge.sha256 else { throw PolicyError.blocked("The IPA changed after you started install") }
        let grantToken = try RemoteSecurity.randomToken()
        remote.artifactGrants[grantToken] = ArtifactGrant(
            pluginID: challenge.pluginID, artifactID: item.id, sha256: item.sha256, size: item.size,
            fileURL: item.fileURL, bundleID: item.bundleID, version: item.version, title: item.title,
            expiresAt: Date().addingTimeInterval(ArtifactDelivery.grantLifetime),
            remainingManifestGets: 5, remainingIPAGets: 5
        )
        try await audit("artifact.install-granted", pluginID: challenge.pluginID, requestedBy: requestedBy)
        return try JSONEncoder().encode(JSONValue.object([
            "installURL": .string(ArtifactDelivery.encodedInstallURL(origin: origin, token: grantToken)),
            "guidance": .string("Open KiwiOS in iPhone Safari to finish install. The Home Screen web app cannot start an iOS install."),
        ]))
    }

    private struct ValidatedArtifact {
        let id: String
        let sha256: String
        let size: Int64
        let fileURL: URL
        let bundleID: String
        let version: String
        let title: String
        let project: String
        let build: String
    }

    private func validatedArtifact(pluginID: String, artifactID: String) async throws -> ValidatedArtifact {
        guard let plugin = loaded[pluginID] else { throw PolicyError.blocked("Unknown plugin") }
        guard plugin.manifest.depends["native.artifact-delivery"] != nil else {
            throw PolicyError.blocked("This plugin cannot install builds")
        }
        guard let configuration else { throw PolicyError.blocked("Plugin configuration is unavailable") }
        let snapshot = try await configuration.snapshot(for: plugin)
        guard case .string(let rawRoot)? = snapshot.values["library_root"] else {
            throw PolicyError.blocked("Set the build library folder in Configure")
        }
        let root = try ArtifactDelivery.libraryRoot(rawRoot, home: FileManager.default.homeDirectoryForCurrentUser.path)
        let indexURL = runner.pluginDataRoot!.appendingPathComponent(pluginID, isDirectory: true)
            .appendingPathComponent("index.v1.json")
        let items = try ArtifactDelivery.loadIndex(at: indexURL)
        guard let item = items.first(where: { $0.id == artifactID }) else {
            throw PolicyError.blocked("That build is no longer in the library")
        }
        let fileURL = try ArtifactDelivery.revalidate(item, root: root)
        return ValidatedArtifact(
            id: item.id, sha256: item.sha256, size: item.size, fileURL: fileURL,
            bundleID: item.bundleID, version: item.version, title: item.title,
            project: item.project, build: item.build
        )
    }

    func artifactResponse(token: String, resource: String) async throws -> Response {
        remote.artifactGrants = remote.artifactGrants.filter { $0.value.expiresAt > Date() }
        guard var grant = remote.artifactGrants[token], grant.expiresAt > Date() else {
            throw PolicyError.blocked("This install link expired; tap Install again")
        }
        let fileURL = try ArtifactDelivery.revalidate(
            ArtifactDelivery.IndexItem(
                id: grant.artifactID, status: "valid", relativeDir: grant.fileURL.deletingLastPathComponent().lastPathComponent,
                ipa: grant.fileURL.lastPathComponent, sha256: grant.sha256, size: grant.size, project: grant.title,
                title: grant.title, version: grant.version, build: grant.version, bundleID: grant.bundleID,
                createdAt: ""
            ),
            root: grant.fileURL.deletingLastPathComponent().deletingLastPathComponent()
        )
        switch resource {
        case "manifest.plist":
            guard grant.remainingManifestGets > 0 else { throw PolicyError.blocked("This install link was used too many times") }
            grant.remainingManifestGets -= 1
            remote.artifactGrants[token] = grant
            guard let origin = remote.origin else { throw PolicyError.blocked("Remote access is not published") }
            let ipa = origin.appending(path: "ota").appending(path: token).appending(path: "app.ipa").absoluteString
            let data = ArtifactDelivery.manifestPlist(grant: grant, ipaURL: ipa)
            return ArtifactDelivery.dataResponse(data, contentType: "application/xml")
        case "app.ipa":
            guard grant.remainingIPAGets > 0 else { throw PolicyError.blocked("This install link was used too many times") }
            grant.remainingIPAGets -= 1
            remote.artifactGrants[token] = grant
            let digest = try ArtifactDelivery.sha256(of: fileURL)
            guard digest == grant.sha256 else {
                remote.artifactGrants.removeValue(forKey: token)
                throw PolicyError.blocked("The IPA changed; tap Install again")
            }
            return ArtifactDelivery.fileResponse(url: fileURL, size: grant.size, contentType: "application/octet-stream")
        default:
            throw PolicyError.blocked("Unknown install file")
        }
    }

    private func pruneRemotePluginChallenges() async {
        let now = Date()
        let expired = remote.installationChallenges.filter { $0.value.expiresAt <= now }
        remote.pluginEnableChallenges = remote.pluginEnableChallenges.filter { $0.value.expiresAt > now }
        remote.installationChallenges = remote.installationChallenges.filter { $0.value.expiresAt > now }
        remote.removalChallenges = remote.removalChallenges.filter { $0.value.expiresAt > now }
        for challenge in expired.values { await installer?.cancel(reviewID: challenge.review.id) }
    }

    func cancelRemotePluginChallenges() async {
        let staged = remote.installationChallenges.values.map(\.review.id)
        remote.pluginEnableChallenges.removeAll()
        remote.installationChallenges.removeAll()
        remote.removalChallenges.removeAll()
        for reviewID in staged { await installer?.cancel(reviewID: reviewID) }
    }

    private func stageRemotePluginInstallation(
        repository: String, commit: String? = nil, path: String = ".",
        expectedEntry: CuratedPluginEntry? = nil, identity: RemoteIdentity,
        requestedBy: String, deadline: RemoteRequestDeadline
    ) async throws -> Data {
        guard let installer, let store else { throw PolicyError.blocked("Plugin installer is unavailable") }
        guard remote.installationChallenges.count < 4 else {
            throw PolicyError.blocked("Too many staged plugin reviews; confirm or wait for an existing review to expire")
        }
        let revision: String
        if let commit { revision = commit }
        else { revision = try await installer.latestCommit(repository: repository) }
        try deadline.check()
        let review = try await installer.stage(repository: repository, commit: revision, pluginPath: path)
        do {
            try deadline.check()
            if let expectedEntry,
               review.repository != expectedEntry.repository || review.commit != expectedEntry.commit
                || review.pluginID != expectedEntry.id || review.version != expectedEntry.version
                || review.license != expectedEntry.license
                || review.loadedPlugin.manifest.kiwiosAPI != expectedEntry.kiwiosAPI {
                throw PolicyError.blocked("The source manifest does not match the reviewed catalog entry")
            }
            guard !remote.installationChallenges.values.contains(where: { $0.review.pluginID == review.pluginID }) else {
                throw PolicyError.blocked("A review for this plugin is already staged")
            }
            if let existing = try await store.plugin(id: review.pluginID), existing.sourceRepository != review.repository {
                throw PolicyError.blocked("This plugin ID is bound to a different source; remove it before replacing it")
            }
            let token = try RemoteSecurity.randomToken()
            let missingBrew = review.brew.filter { !BrewFormulaStatus.isInstalled($0) }
            let response = try remoteInstallationReviewResponse(
                review: review, missingBrew: missingBrew, token: token, reviewed: expectedEntry != nil)
            try await audit("plugin.installation-review-issued", pluginID: review.pluginID, requestedBy: requestedBy)
            remote.installationChallenges[token] = RemoteInstallationChallenge(
                identity: identity, review: review, missingBrew: missingBrew,
                expiresAt: Date().addingTimeInterval(60)
            )
            return response
        } catch {
            await installer.cancel(reviewID: review.id)
            throw error
        }
    }

    private func stageRemotePluginEnableReview(
        pluginID: String, identity: RemoteIdentity, requestedBy: String,
        deadline: RemoteRequestDeadline
    ) async throws -> Data {
        guard await remoteEnableAvailable(pluginID: pluginID) else {
            throw PolicyError.blocked("This plugin source is unavailable for web review")
        }
        guard remote.pluginEnableChallenges.count < 64 else {
            throw PolicyError.blocked("Too many pending source reviews")
        }
        let review = try await pluginReview(pluginID: pluginID)
        try deadline.check()
        guard !remote.pluginEnableChallenges.values.contains(where: { $0.review.pluginID == pluginID }) else {
            throw PolicyError.blocked("A source review for this plugin is already pending")
        }
        let token = try RemoteSecurity.randomToken()
        let response = try remotePluginEnableReviewResponse(review: review,
            source: remotePluginReviewSource(pluginID: pluginID), token: token)
        try await audit("plugin.enable-review-issued", pluginID: pluginID, requestedBy: requestedBy)
        remote.pluginEnableChallenges[token] = RemotePluginEnableChallenge(
            identity: identity, review: review, expiresAt: Date().addingTimeInterval(60)
        )
        return response
    }

    private func installRemotelyApprovedPlugin(
        _ review: InstallationReview, missingBrew: [String], requestedBy: String,
        deadline: RemoteRequestDeadline
    ) async throws {
        guard let installer, let store else { throw PolicyError.blocked("Plugin installer is unavailable") }
        guard !pendingRemovalIDs.contains(review.pluginID), !pluginTransitions.contains(review.pluginID) else {
            throw PolicyError.blocked("Plugin installation is changing; retry when it completes")
        }
        if let existing = try await store.plugin(id: review.pluginID), existing.sourceRepository != review.repository {
            throw PolicyError.blocked("Plugin source changed while reviewing")
        }
        setPluginTransition(review.pluginID, active: true)
        defer { setPluginTransition(review.pluginID, active: false) }
        var activated = false
        do {
            try deadline.check()
            let installed = try await installer.commit(reviewID: review.id)
            try deadline.check()
            let record = PluginRecord(id: review.pluginID, name: installed.plugin.manifest.name,
                version: installed.plugin.manifest.version, sourceRepository: installed.repository,
                sourceCommit: installed.commit, sourcePath: review.pluginPath,
                manifestDigest: installed.manifestDigest,
                contentDigest: installed.contentDigest, enabled: true,
                lifecycleState: PluginLifecycle.needsSetup.rawValue, updatedAt: Date())
            let approval = ApprovalRecord(pluginID: review.pluginID, manifestDigest: installed.manifestDigest,
                contentDigest: installed.contentDigest, disclosureDigest: installed.manifestDigest,
                sourceRepository: installed.repository, sourceCommit: installed.commit,
                approvedBy: requestedBy, approvedAt: Date())
            try await store.activateInstalledPlugin(record, approval: approval)
            pluginUpdates.removeValue(forKey: review.pluginID)
            activated = true
            await queue?.cancelPlugin(review.pluginID, requestedBy: requestedBy)
            await queue?.waitForPluginToStop(review.pluginID)
            await stopChecks(review.pluginID)
            do { try await installer.complete(reviewID: review.id, activeCommit: installed.commit) }
            catch { operationError = "The revision is active, but snapshot cleanup failed: \(error.localizedDescription)" }
            await reload()
            await refreshDoctor()
            let packages = missingBrew.filter { !BrewFormulaStatus.isInstalled($0) }
            if !packages.isEmpty {
                try deadline.check()
                do {
                    try await enqueueNativeOperation(
                        .homebrewInstall(packages: packages), requestedBy: requestedBy,
                        originPluginID: review.pluginID)
                } catch {
                    operationError = "Plugin installed, but Homebrew did not start: \(error.localizedDescription)"
                }
            }
        } catch {
            if !activated { await installer.cancel(reviewID: review.id) }
            throw error
        }
    }

    private func requestRemotePluginRemoval(
        pluginID: String, identity: RemoteIdentity, requestedBy: String,
        deadline: RemoteRequestDeadline
    ) async throws -> Data {
        guard let store, let configuration, let record = try await store.plugin(id: pluginID) else {
            throw PolicyError.blocked("Plugin is not added")
        }
        guard !pendingRemovalIDs.contains(pluginID), !pluginTransitions.contains(pluginID) else {
            throw PolicyError.blocked("Plugin removal is already in progress")
        }
        guard remote.removalChallenges.count < 64 else {
            throw PolicyError.blocked("Too many pending removal reviews")
        }
        try await configuration.verifyRemoteSecretRemoval(pluginID: pluginID)
        try deadline.check()
        let retainedPackages = (loaded[pluginID]?.manifest.brew ?? []).sorted().map {
            HomebrewRemovalItem(formula: $0, canUninstall: false,
                detail: "Retained during remote removal; review package cleanup in Attended Setup")
        }
        let review = PluginRemovalReview(pluginID: pluginID, name: record.name, homebrew: retainedPackages)
        let token = try RemoteSecurity.randomToken()
        let response = try remoteRemovalReviewResponse(review: review, token: token)
        try await audit("plugin.removal-review-issued", pluginID: pluginID, requestedBy: requestedBy)
        remote.removalChallenges[token] = RemoteRemovalChallenge(
            identity: identity, review: review, expiresAt: Date().addingTimeInterval(60)
        )
        return response
    }

    private func removeRemotelyApprovedPlugin(
        _ review: PluginRemovalReview, requestedBy: String, deadline: RemoteRequestDeadline
    ) async throws {
        guard let store, let configuration else { throw PolicyError.blocked("Plugin removal is unavailable") }
        guard try await store.plugin(id: review.pluginID) != nil else {
            throw PolicyError.blocked("Plugin is no longer added")
        }
        guard !pendingRemovalIDs.contains(review.pluginID), !pluginTransitions.contains(review.pluginID) else {
            throw PolicyError.blocked("Plugin removal is already in progress")
        }
        try await configuration.verifyRemoteSecretRemoval(pluginID: review.pluginID)
        try deadline.check()
        setPluginTransition(review.pluginID, active: true)
        defer { setPluginTransition(review.pluginID, active: false) }
        await queue?.cancelPlugin(review.pluginID, requestedBy: requestedBy)
        await queue?.waitForPluginToStop(review.pluginID)
        let id = review.pluginID
        guard PluginLexicalValidator.pluginID(id) else { throw PolicyError.blocked("Invalid plugin ID") }
        if loaded[id] != nil { try await disableApprovedPlugin(pluginID: id, requestedBy: requestedBy) }
        let declaredSecretFields = loaded[id]?.configSchema?.properties.compactMap {
            $0.value.writeOnly ? $0.key : nil
        } ?? []
        let secretFields = Array(Set(try await store.pluginSecretFields(pluginID: id))
            .union(declaredSecretFields)).sorted()
        try deadline.check()
        try await store.beginPluginRemoval(id: id, secretFields: secretFields, requestedBy: requestedBy)
        pendingRemovalIDs.insert(id)
        try await finishRemoval(PendingPluginRemoval(pluginID: id, secretFields: secretFields,
            requestedBy: requestedBy), store: store, configuration: configuration, mode: .remote,
            permitRemoteSecretCleanup: true)
        await reload()
    }

    private func remoteInstallationReviewResponse(
        review: InstallationReview, missingBrew: [String], token: String, reviewed: Bool = false
    ) throws -> Data {
        let dependencies = Dictionary(uniqueKeysWithValues: review.dependencies.map { ($0.key, JSONValue.string($0.value)) })
        var warning = "This is executable code with the Mac user's access. Disclosures describe intent; they do not sandbox it."
        if !missingBrew.isEmpty {
            warning = "KiwiOS will install missing Homebrew formulae locally: \(missingBrew.sorted().joined(separator: ", ")). " + warning
        }
        var reviewObject: [String: JSONValue] = [
            "pluginID": .string(review.pluginID), "name": .string(review.name), "version": .string(review.version),
            "license": .string(review.license), "repository": .string(review.repository), "commit": .string(review.commit),
            "pluginPath": .string(review.pluginPath), "manifestDigest": .string(review.manifestDigest),
            "contentDigest": .string(review.contentDigest), "dependencies": .object(dependencies),
            "brew": .array(missingBrew.map(JSONValue.string)), "permissions": .array(review.permissions.map(JSONValue.string)),
            "permissionChanges": .object(["added": .array(review.permissionChanges.added.map(JSONValue.string)),
                "removed": .array(review.permissionChanges.removed.map(JSONValue.string))]),
            "warning": .string(warning),
        ]
        if reviewed { reviewObject["reviewed"] = .bool(true) }
        let payload: JSONValue = .object([
            "confirmationToken": .string(token), "confirmationOperation": .string(RemoteMutation.Operation.confirmPluginInstall.rawValue),
            "label": .string("Install \(review.name)?"), "expiresIn": .number(60),
            "review": .object(reviewObject),
        ])
        return try boundedRemoteReview(payload)
    }

    private func remotePluginEnableReviewResponse(
        review: PluginReview, source: String, token: String
    ) throws -> Data {
        guard let plugin = loaded[review.pluginID] else { throw PolicyError.blocked("Plugin is unavailable") }
        let dependencies = Dictionary(uniqueKeysWithValues: plugin.manifest.depends.map { ($0.key, JSONValue.string($0.value)) })
        let payload: JSONValue = .object([
            "confirmationToken": .string(token),
            "confirmationOperation": .string(RemoteMutation.Operation.confirmPluginEnable.rawValue),
            "label": .string("Enable \(review.name)?"), "expiresIn": .number(60),
            "review": .object([
                "pluginID": .string(review.pluginID), "name": .string(review.name),
                "version": .string(review.version), "license": .string(review.license),
                "source": .string(source), "manifestDigest": .string(review.fingerprint.manifestDigest),
                "contentDigest": .string(review.fingerprint.contentDigest),
                "dependencies": .object(dependencies), "brew": .array(plugin.manifest.brew.map(JSONValue.string)),
                "permissions": .array(review.disclosures.map(JSONValue.string)),
                "warning": .string("This is executable code with the Mac user's access. Disclosures describe intent; they do not sandbox it."),
            ]),
        ])
        return try boundedRemoteReview(payload)
    }

    private func remotePluginReviewSource(pluginID: String) -> String {
        switch loaded[pluginID]?.source {
        case .bundled: "Bundled with KiwiOS"
        case .development: "Selected development source"
        case .direct: "Direct local source"
        case .installed: "Installed plugin snapshot"
        case nil: "Plugin source"
        }
    }

    private func remoteRemovalReviewResponse(review: PluginRemovalReview, token: String) throws -> Data {
        let packages = review.homebrew.map { item in JSONValue.object([
            "formula": .string(item.formula), "detail": .string(item.detail),
        ]) }
        let payload: JSONValue = .object([
            "confirmationToken": .string(token), "confirmationOperation": .string(RemoteMutation.Operation.confirmPluginRemoval.rawValue),
            "label": .string("Remove \(review.name)?"), "expiresIn": .number(60),
            "review": .object(["pluginID": .string(review.pluginID), "name": .string(review.name),
                "homebrew": .array(packages),
                "destruction": .string("Permanently removes KiwiOS-owned approval, configuration, config secrets, data, results, job and audit records, layout entries, and installed source."),
                "retention": .string("Remote removal keeps all Homebrew packages. Review package cleanup in Attended Setup.")]),
        ])
        return try boundedRemoteReview(payload)
    }

    private func boundedRemoteReview(_ payload: JSONValue) throws -> Data {
        let data = try JSONEncoder().encode(payload)
        guard data.count <= 64 * 1024 else {
            throw PolicyError.blocked("Plugin review exceeds the remote response limit; review it in Attended Setup")
        }
        return data
    }

    private func remoteLayout(
        widgets: [String], hiddenWidgets: [String], wideWidgets: [String], sidebar: [String]
    ) throws -> HomeLayout {
        let widgetKeys = Set(plugins.flatMap { plugin in
            plugin.manifest.ui.widgets.map { "\(plugin.id)/\($0.id)" }
        })
        let declaredWideWidgetKeys = Set(plugins.flatMap { plugin in
            plugin.manifest.ui.widgets.filter { $0.size == "2x1" }.map { "\(plugin.id)/\($0.id)" }
        })
        let sidebarKeys = Set(plugins.flatMap { plugin in
            plugin.manifest.ui.sidebar.map { "\(plugin.id)/\($0.id)" }
        })
        try RemoteLayoutPolicy.validate(widgets: widgets, hiddenWidgets: hiddenWidgets,
            wideWidgets: wideWidgets, sidebar: sidebar,
            validWidgetKeys: widgetKeys, validSidebarKeys: sidebarKeys)
        return HomeLayout(widgets: widgets, hiddenWidgets: Set(hiddenWidgets),
            wideWidgets: declaredWideWidgetKeys.intersection(Set(widgets)), sidebar: sidebar, initialized: layout.initialized)
    }
    func remoteAdmission(_ request: JobRequest, deadline: RemoteRequestDeadline) async throws -> Data {
        guard let queue else { throw PolicyError.blocked("Queue is unavailable") }
        try requireAdmissionsOpen()
        try deadline.check()
        // Once submit accepts the durable request, wait for its authoritative result instead
        // of racing it with a detached HTTP timeout that could claim no work was started.
        let admission = try await queue.submit(request)
        let skipped: Bool
        switch admission {
        case .accepted: skipped = false
        case .skipped: skipped = true; confirmationGrants.removeValue(forKey: request.id)
        }
        return try JSONEncoder().encode(JSONValue.object(["jobID": .string(request.id.uuidString), "skipped": .bool(skipped)]))
    }
    static func wire<T: Encodable>(_ value: T, encoder: JSONEncoder) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: encoder.encode(value))
    }

    static func remoteNativeTools(
        _ snapshot: NativeToolsSnapshot, sshPeerNames: [String], encoder: JSONEncoder
    ) throws -> JSONValue {
        let homebrew: JSONValue
        switch snapshot.homebrew {
        case .unavailable:
            homebrew = .object(["status": .string("unavailable"), "packages": .array([])])
        case .error(let path, let message):
            homebrew = .object([
                "status": .string("error"), "path": .string(path),
                "message": .string(message), "packages": .array([]),
            ])
        case .available(let path, let packages):
            homebrew = .object([
                "status": .string("available"), "path": .string(path),
                "packages": .array(packages.map(remoteHomebrewPackage)),
            ])
        }
        return .object([
            "sampledAt": try wire(snapshot.sampledAt, encoder: encoder),
            "power": .object([
                "lowPowerModeEnabled": .bool(snapshot.power.lowPowerModeEnabled),
                "fileVault": .string(snapshot.power.fileVault),
                "restartSupport": .string(snapshot.power.restartSupport),
            ]),
            "notifications": .object([
                "authorization": .string(snapshot.notificationAuthorization.rawValue),
            ]),
            "processes": .array(snapshot.processes.map { process in .object([
                "pid": .number(Double(process.pid)), "uid": .number(Double(process.uid)),
                "startTimeMicroseconds": .number(Double(process.startTimeMicroseconds)),
                "executablePath": .string(process.executablePath),
                "displayName": .string(process.displayName),
                "bundleIdentifier": process.bundleIdentifier.map(JSONValue.string) ?? .null,
                "canTerminate": .bool(process.canTerminate),
            ]) }),
            "launchAgents": .array(snapshot.launchAgents.map { agent in .object([
                "label": .string(agent.label), "plistPath": .string(agent.plistPath),
                "isLoaded": agent.isLoaded.map(JSONValue.bool) ?? .null,
                "issue": agent.issue.map(JSONValue.string) ?? .null,
            ]) }),
            "launchAgentWarning": snapshot.launchAgentWarning.map(JSONValue.string) ?? .null,
            "sshPeers": .array(sshPeerNames.sorted().map { .object(["name": .string($0)]) }),
            "homebrew": homebrew,
        ])
    }

    private static func remoteHomebrewPackage(_ package: NativeHomebrewPackage) -> JSONValue {
        .object([
            "kind": .string(package.kind.rawValue), "name": .string(package.name),
            "displayName": .string(package.displayName), "qualifiedName": .string(package.qualifiedName),
            "description": package.description.map(JSONValue.string) ?? .null,
            "tap": package.tap.map(JSONValue.string) ?? .null,
            "installedVersions": .array(package.installedVersions.map(JSONValue.string)),
            "latestVersion": package.latestVersion.map(JSONValue.string) ?? .null,
            "dependencies": .array(package.dependencies.map { dependency in .object([
                "kind": .string(dependency.kind.rawValue), "name": .string(dependency.name),
            ]) }),
            "applicationPath": package.applicationPath.map(JSONValue.string) ?? .null,
            "installedOnRequest": .bool(package.installedOnRequest),
            "outdated": .bool(package.outdated), "pinned": .bool(package.pinned),
            "kegOnly": .bool(package.kegOnly),
        ])
    }
}
