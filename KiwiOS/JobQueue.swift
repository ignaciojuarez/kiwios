import Foundation

struct JobRequest: Equatable, Sendable {
    let id: UUID
    let pluginID: String
    let contributionID: String
    let kind: JobKind
    let resource: String
    let requestedBy: String

    static func namespacedResource(pluginID: String, resource: String) -> String {
        "\(pluginID)/\(resource)"
    }

    init(
        id: UUID = UUID(),
        pluginID: String,
        contributionID: String,
        kind: JobKind,
        resource: String? = nil,
        requestedBy: String
    ) {
        self.id = id
        self.pluginID = pluginID
        self.contributionID = contributionID
        self.kind = kind
        self.resource = Self.namespacedResource(pluginID: pluginID, resource: resource ?? contributionID)
        self.requestedBy = requestedBy
    }
}

struct JobExecutionResult: Equatable, Sendable {
    let status: JobStatus
    let summary: String
    /// A bounded, structured result which has already passed the host's redaction policy.
    let redactedPayloadJSON: Data?

    init(status: JobStatus, summary: String, redactedPayloadJSON: Data? = nil) {
        precondition(status.isTerminal && status != .skipped && status != .interrupted)
        self.status = status
        self.summary = summary
        self.redactedPayloadJSON = redactedPayloadJSON
    }
}

struct JobExecutionContext: Sendable {
    let jobID: UUID
    let request: JobRequest
}

enum JobAdmission: Equatable, Sendable {
    case accepted(UUID)
    case skipped(UUID)
}

enum JobQueueError: LocalizedError {
    case notStarted
    case alreadyStarted
    case invalidSchedule
    case queueFull
    case admissionsPaused
    case duplicateJobID(UUID)

    var errorDescription: String? {
        switch self {
        case .notStarted: "Job queue has not started"
        case .alreadyStarted: "Job queue has already started"
        case .invalidSchedule: "Scheduled checks require a positive interval"
        case .queueFull: "Job queue is full"
        case .admissionsPaused: "Job admission is paused during a policy transition"
        case .duplicateJobID(let id): "Job ID is already admitted: \(id.uuidString)"
        }
    }
}

