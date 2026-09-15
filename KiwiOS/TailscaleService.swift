import Foundation
import CryptoKit
import Subprocess
import System

struct ManagedServeTrust: Codable, Equatable, Sendable {
    let origin: URL
    let configurationDigest: Data
}

struct RemotePublicationPlan: Codable, Equatable, Sendable {
    let origin: URL
    /// The complete Serve configuration can contain independently managed endpoints.
    /// This digest reserves only KiwiOS's HTTPS port until publication commits.
    fileprivate let managedPortDigest: Data

    init(origin: URL) {
        self.origin = origin
        self.managedPortDigest = Data()
    }

    fileprivate init(origin: URL, managedPortDigest: Data) {
        self.origin = origin
        self.managedPortDigest = managedPortDigest
    }
}

struct TailscaleServeState: Sendable, Equatable {
    enum Unavailability: Sendable, Equatable {
        case executableMissing
        case loggedOut
        case stopped
        case httpsUnavailable
        case commandFailed(String)

        var message: String {
            switch self {
            case .executableMissing: "Tailscale CLI is unavailable"
            case .loggedOut: "Tailscale is installed but needs sign-in"
            case .stopped: "Tailscale is installed but not connected"
            case .httpsUnavailable: "Enable HTTPS certificates for this tailnet before using Serve"
            case .commandFailed(let detail): detail
            }
        }
    }

    enum Status: Sendable, Equatable {
        case unavailable(String)
        case available(origin: URL)
        case conflict(String)
        case managed(origin: URL)
    }

    let status: Status
    let unavailability: Unavailability?

    init(status: Status, unavailability: Unavailability? = nil) {
        self.status = status
        self.unavailability = unavailability
    }
}

enum TailscaleServiceError: LocalizedError {
    case executableMissing
    case notConnected(String?)
    case httpsUnavailable
    case managedPortConfigured
    case invalidDNSName
    case commandFailed(String)
    case configurationChanged

    var errorDescription: String? {
        switch self {
        case .executableMissing: "Tailscale CLI is unavailable"
        case .notConnected(let state):
            state == "NeedsLogin" ? "Tailscale needs sign-in" : "Tailscale is not connected"
        case .httpsUnavailable: "Enable HTTPS certificates for this tailnet before using Serve"
        case .managedPortConfigured: "Tailscale HTTPS port 443 is already configured; KiwiOS will not overwrite it"
        case .invalidDNSName: "Tailscale did not report a valid tailnet DNS name"
        case .commandFailed(let detail): "Tailscale command failed: \(detail)"
        case .configurationChanged: "Tailscale Serve configuration changed outside KiwiOS"
        }
    }
}

