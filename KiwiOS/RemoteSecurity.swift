import Foundation
import CryptoKit
import Security

struct RemoteIdentity: Codable, Equatable, Sendable {
    let login: String
    let displayName: String

    var auditActor: String { "tailscale:\(login)" }
}

struct RemoteMutation: Codable, Equatable, Sendable {
    enum Operation: String, Codable, Sendable {
        case refreshCheck
        case requestAction
        case confirmAction
        case cancelJob
        case disablePlugin
        case enablePlugin
        case requestPluginInstall
        case confirmPluginInstall
        case requestPluginRemoval
        case confirmPluginRemoval
        case saveConfig
        case refreshDoctor
        case saveLayout
        case reloadPlugins
        case refreshNativeTools
        case requestProcessTermination
        case requestLaunchAgentRestart
        case confirmNativeOperation
        case probeSSH
        case deliverNotification
    }

    let requestID: UUID
    let operation: Operation
    let pluginID: String?
    let contributionID: String?
    let repository: String?
    let commit: String?
    let pluginPath: String?
    let jobID: UUID?
    let values: [String: JSONValue]?
    let configRevision: Int64?
    let confirmationToken: String?
    let widgets: [String]?
    let hiddenWidgets: [String]?
    let wideWidgets: [String]?
    let sidebar: [String]?
    let pid: Int32?
    let launchAgentLabel: String?
    let peerName: String?
    let title: String?
    let body: String?
}

enum RemoteLayoutPolicy {
    static func validate(
        widgets: [String], hiddenWidgets: [String], wideWidgets: [String], sidebar: [String],
        validWidgetKeys: Set<String>, validSidebarKeys: Set<String>
    ) throws {
        guard widgets.count == Set(widgets).count, hiddenWidgets.count == Set(hiddenWidgets).count,
              wideWidgets.count == Set(wideWidgets).count, sidebar.count == Set(sidebar).count,
              widgets.allSatisfy(validWidgetKeys.contains), hiddenWidgets.allSatisfy(validWidgetKeys.contains),
              wideWidgets.allSatisfy(validWidgetKeys.contains), sidebar.allSatisfy(validSidebarKeys.contains) else {
            throw PolicyError.blocked("Layout contains an unknown or duplicate contribution")
        }
    }

    static func normalized(
        _ layout: HomeLayout, validWidgetKeys: Set<String>, declaredWideWidgetKeys: Set<String>, validSidebarKeys: Set<String>
    ) -> HomeLayout {
        HomeLayout(
            widgets: layout.widgets.filter(validWidgetKeys.contains),
            hiddenWidgets: layout.hiddenWidgets.intersection(validWidgetKeys),
            wideWidgets: declaredWideWidgetKeys.intersection(Set(layout.widgets)).intersection(validWidgetKeys),
            sidebar: layout.sidebar.filter(validSidebarKeys.contains),
            initialized: layout.initialized
        )
    }
}

struct RemoteRequestDeadline: Sendable {
    private let instant: ContinuousClock.Instant

    init(after duration: Duration) { instant = ContinuousClock().now.advanced(by: duration) }

    func check() throws {
        try Task.checkCancellation()
        guard ContinuousClock().now < instant else { throw CancellationError() }
    }
}

enum RemoteSecurityError: Error, Equatable {
    case missingIdentity
    case invalidIdentity
    case missingSession
    case expiredSession
    case identityChanged
    case invalidOrigin
    case invalidContentType
    case invalidCSRF
    case replayedRequest
    case rateLimited
    case sessionCapacityReached
    case randomGenerationFailed
}

struct RemoteSession: Sendable {
    static let cookieName = "kiwios_session"

    let cookie: String
    let csrfToken: String
}

