import Foundation
import Hummingbird
import struct HTTPTypes.HTTPField

enum RemoteServerError: LocalizedError {
    case alreadyRunning
    case assetsUnavailable

    var errorDescription: String? {
        switch self {
        case .alreadyRunning: "Remote server is already running"
        case .assetsUnavailable: "Remote web assets are missing from the app bundle"
        }
    }
}

/// A single fixed-port loopback backend. It binds only after Tailscale supplies a checked
/// publication plan and keeps its request gate closed until the exact mapping is active.
actor RemoteServer {
    typealias Snapshot = @Sendable (RemoteIdentity, RemoteRequestDeadline) async throws -> Data
    typealias Mutate = @Sendable (RemoteMutation, RemoteIdentity, RemoteRequestDeadline) async throws -> Data
    typealias Terminated = @Sendable () async -> Void

    private static let maximumMutationBytes = 64 * 1_024
    private var serviceTask: Task<Void, Never>?
    private var serviceID: UUID?
    private var isStopping = false
    private var monitorTask: Task<Void, Never>?
    private var security: RemoteSecurity?
    private var terminationHandler: Terminated?
    private var notifyOnExit = false

    /// Binds the backend before Serve is changed. Requests stay unavailable until `activate`.
    func start(plan: RemotePublicationPlan, snapshot: @escaping Snapshot, mutate: @escaping Mutate,
               onTermination: @escaping Terminated) async throws {
        guard serviceTask == nil, !isStopping else { throw RemoteServerError.alreadyRunning }
        let assets = try RemoteWebAssets.load()
        let security = try RemoteSecurity(expectedOrigin: plan.origin)
        let gate = RemoteTrustGate(expectedOrigin: plan.origin)
        let startup = RemoteStartupSignal()
        self.security = security
        terminationHandler = onTermination
        let expectedHost = plan.origin.host() ?? ""

        let router = Router()
        let staticRoutes: [(RouterPath, Data, String, Bool)] = [
            ("/", assets.index, "text/html; charset=utf-8", false),
            ("/app.css", assets.styles, "text/css; charset=utf-8", true),
            ("/app.js", assets.script, "text/javascript; charset=utf-8", true),
            ("/manifest.webmanifest", assets.manifest, "application/manifest+json", true),
            ("/favicon.png", assets.favicon, "image/png", true),
            ("/icon-192.png", assets.icon192, "image/png", true),
            ("/icon-512.png", assets.icon512, "image/png", true),
            ("/service-worker.js", assets.serviceWorker, "text/javascript; charset=utf-8", false),
        ]
        for (path, data, contentType, cache) in staticRoutes {
            router.get(path) { request, _ in
                guard await gate.isActive, Self.isVerifiedServeRequest(request, expectedHost: expectedHost) else { return Self.forbidden() }
                return Self.asset(data, contentType: contentType, cache: cache)
            }
        }
        router.get("/api/session") { request, _ in
            do {
                guard await gate.isActive, Self.hasExpectedHost(request, expectedHost: expectedHost) else { throw RemoteSecurityError.invalidOrigin }
                guard request.headers[Self.sessionRequestHeader] == "1" else { throw RemoteSecurityError.invalidOrigin }
                let identity = try Self.identity(request)
                let session = try await security.createSession(identity: identity, replacing: Self.sessionCookie(request))
                var headers = Self.apiHeaders()
                headers[.setCookie] = "\(RemoteSession.cookieName)=\(session.cookie); Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=28800"
                headers[Self.csrfHeader] = session.csrfToken
                return Self.response(try JSONEncoder().encode(identity), headers: headers)
            } catch { return Self.errorResponse(error) }
        }
        router.get("/api/snapshot") { request, _ in
            do {
                guard await gate.isActive, Self.hasExpectedHost(request, expectedHost: expectedHost) else { throw RemoteSecurityError.invalidOrigin }
                let identity = try Self.identity(request)
                _ = try await security.authenticate(cookie: Self.sessionCookie(request), identity: identity)
                let deadline = RemoteRequestDeadline(after: .seconds(10))
                try deadline.check()
                let data = try await snapshot(identity, deadline)
                return Self.response(data, headers: Self.apiHeaders())
            } catch { return Self.errorResponse(error) }
        }
        router.post("/api/mutate") { request, _ in
            var nextCSRF: String?
            do {
                guard await gate.isActive, Self.hasExpectedHost(request, expectedHost: expectedHost) else { throw RemoteSecurityError.invalidOrigin }
                let contentType = request.headers[.contentType]
                guard contentType?.lowercased().hasPrefix("application/json") == true else {
                    throw RemoteSecurityError.invalidContentType
                }
                let buffer = try await request.body.collect(upTo: Self.maximumMutationBytes)
                let body = Data(buffer.readableBytesView)
                try Self.validateMutationShape(body)
                let mutation = try JSONDecoder().decode(RemoteMutation.self, from: body)
                let identity = try Self.identity(request)
                let authorization = try await security.authorizeMutation(
                    cookie: Self.sessionCookie(request), csrf: request.headers[Self.csrfHeader],
                    origin: request.headers[.origin], contentType: contentType,
                    identity: identity, requestID: mutation.requestID
                )
                nextCSRF = authorization.nextCSRF
                let deadline = RemoteRequestDeadline(after: .seconds(15))
                try deadline.check()
                let data = try await mutate(mutation, authorization.identity, deadline)
                var headers = Self.apiHeaders()
                headers[Self.csrfHeader] = authorization.nextCSRF
                return Self.response(data, headers: headers)
            } catch {
                var response = Self.errorResponse(error)
                if let nextCSRF { response.headers[Self.csrfHeader] = nextCSRF }
                return response
            }
        }

        let app = Application(
            router: router,
            configuration: .init(
                address: .hostname(TailscaleService.loopbackHost, port: TailscaleService.loopbackPort),
                serverName: "KiwiOS",
                backlog: 64,
                reuseAddress: false
            ),
            onServerRunning: { _ in await startup.succeed() }
        )
        let id = UUID()
        serviceID = id
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try await app.run()
                await startup.fail(RemoteServerError.assetsUnavailable)
            } catch {
                await startup.fail(error)
            }
            await self?.serverExited(id: id)
        }
        serviceTask = task
        do {
            try await startup.waitForResult()
            guard serviceID == id else { throw CancellationError() }
        }
        catch {
            task.cancel()
            await task.value
            if serviceID == id {
                serviceID = nil
                serviceTask = nil
                self.security = nil
                self.terminationHandler = nil
            }
            throw error
        }
        // Retained by route closures and activated only after Tailscale commits the exact mapping.
        self.trustGate = gate
    }

    private var trustGate: RemoteTrustGate?

    func activate(
        trust: ManagedServeTrust,
        validate: @escaping @Sendable (ManagedServeTrust) async throws -> Bool
    ) async throws {
        guard let gate = trustGate, let id = serviceID else { throw RemoteServerError.assetsUnavailable }
        guard try await validate(trust), serviceID == id else { throw TailscaleServiceError.configurationChanged }
        try await gate.activate(trust)
        guard serviceID == id else { await gate.deactivate(); throw CancellationError() }
        notifyOnExit = true
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) }
                catch { return }
                do {
                    guard try await validate(trust) else { await self?.invalidate(id: id); return }
                } catch { await self?.invalidate(id: id); return }
            }
        }
    }

    func stop() async {
        guard !isStopping else { return }
        isStopping = true
        defer { isStopping = false }
        monitorTask?.cancel()
        monitorTask = nil
        let task = serviceTask
        let gate = trustGate
        let sessions = security
        serviceID = nil
        serviceTask = nil
        trustGate = nil
        security = nil
        terminationHandler = nil
        notifyOnExit = false
        await gate?.deactivate()
        task?.cancel()
        await task?.value
        await sessions?.revokeAll()
    }

    var isRunning: Bool { serviceTask != nil }

    private func invalidate(id: UUID) async {
        guard serviceID == id else { return }
        let handler = notifyOnExit ? terminationHandler : nil
        await stop()
        await handler?()
    }

    private func serverExited(id: UUID) async {
        guard serviceID == id else { return }
        let gate = trustGate
        let sessions = security
        let handler = notifyOnExit ? terminationHandler : nil
        serviceID = nil
        serviceTask = nil
        monitorTask?.cancel()
        monitorTask = nil
        trustGate = nil
        security = nil
        terminationHandler = nil
        notifyOnExit = false
        await gate?.deactivate()
        await sessions?.revokeAll()
        await handler?()
    }

    private static let csrfHeader = HTTPField.Name("X-KiwiOS-CSRF")!
    private static let sessionRequestHeader = HTTPField.Name("X-KiwiOS-Session")!
    private static let tailscaleLoginHeader = HTTPField.Name("Tailscale-User-Login")!
    private static let tailscaleNameHeader = HTTPField.Name("Tailscale-User-Name")!
    private static let tailscaleFunnelHeader = HTTPField.Name("Tailscale-Funnel-Request")!
    private static let forwardedHostHeader = HTTPField.Name("X-Forwarded-Host")!
    private static let forwardedProtoHeader = HTTPField.Name("X-Forwarded-Proto")!

    private static func identity(_ request: Request) throws -> RemoteIdentity {
        guard request.headers[tailscaleFunnelHeader] == nil,
              let login = request.headers[tailscaleLoginHeader]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let name = request.headers[tailscaleNameHeader]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !login.isEmpty, !name.isEmpty else { throw RemoteSecurityError.missingIdentity }
        guard login.utf8.count <= 320, name.utf8.count <= 512,
              !login.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw RemoteSecurityError.invalidIdentity
        }
        return RemoteIdentity(login: login, displayName: name)
    }

    private static func hasExpectedHost(_ request: Request, expectedHost: String) -> Bool {
        guard let raw = request.head.authority?.lowercased(),
              let forwarded = request.headers[forwardedHostHeader]?.lowercased(),
              request.headers[forwardedProtoHeader]?.lowercased() == "https" else { return false }
        let externalHostMatches = forwarded == expectedHost.lowercased() || forwarded == "\(expectedHost.lowercased()):443"
        let backendHostMatches = raw == "\(TailscaleService.loopbackHost):\(TailscaleService.loopbackPort)"
            || raw == expectedHost.lowercased() || raw == "\(expectedHost.lowercased()):443"
        return externalHostMatches && backendHostMatches
    }

    private static func isVerifiedServeRequest(_ request: Request, expectedHost: String) -> Bool {
        hasExpectedHost(request, expectedHost: expectedHost) && (try? identity(request)) != nil
    }

    private static func sessionCookie(_ request: Request) -> String? {
        guard let header = request.headers[.cookie] else { return nil }
        for component in header.split(separator: ";") {
            let pair = component.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2, pair[0] == RemoteSession.cookieName { return pair[1] }
        }
        return nil
    }

    static func validateMutationShape(_ data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawOperation = object["operation"] as? String,
              let operation = RemoteMutation.Operation(rawValue: rawOperation) else {
            throw RemoteSecurityError.invalidIdentity
        }
        let common = Set(["requestID", "operation"])
        let fields: Set<String>
        switch operation {
        case .refreshCheck, .requestAction: fields = ["pluginID", "contributionID"]
        case .confirmAction: fields = ["confirmationToken"]
        case .cancelJob: fields = ["jobID"]
        case .disablePlugin, .enablePlugin: fields = ["pluginID"]
        case .saveConfig: fields = ["pluginID", "values", "configRevision"]
        case .refreshDoctor, .reloadPlugins, .refreshNativeTools: fields = []
        case .saveLayout: fields = ["widgets", "hiddenWidgets", "wideWidgets", "sidebar"]
        case .requestProcessTermination: fields = ["pid"]
        case .confirmNativeOperation: fields = ["confirmationToken"]
        case .probeSSH: fields = ["peerName"]
        case .deliverNotification: fields = ["title", "body"]
        }
        guard Set(object.keys) == common.union(fields),
              fields.allSatisfy({ object[$0] != nil && !(object[$0] is NSNull) }) else {
            throw RemoteSecurityError.invalidIdentity
        }
    }

    private static func apiHeaders() -> HTTPFields {
        var headers = securityHeaders()
        headers[.contentType] = "application/json; charset=utf-8"
        headers[.cacheControl] = "no-store"
        return headers
    }

    private static func securityHeaders() -> HTTPFields {
        var headers = HTTPFields()
        headers[HTTPField.Name("Content-Security-Policy")!] = "default-src 'self'; connect-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'"
        headers[HTTPField.Name("Referrer-Policy")!] = "no-referrer"
        headers[HTTPField.Name("X-Content-Type-Options")!] = "nosniff"
        headers[HTTPField.Name("X-Frame-Options")!] = "DENY"
        headers[HTTPField.Name("Strict-Transport-Security")!] = "max-age=31536000"
        return headers
    }

    private static func asset(_ data: Data, contentType: String, cache: Bool) -> Response {
        var headers = securityHeaders()
        headers[.contentType] = contentType
        headers[.cacheControl] = cache ? "public, max-age=3600" : "no-cache"
        return response(data, headers: headers)
    }

    private static func response(_ data: Data, status: HTTPResponse.Status = .ok, headers: HTTPFields) -> Response {
        Response(status: status, headers: headers,
                 body: .init(byteBuffer: ByteBufferAllocator().buffer(bytes: data)))
    }

    private static func forbidden() -> Response {
        errorResponse(RemoteSecurityError.invalidOrigin)
    }

    private static func errorResponse(_ error: Error) -> Response {
        let status: HTTPResponse.Status
        switch error {
        case RemoteSecurityError.rateLimited: status = .tooManyRequests
        case RemoteSecurityError.sessionCapacityReached: status = .serviceUnavailable
        case RemoteSecurityError.invalidContentType: status = .unsupportedMediaType
        case RemoteSecurityError.replayedRequest: status = .conflict
        case PersistenceError.configConflict: status = .conflict
        case is RemoteSecurityError: status = .unauthorized
        case is CancellationError: status = .gatewayTimeout
        default: status = .badRequest
        }
        let code: String
        if let securityError = error as? RemoteSecurityError, securityError == .sessionCapacityReached {
            code = "session_capacity_reached"
        } else {
            code = "request_rejected"
        }
        let body = (try? JSONSerialization.data(withJSONObject: ["error": code])) ?? Data()
        return response(body, status: status, headers: apiHeaders())
    }
}