/// Owns exactly one root HTTPS Serve mapping without altering independently managed endpoints.
/// No command is run until a caller explicitly invokes `start()` or `stop()` from native UI.
actor TailscaleService {
    static let loopbackHost = "127.0.0.1"
    static let loopbackPort = 31_928
    static let httpsPort = 443

    typealias CommandRunner = @Sendable (_ executable: URL, _ arguments: [String]) async throws -> Data

    private var executable: URL?
    private let run: CommandRunner
    private var managedTrust: ManagedServeTrust?
    /// Set after KiwiOS has issued the Serve mutation and cleared only after its exact
    /// mapping is verified or removed. This preserves cleanup ownership if status fails.
    private var publicationAttemptOrigin: URL?

    init(executable: URL? = TailscaleService.findExecutable(), run: @escaping CommandRunner = TailscaleService.runCommand) {
        self.executable = executable
        self.run = run
    }

    func inspect() async -> TailscaleServeState {
        guard let executable = resolveExecutable() else {
            let reason = TailscaleServeState.Unavailability.executableMissing
            return .init(status: .unavailable(reason.message), unavailability: reason)
        }
        do {
            let origin = try await origin(executable: executable)
            let serve = try await run(executable, ["serve", "status", "--json"])
            if let trust = managedTrust,
               trust.origin == origin,
               trust.configurationDigest == Self.managedPortDigest(serve, origin: origin),
               Self.matchesManagedConfiguration(serve, origin: origin) {
                return .init(status: .managed(origin: origin))
            }
            if publicationAttemptOrigin == origin,
               Self.matchesManagedConfiguration(serve, origin: origin) {
                let trust = ManagedServeTrust(origin: origin, configurationDigest: Self.managedPortDigest(serve, origin: origin))
                managedTrust = trust
                publicationAttemptOrigin = nil
                return .init(status: .managed(origin: origin))
            }
            guard !Self.managedPortIsConfigured(serve, origin: origin) else {
                return .init(status: .conflict("Tailscale HTTPS port 443 is already configured"))
            }
            return .init(status: .available(origin: origin))
        } catch {
            let reason = Self.unavailability(for: error)
            return .init(status: .unavailable(reason.message), unavailability: reason)
        }
    }

    /// Performs every safety check needed before the loopback listener binds, without changing Tailscale.
    func prepare() async throws -> RemotePublicationPlan {
        guard let executable = resolveExecutable() else { throw TailscaleServiceError.executableMissing }
        let expectedOrigin = try await origin(executable: executable)
        let serve = try await run(executable, ["serve", "status", "--json"])
        guard !Self.managedPortIsConfigured(serve, origin: expectedOrigin) else { throw TailscaleServiceError.managedPortConfigured }
        return RemotePublicationPlan(origin: expectedOrigin, managedPortDigest: Self.managedPortDigest(serve, origin: expectedOrigin))
    }

    /// Enables a persistent, tailnet-only HTTPS proxy after proving its own port is unused.
    func start(plan: RemotePublicationPlan) async throws -> ManagedServeTrust {
        guard let executable = resolveExecutable() else { throw TailscaleServiceError.executableMissing }
        let expectedOrigin = try await origin(executable: executable)
        guard expectedOrigin == plan.origin else { throw TailscaleServiceError.configurationChanged }
        let serveBefore = try await run(executable, ["serve", "status", "--json"])
        guard Self.managedPortDigest(serveBefore, origin: expectedOrigin) == plan.managedPortDigest,
              !Self.managedPortIsConfigured(serveBefore, origin: expectedOrigin) else {
            throw TailscaleServiceError.managedPortConfigured
        }

        let target = "http://\(Self.loopbackHost):\(Self.loopbackPort)"
        managedTrust = nil
        publicationAttemptOrigin = expectedOrigin
        _ = try await run(executable, ["serve", "--bg", "--https=\(Self.httpsPort)", target])
        let serveAfter = try await run(executable, ["serve", "status", "--json"])
        guard Self.matchesManagedConfiguration(serveAfter, origin: expectedOrigin) else {
            throw TailscaleServiceError.configurationChanged
        }
        let trust = ManagedServeTrust(origin: expectedOrigin,
                                      configurationDigest: Self.managedPortDigest(serveAfter, origin: expectedOrigin))
        managedTrust = trust
        publicationAttemptOrigin = nil
        return trust
    }

    /// Restores ownership after app relaunch when KiwiOS's exact mapping still matches.
    /// A persisted pre-shared-config trust record is upgraded here after confirming its mapping.
    func restore(_ trust: ManagedServeTrust) async throws -> ManagedServeTrust {
        guard let executable = resolveExecutable() else { throw TailscaleServiceError.executableMissing }
        let currentOrigin = try await origin(executable: executable)
        let current = try await run(executable, ["serve", "status", "--json"])
        guard currentOrigin == trust.origin,
              Self.matchesManagedConfiguration(current, origin: currentOrigin) else {
            throw TailscaleServiceError.configurationChanged
        }
        let restored = ManagedServeTrust(origin: currentOrigin,
                                         configurationDigest: Self.managedPortDigest(current, origin: currentOrigin))
        managedTrust = restored
        return restored
    }

    func validate(_ trust: ManagedServeTrust) async throws -> Bool {
        guard let executable = resolveExecutable() else { throw TailscaleServiceError.executableMissing }
        let currentOrigin = try await origin(executable: executable)
        let current = try await run(executable, ["serve", "status", "--json"])
        return currentOrigin == trust.origin
            && trust.configurationDigest == Self.managedPortDigest(current, origin: currentOrigin)
            && Self.matchesManagedConfiguration(current, origin: currentOrigin)
    }

    /// Removes only the exact root mapping previously created by this process.
    func stop() async throws {
        guard managedTrust != nil || publicationAttemptOrigin != nil else { return }
        guard let executable = resolveExecutable() else { throw TailscaleServiceError.executableMissing }
        let current = try await runCleanup(executable, ["serve", "status", "--json"])
        if let trust = managedTrust {
            guard Self.managedPortDigest(current, origin: trust.origin) == trust.configurationDigest,
                  Self.matchesManagedConfiguration(current, origin: trust.origin) else {
                throw TailscaleServiceError.configurationChanged
            }
        } else if let origin = publicationAttemptOrigin {
            if !Self.managedPortIsConfigured(current, origin: origin) {
                publicationAttemptOrigin = nil
                return
            }
            guard Self.matchesManagedConfiguration(current, origin: origin) else {
                throw TailscaleServiceError.configurationChanged
            }
        } else {
            return
        }
        _ = try await runCleanup(executable, ["serve", "--https=\(Self.httpsPort)", "off"])
        managedTrust = nil
        publicationAttemptOrigin = nil
    }

    /// The journal was written only after verifying KiwiOS's port was unused. A retry
    /// still proves exact origin/target/shape ownership before issuing any cleanup.
    func recoverPublicationAttempt(_ plan: RemotePublicationPlan) async throws {
        publicationAttemptOrigin = plan.origin
        try await stop()
    }

    private func resolveExecutable() -> URL? {
        if let executable, FileManager.default.isExecutableFile(atPath: executable.path) { return executable }
        let discovered = Self.findExecutable()
        executable = discovered
        return discovered
    }

    /// Cleanup must finish even when its UI or health-monitor task was canceled.
    private func runCleanup(_ executable: URL, _ arguments: [String]) async throws -> Data {
        let run = self.run
        return try await Task.detached { try await run(executable, arguments) }.value
    }

    private func origin(executable: URL) async throws -> URL {
        struct Status: Decodable {
            struct SelfNode: Decodable {
                let DNSName: String?
            }
            let BackendState: String?
            let CertDomains: [String]?
            let `Self`: SelfNode?
        }
        let data = try await run(executable, ["status", "--json"])
        let status = try JSONDecoder().decode(Status.self, from: data)
        guard status.BackendState == "Running" else {
            throw TailscaleServiceError.notConnected(status.BackendState)
        }
        guard let raw = status.Self?.DNSName?.trimmingCharacters(in: CharacterSet(charactersIn: ".")),
              !raw.isEmpty, raw.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-").contains($0) }),
              let origin = URL(string: "https://\(raw)"), origin.host == raw else {
            throw TailscaleServiceError.invalidDNSName
        }
        guard status.CertDomains?.contains(where: {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                .caseInsensitiveCompare(raw) == .orderedSame
        }) == true else {
            throw TailscaleServiceError.httpsUnavailable
        }
        return origin
    }

    private static func findExecutable() -> URL? {
        let candidates = [
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
            "/usr/local/bin/tailscale",
            "/opt/homebrew/bin/tailscale",
        ]
        return candidates.lazy.map(URL.init(fileURLWithPath:)).first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func runCommand(executable: URL, arguments: [String]) async throws -> Data {
        var environment = ProcessInfo.processInfo.environment.filter {
            ["HOME", "USER", "TMPDIR", "LANG"].contains($0.key)
        }
        // Avoid the macOS app executable's shell-environment heuristic.
        environment["TAILSCALE_BE_CLI"] = "1"
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let subprocessEnvironment = Dictionary(uniqueKeysWithValues: environment.map {
            (Subprocess.Environment.Key(rawValue: $0.key)!, $0.value)
        })
        var platformOptions = PlatformOptions()
        platformOptions.createSession = true
        platformOptions.teardownSequence = [
            .gracefulShutDown(toProcessGroup: true, allowedDurationToNextStep: .seconds(2)),
        ]
        let configuration = Subprocess.Configuration(
            executable: .path(FilePath(executable.path)),
            arguments: Subprocess.Arguments(arguments),
            environment: .custom(subprocessEnvironment),
            workingDirectory: nil,
            platformOptions: platformOptions
        )
        let result = try await ProcessTransport.run(configuration: configuration,
            timeout: 8, maximumOutputBytes: 1_048_576, maximumErrorBytes: 64 * 1_024)
        guard !result.timedOut else { throw TailscaleServiceError.commandFailed("command timed out") }
        guard result.exitCode == 0, !result.truncated else {
            let detail = String(decoding: (result.errorOutput.isEmpty ? result.output : result.errorOutput).prefix(4_096), as: UTF8.self)
            throw TailscaleServiceError.commandFailed(detail.isEmpty ? "exit \(result.exitCode)" : detail)
        }
        return result.output
    }

    private static func matchesManagedConfiguration(_ data: Data, origin: URL) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              !hasFunnelEnabled(data, on: httpsPort),
              let tcp = root["TCP"] as? [String: Any],
              let port = tcp[String(httpsPort)] as? [String: Any], port.count == 1,
              port["HTTPS"] as? Bool == true,
              let host = origin.host?.lowercased(),
              let web = root["Web"] as? [String: Any],
              let server = web["\(host):\(httpsPort)"] as? [String: Any], server.count == 1,
              let handlers = server["Handlers"] as? [String: Any], handlers.count == 1,
              let handler = handlers["/"] as? [String: Any], handler.count == 1,
              handler["Proxy"] as? String == "http://\(loopbackHost):\(loopbackPort)" else { return false }
        return true
    }

    private static func managedPortIsConfigured(_ data: Data, origin: URL) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return true }
        let port = String(httpsPort)
        if (root["TCP"] as? [String: Any])?[port] != nil { return true }
        if (root["Web"] as? [String: Any])?["\(origin.host?.lowercased() ?? ""):\(port)"] != nil { return true }
        return hasFunnelEnabled(data, on: httpsPort)
    }

    private static func hasFunnelEnabled(_ data: Data, on port: Int) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let flags = root["AllowFunnel"] as? [String: Any] else { return false }
        return flags.contains { key, value in
            (value as? Bool) == true && (key == String(port) || key.hasSuffix(":\(port)"))
        }
    }

    /// Canonicalize only the configuration entries that can claim KiwiOS's HTTPS port.
    private static func managedPortDigest(_ data: Data, origin: URL) -> Data {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Data(SHA256.hash(data: data))
        }
        let port = String(httpsPort)
        let hostPort = "\(origin.host?.lowercased() ?? ""):\(port)"
        let funnel = (root["AllowFunnel"] as? [String: Any] ?? [:]).filter { key, _ in
            key == port || key.hasSuffix(":\(port)")
        }
        let projection: [String: Any] = [
            "TCP": (root["TCP"] as? [String: Any])?[port] ?? NSNull(),
            "Web": (root["Web"] as? [String: Any])?[hostPort] ?? NSNull(),
            "AllowFunnel": funnel,
        ]
        guard let canonical = try? JSONSerialization.data(withJSONObject: projection, options: [.sortedKeys]) else {
            return Data(SHA256.hash(data: data))
        }
        return Data(SHA256.hash(data: canonical))
    }

    private static func unavailability(for error: Error) -> TailscaleServeState.Unavailability {
        guard let error = error as? TailscaleServiceError else {
            return .commandFailed(error.localizedDescription)
        }
        switch error {
        case .executableMissing:
            return .executableMissing
        case .notConnected(let state):
            return state == "NeedsLogin" ? .loggedOut : .stopped
        case .httpsUnavailable:
            return .httpsUnavailable
        default:
            return .commandFailed(error.localizedDescription)
        }
    }
}
