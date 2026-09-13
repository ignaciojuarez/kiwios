import Foundation
import AppKit
import Darwin
import UserNotifications
import Subprocess
import System

struct NativeToolsSnapshot: Codable, Equatable, Sendable {
    let sampledAt: Date
    let processes: [NativeProcessIdentity]
    let launchAgents: [NativeLaunchAgent]
    let launchAgentWarning: String?
    let homebrew: NativeHomebrewStatus
    let power: NativePowerStatus
    let notificationAuthorization: NativeNotificationAuthorization
}

struct NativeProcessIdentity: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id: Int32 { pid }
    let pid: Int32
    let uid: UInt32
    let startTimeMicroseconds: UInt64
    let executablePath: String
    let displayName: String
    let bundleIdentifier: String?
    let canTerminate: Bool
}

struct NativeLaunchAgent: Codable, Equatable, Identifiable, Sendable {
    var id: String { plistPath }
    let label: String
    let plistPath: String
    let isLoaded: Bool?
    let issue: String?
}

enum NativeHomebrewStatus: Codable, Equatable, Sendable {
    case unavailable
    case available(path: String, outdatedFormulae: [String], outdatedCasks: [String])
    case error(path: String, message: String)
}

struct NativePowerStatus: Codable, Equatable, Sendable {
    let lowPowerModeEnabled: Bool
    let fileVault: String
    let restartSupport: String
}

enum NativeNotificationAuthorization: String, Codable, Equatable, Sendable {
    case notDetermined = "not-determined"
    case denied, authorized, provisional, ephemeral, unknown
}

struct NamedSSHPeer: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id: String { name }
    let name: String
    let destination: String
    let port: UInt16
}

enum NativeOperation: Codable, Equatable, Hashable, Sendable {
    case terminateProcess(NativeProcessIdentity)
    case kickstartLaunchAgent(label: String)
    case homebrewUpdate
    case homebrewInstall(packages: [String])
    case homebrewUninstall(packages: [String])
    case homebrewUpgrade(packages: [String])
    case probeSSH(peerName: String)
    case requestNotificationAuthorization
    case deliverNotification(title: String, body: String)

    var contributionID: String {
        switch self {
        case .terminateProcess(let process): "process-terminate-\(process.pid)"
        case .kickstartLaunchAgent: "launch-agent-kickstart"
        case .homebrewUpdate: "homebrew-update"
        case .homebrewInstall: "homebrew-install"
        case .homebrewUninstall: "homebrew-uninstall"
        case .homebrewUpgrade: "homebrew-upgrade"
        case .probeSSH: "ssh-probe"
        case .requestNotificationAuthorization: "notification-authorization"
        case .deliverNotification: "notification-delivery"
        }
    }

    var resource: String {
        switch self {
        case .terminateProcess(let process): "process/\(process.pid)"
        case .kickstartLaunchAgent(let label): "launchd/\(label)"
        case .homebrewUpdate, .homebrewInstall, .homebrewUninstall, .homebrewUpgrade: "homebrew"
        case .probeSSH(let peerName): "ssh/\(peerName)"
        case .requestNotificationAuthorization, .deliverNotification: "notifications"
        }
    }

    var confirmationTitle: String? {
        switch self {
        case .terminateProcess(let process): "Send a quit signal to \(process.displayName)?"
        case .kickstartLaunchAgent(let label): "Restart \(label)?"
        case .homebrewUpdate: "Update Homebrew metadata?"
        case .homebrewInstall(let packages): "Install \(packages.count) Homebrew package\(packages.count == 1 ? "" : "s")?"
        case .homebrewUninstall(let packages): "Uninstall \(packages.count) Homebrew package\(packages.count == 1 ? "" : "s")?"
        case .homebrewUpgrade(let packages): "Upgrade \(packages.count) Homebrew item\(packages.count == 1 ? "" : "s")?"
        case .probeSSH: nil
        case .requestNotificationAuthorization: "Ask macOS for notification access?"
        case .deliverNotification: nil
        }
    }