actor JobQueue {
    typealias Executor = @Sendable (JobExecutionContext) async throws -> JobExecutionResult

    private let store: PersistenceStore
    private let maximumConcurrentJobs: Int
    private let maximumPendingJobs: Int
    private let executor: Executor
    private var started = false
    private var starting = false
    private var shuttingDown = false
    private var pending: [UUID] = []
    private var canceledReservations = Set<UUID>()
    private var requests: [UUID: JobRequest] = [:]
    private var activeResources = Set<String>()
    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    private var admissionsPaused = false
    private var inFlightAdmissions = 0
    private var admissionWaiters: [CheckedContinuation<Void, Never>] = []
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []
    private var repeatingTasks: [UUID: Task<Void, Never>] = [:]
    private var repeatingPluginIDs: [UUID: String] = [:]
    private var persistenceFailures: [UUID: String] = [:]
    private(set) var lastErrorMessage: String?

    init(
        store: PersistenceStore,
        maximumConcurrentJobs: Int = 4,
        maximumPendingJobs: Int = 128,
        executor: @escaping Executor
    ) {
        self.store = store
        self.maximumConcurrentJobs = max(1, maximumConcurrentJobs)
        self.maximumPendingJobs = max(1, maximumPendingJobs)
        self.executor = executor
    }

    /// Recovers abandoned running rows. Persisted actions are never automatically replayed.
    func start() async throws {
        guard !started, !starting else { throw JobQueueError.alreadyStarted }
        starting = true
        inFlightAdmissions += 1
        defer { admissionFinished() }
        do {
            try await store.recoverInterruptedJobs()
            guard !shuttingDown else { throw CancellationError() }
            started = true
            starting = false
        } catch {
            starting = false
            lastErrorMessage = error.localizedDescription
            throw error
        }
    }

    func submit(_ request: JobRequest) async throws -> JobAdmission {
        guard started, !shuttingDown else { throw JobQueueError.notStarted }
        try Task.checkCancellation()
        guard !admissionsPaused else { throw JobQueueError.admissionsPaused }
        inFlightAdmissions += 1
        defer { admissionFinished() }
        let now = Date()
        guard requests[request.id] == nil else { throw JobQueueError.duplicateJobID(request.id) }

        let duplicateAction = request.kind == .action && requests.values.contains {
            $0.kind == .action && $0.pluginID == request.pluginID
                && $0.contributionID == request.contributionID
        }
        let overlappingCheck = request.kind == .check && requests.values.contains {
            $0.resource == request.resource
        }
        if overlappingCheck { return .skipped(request.id) }
        if duplicateAction {
            let reason = "Skipped because this action is already active"
            let job = stored(request, status: .skipped, createdAt: now, finishedAt: now,
                summary: reason)
            try await store.admitJob(job, event: "\(request.kind.rawValue).skipped")
            return .skipped(request.id)
        }
        guard requests.count - activeTasks.count < maximumPendingJobs else {
            throw JobQueueError.queueFull
        }

        let status: JobStatus = .queued
        // Reserve before the first suspension so actor reentrancy cannot admit a duplicate.
        requests[request.id] = request
        do {
            try await store.admitJob(stored(request, status: status, createdAt: now),
                event: "job.\(status.rawValue)")
        } catch {
            requests.removeValue(forKey: request.id)
            canceledReservations.remove(request.id)
            lastErrorMessage = error.localizedDescription
            throw error
        }

        if shuttingDown || Task.isCancelled || canceledReservations.remove(request.id) != nil {
            requests.removeValue(forKey: request.id)
            try await finishWithoutExecution(request.id, status: .canceled,
                summary: "Canceled during admission", actor: "system")
            return .accepted(request.id)
        }
        pending.append(request.id)
        drain()
        return .accepted(request.id)
    }

    /// Registers an in-memory interval. The manifest remains the durable source of schedule definitions.
    @discardableResult
    func scheduleCheck(
        pluginID: String,
        contributionID: String,
        resource: String? = nil,
        requestedBy: String = "scheduler",
        every interval: TimeInterval,
        runImmediately: Bool = true
    ) throws -> UUID {
        guard started, !shuttingDown else { throw JobQueueError.notStarted }
        guard interval > 0, interval.isFinite else { throw JobQueueError.invalidSchedule }
        let scheduleID = UUID()
        repeatingTasks[scheduleID] = Task { [weak self] in
            if runImmediately {
                do {
                    _ = try await self?.submit(JobRequest(pluginID: pluginID,
                        contributionID: contributionID, kind: .check, resource: resource,
                        requestedBy: requestedBy))
                } catch JobQueueError.admissionsPaused {
                    // Missed recurring ticks are intentionally not replayed.
                } catch { await self?.record(error) }
            }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: Self.nanoseconds(interval))
                    try Task.checkCancellation()
                } catch { return }
                do {
                    _ = try await self?.submit(JobRequest(pluginID: pluginID,
                        contributionID: contributionID, kind: .check, resource: resource,
                        requestedBy: requestedBy))
                } catch JobQueueError.admissionsPaused {
                    // Missed recurring ticks are intentionally not replayed.
                } catch { await self?.record(error) }
            }
        }
        repeatingPluginIDs[scheduleID] = pluginID
        return scheduleID
    }

    func cancelSchedule(_ id: UUID) {
        repeatingTasks.removeValue(forKey: id)?.cancel()
        repeatingPluginIDs.removeValue(forKey: id)
    }

    func removeSchedules(pluginID: String) {
        let ids = repeatingPluginIDs.compactMap { $0.value == pluginID ? $0.key : nil }
        for id in ids { cancelSchedule(id) }
    }

    func cancelPlugin(_ pluginID: String, requestedBy: String) async {
        removeSchedules(pluginID: pluginID)
        let ids = requests.values.filter { $0.pluginID == pluginID }.map(\.id)
        for id in ids {
            do { try await cancel(id, requestedBy: requestedBy) }
            catch { persistenceFailures[id] = error.localizedDescription; lastErrorMessage = error.localizedDescription }
        }
    }

    /// Use after closing the plugin's runtime gate. Never call from that plugin's executor.
    func waitForPluginToStop(_ pluginID: String) async {
        if inFlightAdmissions > 0 {
            await withCheckedContinuation { admissionWaiters.append($0) }
        }
        let tasks = activeTasks.compactMap { requests[$0.key]?.pluginID == pluginID ? $0.value : nil }
        for task in tasks { await task.value }
    }

    func waitForCompletion(_ id: UUID) async -> StoredJob? {
        while true {
            if persistenceFailures[id] != nil { return nil }
            do {
                guard let job = try await store.job(id: id) else { return nil }
                if job.status.isTerminal { return job }
            } catch {
                persistenceFailures[id] = error.localizedDescription
                lastErrorMessage = error.localizedDescription
                return nil
            }
            do { try await Task.sleep(nanoseconds: 20_000_000) } catch { return try? await store.job(id: id) }
        }
    }

    func persistenceFailure(for id: UUID) -> String? {
        persistenceFailures[id]
    }

    func cancel(_ id: UUID, requestedBy: String) async throws {
        if let index = pending.firstIndex(of: id) {
            pending.remove(at: index)
            requests.removeValue(forKey: id)
            try await finishWithoutExecution(id, status: .canceled, summary: "Canceled while queued",
                actor: requestedBy)
            return
        }
        if requests[id] != nil, activeTasks[id] == nil {
            canceledReservations.insert(id)
            return
        }
        activeTasks[id]?.cancel()
        if activeTasks[id] != nil, requests[id]?.kind == .action {
            try await store.appendAudit(AuditEntry(occurredAt: Date(), actor: requestedBy,
                event: "job.cancellation-requested", pluginID: requests[id]?.pluginID,
                jobID: id))
        }
    }

    /// Pausing and inspecting reservations happen on the queue actor before mode is committed.
    func setAdmissionsPaused(_ paused: Bool) {
        admissionsPaused = paused
        if !paused { drain() }
    }

    var hasAdmittedWork: Bool { !requests.isEmpty || inFlightAdmissions > 0 }

    func shutdown() async {
        if shuttingDown {
            if started || starting { await withCheckedContinuation { shutdownWaiters.append($0) } }
            return
        }
        guard started || starting else { return }
        shuttingDown = true
        for id in requests.keys where activeTasks[id] == nil { canceledReservations.insert(id) }
        let tasks = Array(activeTasks.values)
        tasks.forEach { $0.cancel() }
        repeatingTasks.values.forEach { $0.cancel() }
        repeatingTasks.removeAll()
        repeatingPluginIDs.removeAll()

        let waitingIDs = pending
        pending.removeAll()
        for id in waitingIDs {
            requests.removeValue(forKey: id)
            do {
                try await finishWithoutExecution(id, status: .canceled,
                    summary: "Canceled during shutdown", actor: "system")
            } catch {
                persistenceFailures[id] = error.localizedDescription
                lastErrorMessage = error.localizedDescription
            }
        }
        if inFlightAdmissions > 0 {
            await withCheckedContinuation { admissionWaiters.append($0) }
        }
        for task in tasks { await task.value }
        canceledReservations.removeAll()
        started = false
        starting = false
        let waiters = shutdownWaiters
        shutdownWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func admissionFinished() {
        inFlightAdmissions -= 1
        if inFlightAdmissions == 0 {
            let waiters = admissionWaiters
            admissionWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    private func drain() {
        guard !shuttingDown, !admissionsPaused, activeTasks.count < maximumConcurrentJobs else { return }
        var index = 0
        while index < pending.count, activeTasks.count < maximumConcurrentJobs {
            let id = pending[index]
            guard let request = requests[id] else {
                pending.remove(at: index)
                continue
            }
            guard !activeResources.contains(request.resource) else {
                index += 1
                continue
            }
            pending.remove(at: index)
            activeResources.insert(request.resource)
            let executor = self.executor
            let store = self.store
            activeTasks[id] = Task { [weak self] in
                await Self.execute(id: id, request: request, store: store,
                    executor: executor, queue: self)
            }
        }
    }

    private static func execute(
        id: UUID,
        request: JobRequest,
        store: PersistenceStore,
        executor: @escaping Executor,
        queue: JobQueue?
    ) async {
        let startedAt = Date()
        do {
            try await store.updateJob(id: id, status: .running, startedAt: startedAt)
            if request.kind == .action {
                try await store.appendAudit(AuditEntry(occurredAt: startedAt, actor: "system",
                    event: "job.running", pluginID: request.pluginID, jobID: id))
            }
            let result = try await executor(JobExecutionContext(jobID: id, request: request))
            let final = Task.isCancelled
                ? JobExecutionResult(status: .canceled, summary: "Canceled",
                    redactedPayloadJSON: result.redactedPayloadJSON)
                : result
            await queue?.didFinish(request, result: final)
        } catch is CancellationError {
            await queue?.didFinish(request,
                result: JobExecutionResult(status: .canceled, summary: "Canceled"))
        } catch {
            await queue?.didFinish(request,
                result: JobExecutionResult(status: .failed, summary: error.localizedDescription))
        }
    }

    private func didFinish(
        _ request: JobRequest,
        result: JobExecutionResult
    ) async {
        do {
            try await store.finishJob(id: request.id, status: result.status,
                summary: result.summary, resultJSON: result.redactedPayloadJSON)
        } catch {
            persistenceFailures[request.id] = error.localizedDescription
            lastErrorMessage = error.localizedDescription
        }
        activeTasks.removeValue(forKey: request.id)
        activeResources.remove(request.resource)
        requests.removeValue(forKey: request.id)
        drain()
    }

    private func finishWithoutExecution(
        _ id: UUID,
        status: JobStatus,
        summary: String,
        actor: String
    ) async throws {
        try await store.finishJob(id: id, status: status, summary: summary,
            resultJSON: nil, actor: actor)
    }

    private func stored(
        _ request: JobRequest,
        status: JobStatus,
        createdAt: Date,
        finishedAt: Date? = nil,
        summary: String? = nil
    ) -> StoredJob {
        StoredJob(id: request.id, pluginID: request.pluginID, contributionID: request.contributionID,
            kind: request.kind, resource: request.resource, status: status,
            requestedBy: request.requestedBy, createdAt: createdAt, scheduledAt: nil,
            startedAt: nil, finishedAt: finishedAt, summary: summary, resultJSON: nil)
    }

    private func record(_ error: Error) {
        lastErrorMessage = error.localizedDescription
    }

    private nonisolated static func nanoseconds(_ interval: TimeInterval) -> UInt64 {
        UInt64(min(interval, 9_223_372_036) * 1_000_000_000)
    }
}
