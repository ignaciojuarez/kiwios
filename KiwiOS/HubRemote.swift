import Foundation

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
        guard remote.enabled, mode == .remote, !stopped else { throw PolicyError.blocked("Remote access is unavailable") }
        try deadline.check()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var pluginValues: [JSONValue] = []
        for plugin in plugins {
            try deadline.check()
            var value: [String: JSONValue] = [
                "id": .string(plugin.id), "name": .string(plugin.manifest.name),
                "version": .string(plugin.manifest.version), "lifecycle": .string(plugin.lifecycle.rawValue),
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
            ]
            if let schema = loaded[plugin.id]?.configSchema {
                var properties: [String: JSONValue] = [:]
                for (key, field) in schema.properties {
                    properties[key] = .object([
                        "type": .string(field.type.rawValue), "title": .string(field.title ?? key),
                        "description": field.description.map(JSONValue.string) ?? .null,
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
        let visibleJobs = jobs.filter { $0.kind == .action }
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
        let snapshot: [String: JSONValue] = [
            "api": .string("kiwios.remote/1"), "mode": .string(mode.rawValue),
            "viewer": .object(["loginName": .string(identity.login), "displayName": .string(identity.displayName)]),
            "availability": .string("Available only after the owning Mac user logs in and unlocks FileVault"),
            "plugins": .array(pluginValues), "jobs": .array(jobValues),
            "layout": try Self.wire(layout, encoder: encoder),
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
        guard remote.enabled, mode == .remote, !stopped, !reloading, let queue else {
            throw PolicyError.blocked("Remote mutations require the active remote runtime")
        }
        try requireAdmissionsOpen()
        policyOperations += 1
        defer { policyOperations -= 1 }
        try deadline.check()
        let actor = identity.auditActor
        remote.challenges = remote.challenges.filter { $0.value.confirmation.expiresAt > Date() }
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
        case .saveConfig:
            guard let id = mutation.pluginID, let values = mutation.values, let revision = mutation.configRevision,
                  let plugin = loaded[id], let configuration else { throw PolicyError.blocked("Unknown plugin configuration") }
            try deadline.check()
            guard !pluginTransitions.contains(id), !pendingRemovalIDs.contains(id) else { throw PolicyError.blocked("Plugin installation is changing") }
            _ = try await configuration.save(values, expectedRevision: revision, for: plugin, mode: .remote)
            try await audit("plugin.config-saved", pluginID: id, requestedBy: actor)
            await refreshDoctor()
        }
        await refreshResults()
        return try JSONEncoder().encode(JSONValue.object(["ok": .bool(true)]))
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
}
