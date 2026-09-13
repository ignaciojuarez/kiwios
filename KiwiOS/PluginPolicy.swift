import Foundation
import CryptoKit
import Security
import LocalAuthentication
import ApplicationServices
import CoreGraphics
import Darwin

enum OperationMode: String, Codable, CaseIterable, Equatable, Sendable {
    case setup, remote
}

enum PluginLifecycle: String, Equatable, Sendable {
    case installed, needsSetup = "needs-setup", active, disabled
    case removing, missingDependency = "missing-dependency", error
}

enum PolicyError: LocalizedError {
    case blocked(String)
    var errorDescription: String? {
        switch self { case .blocked(let reason): reason }
    }
}

/// Content approval is tamper detection, not isolation from trusted same-user code.
struct PluginFingerprint: Equatable, Sendable {
    private static let maximumFiles = 4_096
    private static let maximumBytes = 32 * 1024 * 1024
    let source: String
    let manifestDigest: String
    let contentDigest: String

    static func read(root: URL) throws -> Self {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let manager = FileManager.default
        var enumerationError: Error?
        guard let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
            ],
            options: [],
            errorHandler: { _, error in enumerationError = error; return false }
        ) else { throw PolicyError.blocked("Cannot inspect plugin source") }
        var files: [(String, Data, Int)] = []
        guard let rootModificationDate = try root.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate else { throw PolicyError.blocked("Cannot inspect plugin source metadata") }
        var directories: [(URL, Date)] = [(root, rootModificationDate)]
        var total = 0
        var entryCount = 0
        for case let file as URL in enumerator {
            entryCount += 1
            guard entryCount <= maximumFiles else { throw PolicyError.blocked("Plugin exceeds 4,096 files") }
            let values = try file.resourceValues(forKeys: [
                .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
            ])
            // An approved tree has no mutable link indirection between hashing and launch.
            guard values.isSymbolicLink != true else {
                throw PolicyError.blocked("Approval requires regular files; replace the symbolic link \(file.lastPathComponent)")
            }
            if values.isDirectory == true {
                guard let modificationDate = values.contentModificationDate else {
                    throw PolicyError.blocked("Cannot inspect plugin source metadata")
                }
                directories.append((file, modificationDate))
                continue
            }
            guard values.isRegularFile == true, let declaredSize = values.fileSize,
                  declaredSize >= 0, declaredSize <= maximumBytes - total else {
                throw PolicyError.blocked("Plugin contains an unsupported or oversized file")
            }
            let (bytes, mode) = try readBounded(file, limit: maximumBytes - total)
            guard bytes.count == declaredSize else {
                throw PolicyError.blocked("Plugin changed while its contents were being reviewed")
            }
            total += bytes.count
            // Foundation enumeration can return /private/var while resolving the same
            // directory produces /var. Compare paths in one canonical representation.
            let canonicalPath = file.standardizedFileURL.resolvingSymlinksInPath().path
            let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
            guard canonicalPath.hasPrefix(prefix) else {
                throw PolicyError.blocked("Plugin source changed while its contents were being reviewed")
            }
            let relative = String(canonicalPath.dropFirst(prefix.count))
            files.append((relative, bytes, mode))
        }
        if let enumerationError { throw enumerationError }
        for (directory, modificationDate) in directories {
            guard try directory.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                    == modificationDate else {
                throw PolicyError.blocked("Plugin changed while its contents were being reviewed")
            }
        }
        var digest = SHA256()
        for (path, bytes, mode) in files.sorted(by: { $0.0 < $1.0 }) {
            digest.update(data: Data("\(path.utf8.count):\(path):\(mode):\(bytes.count):".utf8))
            digest.update(data: bytes)
        }
        guard let manifest = files.first(where: { $0.0 == "plugin.toml" })?.1 else {
            throw PolicyError.blocked("Plugin manifest disappeared while its contents were being reviewed")
        }
        return Self(source: root.path, manifestDigest: hex(SHA256.hash(data: manifest)), contentDigest: hex(digest.finalize()))
    }

    private static func readBounded(_ url: URL, limit: Int) throws -> (Data, Int) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var before = stat(), after = stat()
        guard Darwin.fstat(handle.fileDescriptor, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_size >= 0, before.st_size <= off_t(limit) else {
            throw PolicyError.blocked("Plugin contains an unsupported or oversized file")
        }
        var result = Data()
        while true {
            let remaining = limit - result.count
            guard remaining >= 0 else { throw PolicyError.blocked("Plugin exceeds 32 MiB") }
            let chunk = try handle.read(upToCount: min(64 * 1024, remaining + 1)) ?? Data()
            if chunk.isEmpty { break }
            result.append(chunk)
            guard result.count <= limit else { throw PolicyError.blocked("Plugin exceeds 32 MiB") }
        }
        guard Darwin.fstat(handle.fileDescriptor, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw PolicyError.blocked("Plugin changed while its contents were being reviewed")
        }
        return (result, Int(before.st_mode & 0o7777))
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// All reads explicitly prohibit authentication UI, including in attended mode.
struct SecretStore: Sendable {
    private let service = "app.kiwios.plugin-secrets"

    private static func noninteractiveContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }

    func read(_ name: String) throws -> String {
        var query = base(name)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = Self.noninteractiveContext()
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw PolicyError.blocked("Secret \(name) is unavailable without a Keychain prompt (\(status)); complete attended setup")
        }
        return value
    }

    func readIfPresent(_ name: String) throws -> String? {
        var query = base(name)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = Self.noninteractiveContext()
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw PolicyError.blocked("Secret \(name) is unavailable without a Keychain prompt (\(status)); complete attended setup")
        }
        return value
    }

    func write(_ value: String, named name: String, mode: OperationMode) throws {
        guard mode == .setup else { throw PolicyError.blocked("Secret changes require attended setup mode") }
        var query = base(name)
        query[kSecUseAuthenticationContext as String] = Self.noninteractiveContext()
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = base(name)
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            insert[kSecUseAuthenticationContext as String] = Self.noninteractiveContext()
            let added = SecItemAdd(insert as CFDictionary, nil)
            guard added == errSecSuccess else { throw PolicyError.blocked("Cannot save Keychain secret (\(added))") }
        } else if status != errSecSuccess {
            throw PolicyError.blocked("Cannot update Keychain secret without a prompt (\(status))")
        }
    }

    func delete(_ name: String, mode: OperationMode) throws {
        guard mode == .setup else { throw PolicyError.blocked("Secret changes require attended setup mode") }
        var query = base(name)
        query[kSecUseAuthenticationContext as String] = Self.noninteractiveContext()
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PolicyError.blocked("Cannot delete Keychain secret without a prompt (\(status))")
        }
    }

    /// The `<plugin-id>.config.` account prefix is reserved for schema-owned write-only fields.
    /// Enumerating it lets uninstall remove credentials created before ownership rows existed,
    /// even when the installed manifest has become unreadable.
    func deleteConfigSecrets(pluginID: String, knownPluginIDs: Set<String>, mode: OperationMode) throws {
        guard mode == .setup else { throw PolicyError.blocked("Secret changes require attended setup mode") }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecUseAuthenticationContext as String: Self.noninteractiveContext(),
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return }
        guard status == errSecSuccess else {
            throw PolicyError.blocked("Cannot enumerate plugin Keychain secrets without a prompt (\(status))")
        }
        let rows: [[String: Any]]
        if let values = result as? [[String: Any]] { rows = values }
        else if let value = result as? [String: Any] { rows = [value] }
        else { throw PolicyError.blocked("Keychain returned invalid secret metadata") }
        let owners = knownPluginIDs.union([pluginID])
        for name in rows.compactMap({ $0[kSecAttrAccount as String] as? String })
            where name.contains(".config.") {
            let owner = owners.filter { name.hasPrefix("\($0).config.") }
                .max { $0.count < $1.count }
            if owner == pluginID { try delete(name, mode: mode) }
        }
    }

    private func base(_ name: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: name]
    }
}

