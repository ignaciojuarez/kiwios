import Foundation
import Subprocess
import System
import Darwin

struct PluginRepositoryIdentity: Hashable, Codable, Sendable {
    let url: URL
    let canonical: String

    init(_ value: String) throws {
        guard !value.contains("%"), var components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "github.com",
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil else {
            throw PluginInstallerError.invalidRepository
        }
        var parts = components.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 2, parts.allSatisfy({ Self.validGitHubName($0) }) else {
            throw PluginInstallerError.invalidRepository
        }
        if parts[1].hasSuffix(".git") { parts[1].removeLast(4) }
        guard !parts[1].isEmpty else { throw PluginInstallerError.invalidRepository }
        let identity = "https://github.com/\(parts[0].lowercased())/\(parts[1].lowercased())"
        components = URLComponents(string: identity)!
        guard let normalized = components.url else { throw PluginInstallerError.invalidRepository }
        url = normalized
        canonical = identity
    }

    private static func validGitHubName(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".."
            && value.unicodeScalars.allSatisfy {
                (48...57).contains($0.value) || (65...90).contains($0.value)
                    || (97...122).contains($0.value) || ".-_".unicodeScalars.contains($0)
            }
    }
}

enum PluginInstallerError: LocalizedError, Equatable {
    case invalidRepository
    case invalidCommit
    case invalidPluginPath
    case gitUnavailable
    case gitFailed(String)
    case gitOutputTooLarge
    case commitMismatch
    case unsupportedTreeEntry(String)
    case unsafeTreePath(String)
    case pathCollision(String)
    case treeTooLarge
    case lfsPlaceholder(String)
    case staleReview
    case snapshotConflict

    var errorDescription: String? {
        switch self {
        case .invalidRepository: "Use a GitHub HTTPS repository URL with only an owner and repository name"
        case .invalidCommit: "Commit must be a full 40-character hexadecimal Git SHA"
        case .invalidPluginPath: "Plugin path must stay inside the repository"
        case .gitUnavailable: "Git is unavailable at /usr/bin/git"
        case .gitFailed(let detail): "Git could not retrieve the requested commit: \(detail)"
        case .gitOutputTooLarge: "Git returned more data than the installer allows"
        case .commitMismatch: "The fetched object does not match the requested commit"
        case .unsupportedTreeEntry(let path): "Repository contains an unsupported entry: \(path)"
        case .unsafeTreePath(let path): "Repository contains an unsafe path: \(path)"
        case .pathCollision(let path): "Repository paths collide on macOS: \(path)"
        case .treeTooLarge: "Plugin source exceeds 4,096 files or 32 MiB"
        case .lfsPlaceholder(let path): "Git LFS content is unavailable for \(path)"
        case .staleReview: "The staged review is missing or changed; stage the plugin again"
        case .snapshotConflict: "An installed snapshot exists with different contents"
        }
    }
}

struct PermissionDisclosureDiff: Equatable, Sendable {
    let added: [String]
    let removed: [String]
}

struct InstallationReview: Identifiable, Sendable {
    let id: UUID
    let repository: String
    let commit: String
    let pluginPath: String
    let pluginID: String
    let name: String
    let version: String
    let license: String
    let dependencies: [String: String]
    let brew: [String]
    let permissions: [String]
    let permissionChanges: PermissionDisclosureDiff
    let manifestDigest: String
    let contentDigest: String
    /// A validated staging tree for source inspection. It must never be used to execute commands.
    let loadedPlugin: LoadedPlugin
}

struct InstalledPlugin: Sendable {
    let plugin: LoadedPlugin
    let repository: String
    let commit: String
    let manifestDigest: String
    let contentDigest: String
}

struct PluginUpdate: Equatable, Sendable {
    let commit: String
    let version: String
}

