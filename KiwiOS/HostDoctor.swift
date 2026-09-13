import Foundation
import CoreGraphics
import ServiceManagement
import Security
import Darwin

/// Prompt-free checks for host prerequisites that KiwiOS itself depends on.
struct HostDoctor: Sendable {
    static let minimumAvailableCapacity: Int64 = 512 * 1024 * 1024

    func inspect(storageRoot: URL) async -> [DoctorFinding] {
        async let fileVault = Self.inspectFileVault(workingDirectory: storageRoot)
        async let launchAtLogin = inspectLaunchAtLogin()
        return [
            inspectAquaSession(),
            inspectStorage(storageRoot),
            inspectTools(),
            inspectSigning(),
            await fileVault,
            await launchAtLogin,
        ]
    }

    private func inspectAquaSession() -> DoctorFinding {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return DoctorFinding(
                id: "session",
                title: "Aqua session",
                status: .unknown,
                detail: "macOS did not expose the current GUI session; KiwiOS cannot claim remote availability"
            )
        }
        guard let loginComplete = session[kCGSessionLoginDoneKey as String] as? Bool,
              let sessionUID = (session[kCGSessionUserIDKey as String] as? NSNumber)?.uint32Value else {
            return DoctorFinding(
                id: "session",
                title: "Aqua session",
                status: .unknown,
                detail: "macOS returned incomplete GUI session metadata"
            )
        }
        guard loginComplete, sessionUID == getuid() else {
            return DoctorFinding(
                id: "session",
                title: "Aqua session",
                status: .blocked,
                detail: "The owning user's Aqua login session is not ready"
            )
        }
        let onConsole = session[kCGSessionOnConsoleKey as String] as? Bool
        return DoctorFinding(
            id: "session",
            title: "Aqua session",
            status: .passed,
            detail: onConsole == false
                ? "The owning Aqua session is logged in but is not the active console session"
                : "The owning Aqua session is logged in and available"
        )
    }

    private func inspectStorage(_ storageRoot: URL) -> DoctorFinding {
        do {
            let values = try storageRoot.resourceValues(forKeys: [
                .isDirectoryKey,
                .isReadableKey,
                .isWritableKey,
                .volumeIsReadOnlyKey,
                .volumeAvailableCapacityForImportantUsageKey,
            ])
            return Self.storageFinding(
                isDirectory: values.isDirectory,
                isReadable: values.isReadable,
                isWritable: values.isWritable,
                isReadOnly: values.volumeIsReadOnly,
                availableCapacity: values.volumeAvailableCapacityForImportantUsage
            )
        } catch {
            return DoctorFinding(
                id: "storage",
                title: "Persistent storage",
                status: .blocked,
                detail: "Cannot read KiwiOS storage metadata: \(error.localizedDescription)"
            )
        }
    }

    static func storageFinding(
        isDirectory: Bool?, isReadable: Bool?, isWritable: Bool?, isReadOnly: Bool?,
        availableCapacity: Int64?
    ) -> DoctorFinding {
        guard isDirectory == true, isReadable == true, isWritable == true, isReadOnly != true else {
            return DoctorFinding(
                id: "storage", title: "Persistent storage", status: .blocked,
                detail: "KiwiOS storage is not a readable and writable directory"
            )
        }
        guard let availableCapacity else {
            return DoctorFinding(
                id: "storage", title: "Persistent storage", status: .unknown,
                detail: "Storage is readable and writable, but macOS did not report available capacity"
            )
        }
        let capacity = ByteCountFormatter.string(fromByteCount: availableCapacity, countStyle: .file)
        guard availableCapacity >= minimumAvailableCapacity else {
            return DoctorFinding(
                id: "storage", title: "Persistent storage", status: .blocked,
                detail: "Only \(capacity) is available; free at least 512 MB before relying on KiwiOS"
            )
        }
        return DoctorFinding(
            id: "storage", title: "Persistent storage", status: .passed,
            detail: "Storage is readable and writable; \(capacity) available for important usage"
        )
    }

    private func inspectTools() -> DoctorFinding {
        let required = ["/bin/sh", "/usr/bin/fdesetup"]
        let missing = required.filter { !FileManager.default.isExecutableFile(atPath: $0) }
        return DoctorFinding(
            id: "host-tools",
            title: "Native tools",
            status: missing.isEmpty ? .passed : .blocked,
            detail: missing.isEmpty
                ? "Required macOS command-line tools are executable"
                : "Required tool unavailable: \(missing.joined(separator: ", "))"
        )
    }

    private func inspectSigning() -> DoctorFinding {
        guard let executable = Bundle.main.executableURL else {
            return Self.signingFinding(teamIdentifier: nil, inspectionSucceeded: false)
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(executable as CFURL, SecCSFlags(), &code) == errSecSuccess,
              let code else {
            return Self.signingFinding(teamIdentifier: nil, inspectionSucceeded: false)
        }
        var information: CFDictionary?
        let status = SecCodeCopySigningInformation(
            code, SecCSFlags(rawValue: kSecCSSigningInformation), &information
        )
        guard status == errSecSuccess, let values = information as? [String: Any] else {
            return Self.signingFinding(teamIdentifier: nil, inspectionSucceeded: false)
        }
        return Self.signingFinding(
            teamIdentifier: values[kSecCodeInfoTeamIdentifier as String] as? String,
            inspectionSucceeded: true
        )
    }

    static func signingFinding(teamIdentifier: String?, inspectionSucceeded: Bool) -> DoctorFinding {
        guard inspectionSucceeded else {
            return DoctorFinding(
                id: "app-signing", title: "App signing", status: .unknown,
                detail: "macOS could not inspect the KiwiOS signing identity"
            )
        }
        guard let teamIdentifier, !teamIdentifier.isEmpty else {
            return DoctorFinding(
                id: "app-signing", title: "App signing", status: .blocked,
                detail: "This build has no stable team identity. For development, relaunch with KIWIOS_DEVELOPMENT_TEAM so macOS can retain privacy approvals"
            )
        }
        return DoctorFinding(
            id: "app-signing", title: "App signing", status: .passed,
            detail: "KiwiOS has a stable signed identity for macOS privacy approvals"
        )
    }

    static func inspectFileVault(workingDirectory: URL) async -> DoctorFinding {
        do {
            let result = try await CommandRunner(timeout: 3).run(
                command: ["fdesetup", "status"],
                in: workingDirectory
            )
            guard !result.timedOut else {
                return fileVaultUnknown("The prompt-free FileVault status query timed out")
            }
            guard result.exitCode == 0 else {
                return fileVaultUnknown("macOS could not report FileVault status without interaction")
            }
            let status = String(decoding: result.output + result.errorOutput, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return fileVaultFinding(status)
        } catch {
            return fileVaultUnknown("Cannot query FileVault status: \(error.localizedDescription)")
        }
    }

    private static func fileVaultUnknown(_ detail: String) -> DoctorFinding {
        DoctorFinding(id: "filevault", title: "FileVault", status: .unknown, detail: detail)
    }

    static func fileVaultFinding(_ status: String) -> DoctorFinding {
        let normalized = status.lowercased()
        if normalized.contains("filevault is on") {
            return DoctorFinding(
                id: "filevault", title: "FileVault", status: .passed,
                detail: "FileVault is enabled; after a cold boot, remote service waits for the owning user to unlock the Mac"
            )
        }
        if normalized.contains("filevault is off") {
            return DoctorFinding(
                id: "filevault", title: "FileVault", status: .passed,
                detail: "FileVault is disabled; no pre-login disk unlock is required"
            )
        }
        return fileVaultUnknown(status.isEmpty
            ? "macOS returned an empty FileVault status"
            : "Unrecognized FileVault status: \(status)")
    }

    @MainActor
    private func inspectLaunchAtLogin() async -> DoctorFinding {
        let status = SMAppService.mainApp.status
        switch status {
        case .enabled:
            return DoctorFinding(
                id: "launch-at-login",
                title: "Launch at login",
                status: .passed,
                detail: "KiwiOS is registered to start when the owning user logs in"
            )
        case .notRegistered:
            return DoctorFinding(
                id: "launch-at-login",
                title: "Launch at login",
                status: .blocked,
                detail: "Enable launch at login before relying on unattended operation"
            )
        case .requiresApproval:
            return DoctorFinding(
                id: "launch-at-login",
                title: "Launch at login",
                status: .blocked,
                detail: "Launch at login requires approval in System Settings"
            )
        case .notFound:
            return DoctorFinding(
                id: "launch-at-login",
                title: "Launch at login",
                status: .unknown,
                detail: "macOS could not find the launch-at-login registration for this app"
            )
        @unknown default:
            return DoctorFinding(
                id: "launch-at-login",
                title: "Launch at login",
                status: .unknown,
                detail: "macOS returned an unrecognized launch-at-login state"
            )
        }
    }
}