    var confirmationDetail: String? {
        switch self {
        case .homebrewInstall(let packages):
            return "KiwiOS will run Homebrew to install:\n\(packages.sorted().joined(separator: "\n"))"
        case .homebrewUninstall(let packages):
            return "KiwiOS will run Homebrew to uninstall:\n\(packages.sorted().joined(separator: "\n"))\n\nOther scripts and projects are not visible to KiwiOS."
        default: return nil
        }
    }
}

enum NativeCapabilityError: LocalizedError {
    case blocked(String)
    case commandFailed(String)
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .blocked(let reason), .commandFailed(let reason), .timedOut(let reason): reason
        }
    }
}

actor NativeCapabilities {
    private var namedSSHPeers: [String: NamedSSHPeer] = [:]
    private let commandRunner = NativeCommandRunner()

    func setNamedSSHPeers(_ peers: [NamedSSHPeer]) throws {
        var configured: [String: NamedSSHPeer] = [:]
        for peer in peers {
            try Self.validate(peer)
            guard configured[peer.name] == nil else {
                throw NativeCapabilityError.blocked("SSH peer names must be unique")
            }
            configured[peer.name] = peer
        }
        namedSSHPeers = configured
    }

    func toolsSnapshot() async -> NativeToolsSnapshot {
        async let brew = homebrewStatus()
        async let power = powerStatus()
        async let notifications = notificationAuthorization()
        let processes = await Self.aquaProcesses()
        let launchAgentDiscovery = Self.userLaunchAgents()
        let launchAgents = await launchAgentStatuses(launchAgentDiscovery.agents)
        let (homebrewStatus, powerStatus, notificationStatus) = await (brew, power, notifications)
        return NativeToolsSnapshot(
            sampledAt: Date(),
            processes: processes,
            launchAgents: launchAgents,
            launchAgentWarning: launchAgentDiscovery.warning,
            homebrew: homebrewStatus,
            power: powerStatus,
            notificationAuthorization: notificationStatus
        )
    }

    func validate(_ operation: NativeOperation, mode: OperationMode) async throws {
        switch operation {
        case .terminateProcess(let expected):
            guard expected.canTerminate else {
                throw NativeCapabilityError.blocked("KiwiOS only terminates non-Apple Aqua apps running as the current user")
            }
            _ = try await Self.verifiedProcess(expected)
        case .kickstartLaunchAgent(let label):
            guard mode == .setup else {
                throw NativeCapabilityError.blocked("Launch agent changes require attended setup")
            }
            let matches = Self.userLaunchAgents().agents.filter { $0.label == label && $0.issue == nil }
            guard matches.count == 1 else {
                throw NativeCapabilityError.blocked("The launch agent is not a current-user agent declared in ~/Library/LaunchAgents")
            }
        case .homebrewUpdate:
            guard mode == .setup else {
                throw NativeCapabilityError.blocked("Homebrew changes are disabled in remote policy mode")
            }
            _ = try Self.homebrewExecutable()
        case .homebrewInstall(let packages):
            guard mode == .setup else {
                throw NativeCapabilityError.blocked("Homebrew changes are disabled in remote policy mode")
            }
            guard !packages.isEmpty, packages.count <= 50,
                  packages.allSatisfy(Self.validCoreBrewFormula) else {
                throw NativeCapabilityError.blocked("Choose 1–50 valid Homebrew core formula names")
            }
            _ = try Self.homebrewExecutable()
            guard packages.allSatisfy({ !BrewFormulaStatus.isInstalled($0) }) else {
                throw NativeCapabilityError.blocked("A selected Homebrew formula was installed after review; review the current missing list again")
            }
        case .homebrewUninstall(let packages):
            guard mode == .setup else {
                throw NativeCapabilityError.blocked("Homebrew changes are disabled in remote policy mode")
            }
            guard !packages.isEmpty, packages.count <= 50,
                  packages.allSatisfy(Self.validCoreBrewFormula) else {
                throw NativeCapabilityError.blocked("Choose 1–50 valid Homebrew core formula names")
            }
            _ = try Self.homebrewExecutable()
            for package in packages where BrewFormulaStatus.isInstalled(package) {
                let dependents = try await installedHomebrewDependents(of: package)
                guard dependents.isEmpty else {
                    throw NativeCapabilityError.blocked(
                        "Homebrew package \(package) is still required by: \(dependents.joined(separator: ", "))"
                    )
                }
            }
        case .homebrewUpgrade(let packages):
            guard mode == .setup else {
                throw NativeCapabilityError.blocked("Homebrew changes are disabled in remote policy mode")
            }
            guard !packages.isEmpty, packages.count <= 50,
                  packages.allSatisfy(Self.validBrewPackage) else {
                throw NativeCapabilityError.blocked("Choose 1–50 valid Homebrew formula or cask names")
            }
            _ = try Self.homebrewExecutable()
        case .probeSSH(let peerName):
            guard let peer = namedSSHPeers[peerName] else {
                throw NativeCapabilityError.blocked("SSH peer is not in the configured named allowlist")
            }
            try Self.validate(peer)
        case .requestNotificationAuthorization:
            guard mode == .setup else {
                throw NativeCapabilityError.blocked("Notification authorization requires attended setup")
            }
        case .deliverNotification(let title, let body):
            guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  title.utf8.count <= 160, body.utf8.count <= 4_096 else {
                throw NativeCapabilityError.blocked("Notification title or body is invalid")
            }
            guard await notificationAuthorization() == .authorized else {
                throw NativeCapabilityError.blocked("Notification delivery requires authorization completed in attended setup")
            }
        }
    }

    func execute(_ operation: NativeOperation) async throws -> JobExecutionResult {
        do { return try await perform(operation) }
        catch NativeCapabilityError.timedOut(let summary) {
            return result(summary, status: .timedOut)
        }
    }

    private func perform(_ operation: NativeOperation) async throws -> JobExecutionResult {
        switch operation {
        case .terminateProcess(let expected):
            let current = try await Self.verifiedProcess(expected)
            guard kill(current.pid, SIGTERM) == 0 else {
                throw NativeCapabilityError.commandFailed("Could not send a quit signal to \(current.displayName): \(String(cString: strerror(errno)))")
            }
            return result("Sent a quit signal to \(current.displayName)")

        case .kickstartLaunchAgent(let label):
            let matches = Self.userLaunchAgents().agents.filter { $0.label == label && $0.issue == nil }
            guard matches.count == 1 else {
                throw NativeCapabilityError.blocked("The launch agent changed before execution")
            }
            let target = "gui/\(getuid())/\(label)"
            let output = try await commandRunner.run(
                executable: "/bin/launchctl", arguments: ["kickstart", "-k", target], timeout: 15
            )
            try requireSuccess(output, action: "launch agent restart")
            return result("Restarted \(label)")

        case .homebrewUpdate:
            let brew = try Self.homebrewExecutable()
            let output = try await commandRunner.run(
                executable: brew, arguments: ["update"], environment: Self.brewEnvironment, timeout: 120
            )
            try requireSuccess(output, action: "Homebrew update")
            return result("Updated Homebrew metadata")

        case .homebrewInstall(let packages):
            guard !packages.isEmpty, packages.count <= 50,
                  packages.allSatisfy(Self.validCoreBrewFormula) else {
                throw NativeCapabilityError.blocked("The Homebrew selection changed before execution")
            }
            let brew = try Self.homebrewExecutable()
            let output = try await commandRunner.run(
                executable: brew, arguments: ["install", "--formula"] + packages,
                environment: Self.brewEnvironment, timeout: 900
            )
            try requireSuccess(output, action: "Homebrew install")
            return result("Installed \(packages.count) Homebrew package\(packages.count == 1 ? "" : "s")")

        case .homebrewUninstall(let packages):
            guard !packages.isEmpty, packages.count <= 50,
                  packages.allSatisfy(Self.validCoreBrewFormula) else {
                throw NativeCapabilityError.blocked("The Homebrew selection changed before execution")
            }
            let installed = packages.filter { BrewFormulaStatus.isInstalled($0) }
            guard !installed.isEmpty else {
                return result("The selected Homebrew package\(packages.count == 1 ? " is" : "s are") already absent")
            }
            let brew = try Self.homebrewExecutable()
            let output = try await commandRunner.run(
                executable: brew, arguments: ["uninstall", "--formula"] + installed,
                environment: Self.brewEnvironment, timeout: 900
            )
            try requireSuccess(output, action: "Homebrew uninstall")
            return result("Uninstalled \(installed.count) Homebrew package\(installed.count == 1 ? "" : "s")")

        case .homebrewUpgrade(let packages):
            guard !packages.isEmpty, packages.count <= 50, packages.allSatisfy(Self.validBrewPackage) else {
                throw NativeCapabilityError.blocked("The Homebrew selection changed before execution")
            }
            let brew = try Self.homebrewExecutable()
            let output = try await commandRunner.run(
                executable: brew, arguments: ["upgrade"] + packages,
                environment: Self.brewEnvironment, timeout: 900
            )
            try requireSuccess(output, action: "Homebrew upgrade")
            return result("Upgraded \(packages.count) Homebrew item\(packages.count == 1 ? "" : "s")")

        case .probeSSH(let peerName):
            guard let peer = namedSSHPeers[peerName] else {
                throw NativeCapabilityError.blocked("SSH peer changed or was removed before execution")
            }
            try Self.validate(peer)
            let output = try await commandRunner.run(
                executable: "/usr/bin/ssh",
                arguments: [
                    "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                    "-o", "ConnectTimeout=5", "-o", "ConnectionAttempts=1",
                    "-p", String(peer.port), peer.destination, "true",
                ],
                timeout: 10
            )
            guard output.exitCode == 0 else {
                return result("SSH check failed without prompting: \(output.conciseError)", status: .warning)
            }
            return result("SSH connection to \(peer.name) succeeded")

        case .requestNotificationAuthorization:
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            return result(granted ? "Notifications authorized" : "Notification access was not granted",
                          status: granted ? .succeeded : .warning)

        case .deliverNotification(let title, let body):
            guard await notificationAuthorization() == .authorized else {
                throw NativeCapabilityError.blocked("Notification access is not authorized")
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            try await UNUserNotificationCenter.current().add(request)
            return result("Delivered a local notification")
        }
    }

    private func homebrewStatus() async -> NativeHomebrewStatus {
        let path: String
        do { path = try Self.homebrewExecutable() }
        catch { return .unavailable }
        do {
            let output = try await commandRunner.run(
                executable: path,
                arguments: ["outdated", "--json=v2"],
                environment: Self.brewEnvironment,
                timeout: 30
            )
            guard output.exitCode == 0 else { return .error(path: path, message: output.conciseError) }
            guard let object = try JSONSerialization.jsonObject(with: output.output) as? [String: Any] else {
                return .error(path: path, message: "Homebrew returned invalid JSON")
            }
            let formulae = (object["formulae"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            let casks = (object["casks"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            return .available(path: path, outdatedFormulae: formulae, outdatedCasks: casks)
        } catch { return .error(path: path, message: error.localizedDescription) }
    }

    func installedHomebrewDependents(of formula: String) async throws -> [String] {
        guard Self.validCoreBrewFormula(formula) else {
            throw NativeCapabilityError.blocked("Invalid Homebrew core formula name")
        }
        let brew = try Self.homebrewExecutable()
        let output = try await commandRunner.run(
            executable: brew, arguments: ["uses", "--installed", "--recursive", formula],
            environment: Self.brewEnvironment, timeout: 30
        )
        try requireSuccess(output, action: "Homebrew dependency check")
        return Array(Set(String(decoding: output.output, as: UTF8.self)
            .split(whereSeparator: \.isNewline).map(String.init))).sorted()
    }

    private func powerStatus() async -> NativePowerStatus {
        let fileVault = await HostDoctor.inspectFileVault(
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        return NativePowerStatus(
            lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            fileVault: fileVault.detail,
            restartSupport: "Unavailable: KiwiOS has no privileged helper and never invokes sudo"
        )
    }

    private func launchAgentStatuses(_ agents: [NativeLaunchAgent]) async -> [NativeLaunchAgent] {
        let runner = commandRunner
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(15))
        var result: [NativeLaunchAgent] = []
        let concurrency = 6

        for start in stride(from: 0, to: agents.count, by: concurrency) {
            let batch = Array(agents[start..<min(start + concurrency, agents.count)])
            guard clock.now < deadline else {
                result += batch.map { NativeLaunchAgent(
                    label: $0.label, plistPath: $0.plistPath, isLoaded: nil,
                    issue: $0.issue ?? "Status was not checked before the inspection deadline"
                ) }
                if start + batch.count < agents.count {
                    result += agents[(start + batch.count)...].map { NativeLaunchAgent(
                        label: $0.label, plistPath: $0.plistPath, isLoaded: nil,
                        issue: $0.issue ?? "Status was not checked before the inspection deadline"
                    ) }
                }
                break
            }
            let checked = await withTaskGroup(of: NativeLaunchAgent.self) { group in
                for agent in batch {
                    group.addTask {
                        guard agent.issue == nil else { return agent }
                        do {
                            let output = try await runner.run(
                                executable: "/bin/launchctl",
                                arguments: ["print", "gui/\(getuid())/\(agent.label)"],
                                timeout: 3
                            )
                            return NativeLaunchAgent(
                                label: agent.label, plistPath: agent.plistPath,
                                isLoaded: output.exitCode == 0, issue: nil
                            )
                        } catch {
                            return NativeLaunchAgent(
                                label: agent.label, plistPath: agent.plistPath,
                                isLoaded: nil, issue: agent.issue
                            )
                        }
                    }
                }
                return await group.reduce(into: [NativeLaunchAgent]()) { $0.append($1) }
            }
            result += checked
        }
        return result.sorted {
            let order = $0.label.localizedStandardCompare($1.label)
            return order == .orderedSame
                ? $0.plistPath.localizedStandardCompare($1.plistPath) == .orderedAscending
                : order == .orderedAscending
        }
    }

    private func notificationAuthorization() async -> NativeNotificationAuthorization {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: return .authorized
        case .provisional: return .provisional
        case .ephemeral: return .ephemeral
        @unknown default: return .unknown
        }
    }

    private func result(_ summary: String, status: JobStatus = .succeeded) -> JobExecutionResult {
        JobExecutionResult(status: status, summary: summary)
    }

    private func requireSuccess(_ output: CommandResult, action: String) throws {
        guard output.exitCode == 0 else {
            throw NativeCapabilityError.commandFailed("\(action) failed: \(output.conciseError)")
        }
    }

    private static var brewEnvironment: [String: String] {
        [
            "HOMEBREW_NO_AUTOREMOVE": "1",
            "HOMEBREW_NO_AUTO_UPDATE": "1",
            "HOMEBREW_NO_ENV_HINTS": "1",
            "HOMEBREW_NO_INSTALL_CLEANUP": "1",
            "HOMEBREW_NO_INSTALL_UPGRADE": "1",
            "NONINTERACTIVE": "1",
        ]
    }

    private static func homebrewExecutable() throws -> String {
        if let installation = BrewFormulaStatus.Installation.selected() { return installation.executable }
        throw NativeCapabilityError.blocked("Homebrew is not installed in a supported location")
    }

    private static func validBrewPackage(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9@+._/-]{1,160}$"#, options: .regularExpression) != nil
            && !value.contains("..") && !value.hasPrefix("-")
            && !value.hasPrefix("/") && !value.hasSuffix("/")
    }

    private static func validCoreBrewFormula(_ value: String) -> Bool {
        value.range(of: #"^[a-z0-9][a-z0-9@+._-]{0,159}$"#, options: .regularExpression) != nil
    }

    private static func validate(_ peer: NamedSSHPeer) throws {
        guard peer.name.range(of: #"^[A-Za-z0-9][A-Za-z0-9 ._-]{0,63}$"#, options: .regularExpression) != nil,
              peer.port > 0,
              peer.destination.range(
                of: #"^[A-Za-z0-9._-]+@[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$"#,
                options: .regularExpression
              ) != nil,
              !peer.destination.contains("..") else {
            throw NativeCapabilityError.blocked("SSH peers require a short name and a literal user@host destination")
        }
    }

    private static func aquaProcesses() async -> [NativeProcessIdentity] {
        let apps: [(Int32, String, String?)] = await MainActor.run {
            NSWorkspace.shared.runningApplications.compactMap { app in
                guard app.activationPolicy == .regular else { return nil }
                return (app.processIdentifier, app.localizedName ?? "Application", app.bundleIdentifier)
            }
        }
        return apps.compactMap { pid, name, bundleID in processIdentity(pid: pid, name: name, bundleID: bundleID) }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private static func processIdentity(pid: Int32, name: String, bundleID: String?) -> NativeProcessIdentity? {
        var info = proc_bsdinfo()
        let actual = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard actual == Int32(MemoryLayout<proc_bsdinfo>.size) else { return nil }
        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        guard pathLength > 0 else { return nil }
        let path = String(decoding: pathBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let uid = UInt32(info.pbi_uid)
        let start = UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec)
        let userApplications = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true).path + "/"
        let allowlistedPath = path.hasPrefix("/Applications/") || path.hasPrefix(userApplications)
        let protected = path.hasPrefix("/System/") || bundleID?.hasPrefix("com.apple.") == true
        return NativeProcessIdentity(
            pid: pid, uid: uid, startTimeMicroseconds: start, executablePath: path,
            displayName: name, bundleIdentifier: bundleID,
            canTerminate: uid == getuid() && pid != getpid() && allowlistedPath && !protected
        )
    }

    private static func verifiedProcess(_ expected: NativeProcessIdentity) async throws -> NativeProcessIdentity {
        let application: (String, String?)? = await MainActor.run {
            guard let app = NSRunningApplication(processIdentifier: expected.pid),
                  app.activationPolicy == .regular else { return nil }
            return (app.localizedName ?? "Application", app.bundleIdentifier)
        }
        guard expected.uid == getuid(), expected.pid > 1, expected.pid != getpid(),
              let application,
              let current = processIdentity(
                pid: expected.pid,
                name: application.0,
                bundleID: application.1
              ), current.canTerminate,
              current.startTimeMicroseconds == expected.startTimeMicroseconds,
              current.executablePath == expected.executablePath,
              current.displayName == expected.displayName,
              current.bundleIdentifier == expected.bundleIdentifier else {
            throw NativeCapabilityError.blocked("The process exited, changed identity, or is protected")
        }
        return current
    }

    private struct LaunchAgentDiscovery {
        let agents: [NativeLaunchAgent]
        let warning: String?
    }

    private static func userLaunchAgents() -> LaunchAgentDiscovery {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return LaunchAgentDiscovery(agents: [], warning: nil) }

        var candidates: [URL] = []
        var scanned = 0
        var truncated = false
        while let file = enumerator.nextObject() as? URL {
            scanned += 1
            if scanned > 500 { truncated = true; break }
            guard file.pathExtension == "plist" else { continue }
            if candidates.count >= 50 { truncated = true; break }
            candidates.append(file)
        }
        var agents = candidates.compactMap { file -> NativeLaunchAgent? in
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let data = try? boundedLaunchAgentData(file),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
                  let dictionary = plist as? [String: Any], let label = dictionary["Label"] as? String,
                  validLaunchLabel(label) else { return nil }
            return NativeLaunchAgent(label: label, plistPath: file.path, isLoaded: nil, issue: nil)
        }
        let duplicateLabels = Set(Dictionary(grouping: agents, by: \.label).compactMap { label, values in
            values.count > 1 ? label : nil
        })
        if !duplicateLabels.isEmpty {
            agents = agents.map { agent in
                guard duplicateLabels.contains(agent.label) else { return agent }
                return NativeLaunchAgent(
                    label: agent.label, plistPath: agent.plistPath, isLoaded: nil,
                    issue: "Duplicate Label appears in more than one owned plist"
                )
            }
        }
        agents.sort { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
        let warnings = [
            truncated ? "LaunchAgent discovery was limited to 50 plist candidates and 500 directory entries." : nil,
            duplicateLabels.isEmpty ? nil : "Duplicate LaunchAgent labels cannot be restarted until the duplicate plist is removed.",
        ].compactMap { $0 }
        return LaunchAgentDiscovery(agents: agents, warning: warnings.isEmpty ? nil : warnings.joined(separator: " "))
    }

    private static func boundedLaunchAgentData(_ url: URL) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_uid == getuid(),
              status.st_mode & S_IFMT == S_IFREG,
              status.st_size >= 0,
              status.st_size <= 1_048_576 else {
            throw NativeCapabilityError.blocked("LaunchAgent plist is not a bounded, owned regular file")
        }
        let data = try handle.read(upToCount: 1_048_577) ?? Data()
        guard data.count <= 1_048_576 else {
            throw NativeCapabilityError.blocked("LaunchAgent plist exceeds 1 MiB")
        }
        return data
    }

    private static func validLaunchLabel(_ label: String) -> Bool {
        label.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$"#, options: .regularExpression) != nil
    }
}

private extension CommandResult {
    var conciseError: String {
        let data = errorOutput.isEmpty ? output : errorOutput
        let decoded = String(decoding: data.prefix(2_048), as: UTF8.self)
        let printable = decoded.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? " " : String($0)
        }.joined()
        let text = printable.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.joined(separator: " ")
            .replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "$HOME")
        let summary = text.isEmpty ? "command exited with status \(exitCode)" : text
        return truncated ? summary + " [output truncated]" : summary
    }
}

private struct NativeCommandRunner: Sendable {
    private static let allowedExecutables: Set<String> = [
        "/bin/launchctl", "/usr/bin/ssh",
        "/opt/homebrew/bin/brew", "/usr/local/bin/brew",
    ]

    func run(
        executable: String,
        arguments: [String],
        environment additions: [String: String] = [:],
        timeout: TimeInterval
    ) async throws -> CommandResult {
        guard Self.allowedExecutables.contains(executable),
              FileManager.default.isExecutableFile(atPath: executable) else {
            throw NativeCapabilityError.blocked("Native executable is unavailable or not allowlisted")
        }
        var environment = ProcessInfo.processInfo.environment.filter {
            ["HOME", "USER", "TMPDIR", "LANG"].contains($0.key)
        }
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        additions.forEach { environment[$0.key] = $0.value }
        let subprocessEnvironment = Dictionary(uniqueKeysWithValues: environment.map {
            (Subprocess.Environment.Key(rawValue: $0.key)!, $0.value)
        })
        var platformOptions = PlatformOptions()
        platformOptions.createSession = true
        platformOptions.teardownSequence = [
            .gracefulShutDown(toProcessGroup: true, allowedDurationToNextStep: .seconds(2)),
        ]
        let configuration = Subprocess.Configuration(
            executable: .path(FilePath(executable)),
            arguments: Subprocess.Arguments(arguments),
            environment: .custom(subprocessEnvironment),
            workingDirectory: nil,
            platformOptions: platformOptions
        )
        let result = try await ProcessTransport.run(
            configuration: configuration,
            timeout: timeout,
            maximumOutputBytes: 64 * 1024
        )
        if result.timedOut {
            let partial = result.conciseError
            let detail = partial == "command exited with status -1" ? "" : ": \(partial)"
            throw NativeCapabilityError.timedOut("Native command timed out\(detail)")
        }
        return result
    }
}