/// Fetches and inspects source only. Plugin commands are never run by this type.
actor PluginInstaller {
    typealias ConfigurationValidator = @Sendable (LoadedPlugin) async throws -> Void
    typealias ExistingPluginProvider = @Sendable (String) async throws -> LoadedPlugin?

    private struct TreeEntry: Sendable {
        let mode: Int
        let object: String
        let size: Int
        let path: String
    }

    private struct Staged: Sendable {
        let review: InstallationReview
        let temporaryRoot: URL
        let exportRoot: URL
        let plugin: LoadedPlugin
        var publishedDestination: URL?
        var createdPublishedDestination = false
    }

    private let installedRoot: URL
    private let loader: PluginLoader
    private let validateConfiguration: ConfigurationValidator?
    private let existingPlugin: ExistingPluginProvider?
    private var staged: [UUID: Staged] = [:]

    init(
        applicationSupportRoot: URL? = nil,
        loader: PluginLoader = PluginLoader(),
        validateConfiguration: ConfigurationValidator? = nil,
        existingPlugin: ExistingPluginProvider? = nil
    ) {
        let support = applicationSupportRoot ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("KiwiOS", isDirectory: true)
        installedRoot = support.appendingPathComponent("InstalledPlugins", isDirectory: true)
        self.loader = loader
        self.validateConfiguration = validateConfiguration
        self.existingPlugin = existingPlugin
    }

    deinit {
        for item in staged.values { try? FileManager.default.removeItem(at: item.temporaryRoot) }
    }

    func stage(repository: String, commit: String, pluginPath: String) async throws -> InstallationReview {
        let source = try PluginRepositoryIdentity(repository)
        let sha = commit.lowercased()
        guard sha.count == 40, sha.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef").contains($0) }) else {
            throw PluginInstallerError.invalidCommit
        }
        let path = try Self.normalizedPluginPath(pluginPath)
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("kiwios-install-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            let bare = temporaryRoot.appendingPathComponent("repository.git", isDirectory: true)
            let export = temporaryRoot.appendingPathComponent("source", isDirectory: true)
            try FileManager.default.createDirectory(at: export, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])

            _ = try await Self.git(["init", "--bare", "--template=", bare.path], in: temporaryRoot, outputLimit: 64 * 1024)
            _ = try await Self.git([
                "-C", bare.path, "-c", "core.hooksPath=/dev/null", "-c", "credential.helper=",
                "-c", "protocol.file.allow=never", "-c", "protocol.ext.allow=never",
                "-c", "fetch.fsckObjects=true", "-c", "submodule.recurse=false",
                "-c", "filter.lfs.required=false", "-c", "filter.lfs.smudge=",
                "fetch", "--no-tags", "--no-recurse-submodules",
                "--depth=1", source.canonical, sha,
            ], in: temporaryRoot, outputLimit: 64 * 1024, timeout: 60)
            let resolvedData = try await Self.git([
                "-C", bare.path, "rev-parse", "--verify", "FETCH_HEAD^{commit}",
            ], in: temporaryRoot, outputLimit: 256)
            guard String(decoding: resolvedData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == sha else {
                throw PluginInstallerError.commitMismatch
            }
            let listing = try await Self.git([
                "-C", bare.path, "ls-tree", "-rz", "-l", "--full-tree", sha,
            ], in: temporaryRoot, outputLimit: 2 * 1024 * 1024)
            let entries = try Self.parseTree(listing)
            var contents: [(TreeEntry, Data)] = []
            contents.reserveCapacity(entries.count)
            for entry in entries {
                try Task.checkCancellation()
                let bytes = try await Self.git([
                    "-C", bare.path, "cat-file", "blob", entry.object,
                ], in: temporaryRoot, outputLimit: entry.size)
                guard bytes.count == entry.size else { throw PluginInstallerError.treeTooLarge }
                if bytes.starts(with: Data("version https://git-lfs.github.com/spec/v1\n".utf8)) {
                    throw PluginInstallerError.lfsPlaceholder(entry.path)
                }
                contents.append((entry, bytes))
            }
            try Task.checkCancellation()
            for (entry, bytes) in contents {
                try Self.write(bytes, entry: entry, under: export)
            }

            let pluginRoot = path == "." ? export : export.appendingPathComponent(path, isDirectory: true)
            let loaded = try loader.load(from: pluginRoot)
            let stagedFingerprint = try PluginFingerprint.read(root: pluginRoot)
            let fingerprint = PluginFingerprint(source: source.canonical,
                manifestDigest: stagedFingerprint.manifestDigest,
                contentDigest: stagedFingerprint.contentDigest)
            let previous = try await existingPlugin?(loaded.manifest.id)
            let oldPermissions = Set(previous?.manifest.permissions.disclosureLines ?? [])
            let newPermissions = Set(loaded.manifest.permissions.disclosureLines)
            let review = InstallationReview(
                id: UUID(), repository: source.canonical, commit: sha, pluginPath: path,
                pluginID: loaded.manifest.id, name: loaded.manifest.name,
                version: loaded.manifest.version, license: loaded.manifest.license,
                dependencies: loaded.manifest.depends, brew: loaded.manifest.brew,
                permissions: newPermissions.sorted(),
                permissionChanges: PermissionDisclosureDiff(
                    added: newPermissions.subtracting(oldPermissions).sorted(),
                    removed: oldPermissions.subtracting(newPermissions).sorted()
                ),
                manifestDigest: fingerprint.manifestDigest, contentDigest: fingerprint.contentDigest,
                loadedPlugin: loaded
            )
            staged[review.id] = Staged(review: review, temporaryRoot: temporaryRoot,
                exportRoot: pluginRoot, plugin: loaded)
            return review
        } catch {
            try? FileManager.default.removeItem(at: temporaryRoot)
            throw error
        }
    }

    func availableUpdate(
        repository: String, currentCommit: String, pluginPath: String,
        pluginID: String, currentVersion: String
    ) async throws -> PluginUpdate? {
        let commit = try await latestCommit(repository: repository)
        guard commit != currentCommit.lowercased() else { return nil }
        let review = try await stage(repository: repository, commit: commit, pluginPath: pluginPath)
        defer { cancel(reviewID: review.id) }
        guard review.pluginID == pluginID,
              Self.isNewerVersion(review.version, than: currentVersion) else { return nil }
        return PluginUpdate(commit: commit, version: review.version)
    }

    func latestCommit(repository: String) async throws -> String {
        let source = try PluginRepositoryIdentity(repository)
        let output = try await Self.git(["ls-remote", "--exit-code", source.canonical, "HEAD"],
            in: FileManager.default.temporaryDirectory, outputLimit: 256, timeout: 15)
        return try Self.parseRemoteHead(output)
    }

    static func isNewerVersion(_ candidate: String, than current: String) -> Bool {
        guard let candidate = SemanticVersion(candidate), let current = SemanticVersion(current) else { return false }
        return candidate > current
    }

    static func parseRemoteHead(_ data: Data) throws -> String {
        let fields = String(decoding: data, as: UTF8.self).split(whereSeparator: \Character.isWhitespace)
        guard fields.count == 2, fields[1] == "HEAD" else {
            throw PluginInstallerError.gitFailed("invalid HEAD response")
        }
        let commit = fields[0].lowercased()
        guard commit.count == 40,
              commit.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef").contains($0) }) else {
            throw PluginInstallerError.gitFailed("invalid HEAD revision")
        }
        return commit
    }

    /// Call only after the user explicitly approves the corresponding review.
    func commit(reviewID: UUID) async throws -> InstalledPlugin {
        guard var item = staged[reviewID] else {
            throw PluginInstallerError.staleReview
        }
        let review = item.review
        let source = try PluginRepositoryIdentity(review.repository)

        let fresh = try loader.load(from: item.exportRoot)
        let fingerprint = try PluginFingerprint.read(root: item.exportRoot)
        guard fresh.manifest == item.plugin.manifest,
              fingerprint.manifestDigest == review.manifestDigest,
              fingerprint.contentDigest == review.contentDigest else {
            throw PluginInstallerError.staleReview
        }
        try await validateConfiguration?(fresh)

        let idRoot = installedRoot.appendingPathComponent(review.pluginID, isDirectory: true)
        let destination = idRoot.appendingPathComponent(review.commit, isDirectory: true)
        try FileManager.default.createDirectory(at: idRoot, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        if FileManager.default.fileExists(atPath: destination.path) {
            let existing = try PluginFingerprint.read(root: destination)
            guard existing.manifestDigest == review.manifestDigest,
                  existing.contentDigest == review.contentDigest else {
                throw PluginInstallerError.snapshotConflict
            }
        } else {
            let incoming = idRoot.appendingPathComponent(".incoming-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: incoming) }
            try Task.checkCancellation()
            try FileManager.default.copyItem(at: item.exportRoot, to: incoming)
            let copied = try PluginFingerprint.read(root: incoming)
            guard copied.manifestDigest == review.manifestDigest,
                  copied.contentDigest == review.contentDigest else { throw PluginInstallerError.staleReview }
            try Task.checkCancellation()
            guard Darwin.rename(incoming.path, destination.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            item.createdPublishedDestination = true
        }
        item.publishedDestination = destination
        staged[review.id] = item

        let installed = try loader.load(from: destination)
        return InstalledPlugin(plugin: installed, repository: source.canonical, commit: review.commit,
            manifestDigest: review.manifestDigest, contentDigest: review.contentDigest)
    }

    func cancel(reviewID: UUID) {
        guard let item = staged.removeValue(forKey: reviewID) else { return }
        if item.createdPublishedDestination, let destination = item.publishedDestination {
            try? FileManager.default.removeItem(at: destination)
        }
        try? FileManager.default.removeItem(at: item.temporaryRoot)
    }

    func complete(reviewID: UUID, activeCommit: String) throws {
        guard let item = staged.removeValue(forKey: reviewID) else { throw PluginInstallerError.staleReview }
        try? FileManager.default.removeItem(at: item.temporaryRoot)
        try pruneSnapshots(pluginID: item.review.pluginID, activeCommit: activeCommit)
    }

    func pruneSnapshots(pluginID: String, activeCommit: String) throws {
        guard PluginLexicalValidator.pluginID(pluginID),
              PluginLexicalValidator.commitSHA(activeCommit) else {
            throw PluginInstallerError.invalidCommit
        }
        let idRoot = installedRoot.appendingPathComponent(pluginID, isDirectory: true)
        guard FileManager.default.fileExists(atPath: idRoot.path) else { return }
        for child in try FileManager.default.contentsOfDirectory(at: idRoot,
            includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsSubdirectoryDescendants]) {
            if child.lastPathComponent != activeCommit { try FileManager.default.removeItem(at: child) }
        }
    }

    private static func normalizedPluginPath(_ value: String) throws -> String {
        if value == "." { return value }
        guard PluginLexicalValidator.relativePath(value, allowRoot: true) else {
            throw PluginInstallerError.invalidPluginPath
        }
        return value
    }

    private static func parseTree(_ data: Data) throws -> [TreeEntry] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw PluginInstallerError.unsafeTreePath("invalid UTF-8")
        }
        var entries: [TreeEntry] = []
        var total = 0
        var knownPaths: [String: String] = [:]
        var filePaths = Set<String>()
        for record in text.split(separator: "\0", omittingEmptySubsequences: true) {
            guard let tab = record.firstIndex(of: "\t") else {
                throw PluginInstallerError.unsupportedTreeEntry("invalid tree record")
            }
            let metadata = record[..<tab].split(separator: " ")
            let path = String(record[record.index(after: tab)...])
            guard metadata.count == 4, metadata[1] == "blob",
                  let mode = Int(metadata[0], radix: 8), [0o100644, 0o100755].contains(mode),
                  metadata[2].count == 40, let size = Int(metadata[3]), size >= 0 else {
                throw PluginInstallerError.unsupportedTreeEntry(path)
            }
            try validateTreePath(path, knownPaths: &knownPaths, filePaths: &filePaths)
            entries.append(TreeEntry(mode: mode, object: String(metadata[2]), size: size, path: path))
            guard knownPaths.count <= 4_096, size <= 32 * 1024 * 1024 - total else {
                throw PluginInstallerError.treeTooLarge
            }
            total += size
        }
        return entries
    }

    private static func validateTreePath(
        _ path: String, knownPaths: inout [String: String], filePaths: inout Set<String>
    ) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !path.hasPrefix("/"), !path.contains("\\"), !path.unicodeScalars.contains(where: {
            $0.value == 0 || CharacterSet.controlCharacters.contains($0)
        }), components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0 != ".git" }) else {
            throw PluginInstallerError.unsafeTreePath(path)
        }
        var prefix = ""
        for (offset, component) in components.enumerated() {
            prefix += (prefix.isEmpty ? "" : "/") + component
            let key = prefix.precomposedStringWithCanonicalMapping
                .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            if let known = knownPaths[key], known != prefix {
                throw PluginInstallerError.pathCollision(path)
            }
            if offset < components.count - 1, filePaths.contains(key) {
                throw PluginInstallerError.pathCollision(path)
            }
            if offset == components.count - 1 {
                guard knownPaths[key] == nil else { throw PluginInstallerError.pathCollision(path) }
                filePaths.insert(key)
            }
            knownPaths[key] = prefix
        }
    }

    private static func write(_ data: Data, entry: TreeEntry, under root: URL) throws {
        let destination = root.appendingPathComponent(entry.path)
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755])
        guard FileManager.default.createFile(atPath: destination.path, contents: data,
            attributes: [.posixPermissions: entry.mode == 0o100755 ? 0o755 : 0o644]) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private static func git(
        _ arguments: [String], in directory: URL, outputLimit: Int, timeout: TimeInterval = 30
    ) async throws -> Data {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else {
            throw PluginInstallerError.gitUnavailable
        }
        var environment: [Subprocess.Environment.Key: String] = [:]
        for (key, value) in [
            "PATH": "/usr/bin:/bin", "HOME": directory.path, "TMPDIR": directory.path,
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0", "GIT_ASKPASS": "/usr/bin/false",
            "GIT_SSH_COMMAND": "/usr/bin/false", "GIT_OPTIONAL_LOCKS": "0",
        ] { environment[Subprocess.Environment.Key(rawValue: key)!] = value }
        var options = PlatformOptions()
        options.createSession = true
        options.teardownSequence = [.gracefulShutDown(toProcessGroup: true, allowedDurationToNextStep: .seconds(2))]
        let configuration = Subprocess.Configuration(
            executable: .path(FilePath("/usr/bin/git")), arguments: Subprocess.Arguments(arguments),
            environment: .custom(environment), workingDirectory: FilePath(directory.path), platformOptions: options
        )
        let result: CommandResult
        do {
            result = try await ProcessTransport.run(configuration: configuration, timeout: timeout,
                maximumOutputBytes: outputLimit, maximumErrorBytes: 64 * 1_024,
                failOnOutputOverflow: true)
        } catch ProcessTransportError.outputLimitExceeded { throw PluginInstallerError.gitOutputTooLarge }
        guard !result.timedOut else { throw PluginInstallerError.gitFailed("operation timed out") }
        guard result.exitCode == 0 else {
            let detail = String(decoding: result.errorOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw PluginInstallerError.gitFailed(detail.isEmpty ? "exit status \(result.exitCode)" : detail)
        }
        return result.output
    }
}