private actor RemoteTrustGate {
    private let expectedOrigin: URL
    private var trust: ManagedServeTrust?
    init(expectedOrigin: URL) { self.expectedOrigin = expectedOrigin }
    var isActive: Bool { trust != nil }

    func activate(_ trust: ManagedServeTrust) throws {
        guard self.trust == nil, trust.origin == expectedOrigin else { throw RemoteServerError.alreadyRunning }
        self.trust = trust
    }
    func deactivate() { trust = nil }
}

private actor RemoteStartupSignal {
    private var result: Result<Void, Error>?
    private var waiter: CheckedContinuation<Void, Error>?
    private var timeoutTask: Task<Void, Never>?

    func waitForResult() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let result {
                    continuation.resume(with: result)
                    return
                }
                waiter = continuation
                timeoutTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    await self?.fail(CancellationError())
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter() }
        }
    }
    func succeed() { resolve(.success(())) }
    func fail(_ error: Error) { resolve(.failure(error)) }
    private func resolve(_ result: Result<Void, Error>) {
        guard self.result == nil else { return }
        self.result = result
        timeoutTask?.cancel()
        timeoutTask = nil
        waiter?.resume(with: result)
        waiter = nil
    }
    private func cancelWaiter() {
        resolve(.failure(CancellationError()))
    }
}

private struct RemoteWebAssets: Sendable {
    let index: Data
    let styles: Data
    let script: Data
    let manifest: Data
    let favicon: Data
    let icon192: Data
    let icon512: Data
    let serviceWorker: Data

    static func load(bundle: Bundle = .main) throws -> Self {
        func read(_ name: String, _ extension: String) throws -> Data {
            let url = bundle.url(forResource: name, withExtension: `extension`, subdirectory: "Web")
                ?? bundle.url(forResource: name, withExtension: `extension`)
            guard let url else { throw RemoteServerError.assetsUnavailable }
            return try Data(contentsOf: url, options: .mappedIfSafe)
        }
        return try Self(index: read("index", "html"), styles: read("app", "css"), script: read("app", "js"),
                        manifest: read("manifest", "webmanifest"), favicon: read("favicon", "png"),
                        icon192: read("icon-192", "png"), icon512: read("icon-512", "png"),
                        serviceWorker: read("service-worker", "js"))
    }
}