struct DoctorFinding: Identifiable, Sendable {
    enum Status: String, Equatable, Sendable { case passed, blocked, unknown }
    let id: String
    let title: String
    let status: Status
    let detail: String
}

enum DoctorReadiness {
    static let requiredHostIDs: Set<String> = [
        "session", "storage", "host-tools", "app-signing", "database", "launch-at-login",
    ]

    static func hostIsReady(
        _ findings: [DoctorFinding], excluding excludedIDs: Set<String> = []
    ) -> Bool {
        let required = requiredHostIDs.subtracting(excludedIDs)
        let passed = Set(findings.filter { $0.status == .passed }.map(\.id))
        return required.isSubset(of: passed)
    }
}

struct PluginDoctor: Sendable {
    func inspect(_ manifest: PluginManifest) -> [DoctorFinding] {
        let access = manifest.permissions.tcc.map { grant in
            switch grant {
            case "accessibility":
                let available = AXIsProcessTrusted()
                return DoctorFinding(id: grant, title: "Accessibility", status: available ? .passed : .blocked,
                    detail: available ? "KiwiOS has Accessibility access" : "Grant KiwiOS access in System Settings → Privacy & Security → Accessibility")
            case "screen-recording":
                let available = CGPreflightScreenCaptureAccess()
                return DoctorFinding(id: grant, title: "Screen Recording", status: available ? .passed : .blocked,
                    detail: available ? "Screen Recording preflight passed" : "Grant access in System Settings → Privacy & Security → Screen Recording")
            default:
                return DoctorFinding(id: grant, title: grant, status: .unknown,
                    detail: "No reliable prompt-free probe is available for this declaration; execution remains blocked")
            }
        }
        return access + manifest.brew.map { formula in
            let installed = BrewFormulaStatus.isInstalled(formula)
            return DoctorFinding(
                id: "brew-\(formula)", title: "Homebrew formula \(formula)",
                status: installed ? .passed : .blocked,
                detail: installed ? "\(formula) is installed" : "Install the required package from Plugins"
            )
        }
    }
}