/// Session and replay protection for the managed Tailscale Serve deployment.
///
/// Tailscale strips caller supplied identity headers before adding its own. KiwiOS only
/// accepts those headers while its exact loopback proxy configuration is active. A local
/// same-user process remains outside the v1 threat boundary documented by the project.
actor RemoteSecurity {
    static let sessionLifetime: TimeInterval = 8 * 60 * 60
    static let replayLifetime: TimeInterval = 10 * 60
    static let maximumSessions = 64
    static let maximumSessionsPerIdentity = 4
    static let maximumSessionCreationsPerMinute = 5
    static let maximumRequestsPerMinute = 30

    private struct SessionState {
        let identity: RemoteIdentity
        var csrfHash: Data
        let expiresAt: Date
        var requestTimes: [Date]
    }

    private let expectedOrigin: String
    private var sessions: [Data: SessionState] = [:]
    private var replayedRequests: [UUID: Date] = [:]
    private var sessionCreations: [String: [Date]] = [:]

    init(expectedOrigin: URL) throws {
        guard expectedOrigin.scheme == "https", expectedOrigin.path.isEmpty,
              expectedOrigin.user == nil, expectedOrigin.password == nil,
              expectedOrigin.query == nil, expectedOrigin.fragment == nil,
              expectedOrigin.port == nil, expectedOrigin.host != nil else {
            throw RemoteSecurityError.invalidOrigin
        }
        self.expectedOrigin = expectedOrigin.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    func createSession(identity: RemoteIdentity, replacing cookie: String? = nil, now: Date = Date()) throws -> RemoteSession {
        prune(now: now)
        let recent = sessionCreations[identity.login, default: []].filter { $0 > now.addingTimeInterval(-60) }
        guard recent.count < Self.maximumSessionCreationsPerMinute else { throw RemoteSecurityError.rateLimited }
        let oldKey = cookie.map(Self.hash)
        let existing = oldKey.flatMap { sessions[$0] }.flatMap { $0.identity == identity ? $0 : nil }
        let owned = sessions.filter { $0.value.identity.login == identity.login }
        // Clearing cookies cannot consume all global slots. Replace this identity's
        // oldest session once its small device allowance is full.
        let eviction = existing == nil && owned.count >= Self.maximumSessionsPerIdentity
            ? owned.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key : nil
        guard sessions.count < Self.maximumSessions || existing != nil || eviction != nil else {
            throw RemoteSecurityError.sessionCapacityReached
        }
        let cookie = try Self.randomToken()
        let csrf = try Self.randomToken()
        let expiresAt = now.addingTimeInterval(Self.sessionLifetime)
        if existing != nil, let oldKey { sessions.removeValue(forKey: oldKey) }
        if let eviction { sessions.removeValue(forKey: eviction) }
        sessions[Self.hash(cookie)] = SessionState(identity: identity, csrfHash: Self.hash(csrf),
            expiresAt: expiresAt, requestTimes: existing?.requestTimes ?? [])
        sessionCreations[identity.login] = recent + [now]
        return RemoteSession(cookie: cookie, csrfToken: csrf)
    }

    func authenticate(cookie: String?, identity: RemoteIdentity, now: Date = Date()) throws -> RemoteIdentity {
        prune(now: now)
        guard let cookie else { throw RemoteSecurityError.missingSession }
        let key = Self.hash(cookie)
        guard let session = sessions[key] else { throw RemoteSecurityError.expiredSession }
        guard session.identity == identity else {
            sessions.removeValue(forKey: key)
            throw RemoteSecurityError.identityChanged
        }
        return identity
    }

    /// Consumes both CSRF and request ID before mutation begins, preventing concurrent replay.
    /// A replacement CSRF token is returned even when the runtime mutation subsequently fails.
    func authorizeMutation(
        cookie: String?, csrf: String?, origin: String?, contentType: String?, identity: RemoteIdentity,
        requestID: UUID, now: Date = Date()
    ) throws -> (identity: RemoteIdentity, nextCSRF: String) {
        prune(now: now)
        guard origin == expectedOrigin else { throw RemoteSecurityError.invalidOrigin }
        guard contentType?.lowercased().split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces)
            == "application/json" else { throw RemoteSecurityError.invalidContentType }
        guard let cookie, let csrf else { throw RemoteSecurityError.invalidCSRF }
        let key = Self.hash(cookie)
        guard var session = sessions[key], session.expiresAt > now else { throw RemoteSecurityError.expiredSession }
        guard session.identity == identity else {
            sessions.removeValue(forKey: key)
            throw RemoteSecurityError.identityChanged
        }
        guard Self.constantTimeEqual(session.csrfHash, Self.hash(csrf)) else { throw RemoteSecurityError.invalidCSRF }
        guard replayedRequests[requestID] == nil else { throw RemoteSecurityError.replayedRequest }

        let cutoff = now.addingTimeInterval(-60)
        session.requestTimes.removeAll { $0 < cutoff }
        guard session.requestTimes.count < Self.maximumRequestsPerMinute else { throw RemoteSecurityError.rateLimited }

        let nextCSRF = try Self.randomToken()
        session.csrfHash = Self.hash(nextCSRF)
        session.requestTimes.append(now)
        sessions[key] = session
        replayedRequests[requestID] = now.addingTimeInterval(Self.replayLifetime)
        return (identity, nextCSRF)
    }

    func revokeAll() {
        sessions.removeAll(keepingCapacity: false)
        replayedRequests.removeAll(keepingCapacity: false)
        sessionCreations.removeAll(keepingCapacity: false)
    }

    private func prune(now: Date) {
        sessionCreations = sessionCreations.compactMapValues { values in
            let recent = values.filter { $0 > now.addingTimeInterval(-60) }
            return recent.isEmpty ? nil : recent
        }
        sessions = sessions.filter { $0.value.expiresAt > now }
        replayedRequests = replayedRequests.filter { $0.value > now }
    }

    static func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw RemoteSecurityError.randomGenerationFailed
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func hash(_ value: String) -> Data {
        // Session material is uniformly random. Storing a SHA-256 digest avoids retaining bearer tokens.
        Data(SHA256.hash(data: Data(value.utf8)))
    }

    private static func constantTimeEqual(_ left: Data, _ right: Data) -> Bool {
        guard left.count == right.count else { return false }
        return zip(left, right).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