enum BrewFormulaStatus {
    struct Installation: Equatable, Sendable {
        let executable: String
        let cellar: URL

        static func selected(fileManager: FileManager = .default) -> Self? {
            for (executable, cellar) in [
                ("/opt/homebrew/bin/brew", "/opt/homebrew/Cellar"),
                ("/usr/local/bin/brew", "/usr/local/Cellar"),
            ] where fileManager.isExecutableFile(atPath: executable) {
                return Self(executable: executable, cellar: URL(fileURLWithPath: cellar, isDirectory: true))
            }
            return nil
        }

        func isInstalled(_ formula: String) -> Bool {
            Self.receipts(formula, cellar: cellar).isEmpty == false
        }

        func receiptIdentity(_ formula: String) -> String? {
            let receipts = Self.receipts(formula, cellar: cellar)
            guard !receipts.isEmpty else { return nil }
            var digest = SHA256()
            for receipt in receipts {
                guard let values = try? receipt.resourceValues(forKeys: [.fileSizeKey]),
                      let size = values.fileSize, size <= 1_048_576,
                      let data = try? Data(contentsOf: receipt, options: [.mappedIfSafe]) else { return nil }
                digest.update(data: Data(receipt.deletingLastPathComponent().lastPathComponent.utf8))
                digest.update(data: data)
            }
            return digest.finalize().map { String(format: "%02x", $0) }.joined()
        }

        private static func receipts(_ formula: String, cellar: URL) -> [URL] {
            let folder = cellar.appendingPathComponent(formula, isDirectory: true)
            let versions = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            )
            return (versions ?? []).map { $0.appendingPathComponent("INSTALL_RECEIPT.json") }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
                .sorted { $0.path < $1.path }
        }
    }

    static func isInstalled(_ formula: String) -> Bool {
        Installation.selected()?.isInstalled(formula) == true
    }

    static func receiptIdentity(_ formula: String) -> String? {
        Installation.selected()?.receiptIdentity(formula)
    }

}

struct ActionConfirmation: Identifiable, Sendable {
    let id: UUID
    let pluginID: String
    let actionID: String
    let label: String
    let digest: String
    let expiresAt: Date
}

struct PluginReview: Identifiable, Sendable {
    var id: String { pluginID }
    let pluginID: String
    let name: String
    let version: String
    let license: String
    let fingerprint: PluginFingerprint
    let disclosures: [String]
}
