import Foundation

enum PluginSource: String, Equatable, Sendable {
    case bundled
    case development
    case direct
    case installed
}

struct PluginDiscoveryResult: Sendable {
    let plugins: [LoadedPlugin]
    let dependencyIssues: [String: [PluginDependencyIssue]]
    let failures: [PluginDiscoveryFailure]
}

struct PluginDiscoveryFailure: Equatable, Sendable {
    let path: String
    let pluginID: String?
    let message: String
}

struct PluginDiscovery {
    let loader: PluginLoader

    init(loader: PluginLoader = PluginLoader()) {
        self.loader = loader
    }

    func discover(
        bundledPluginRoots: [URL],
        developmentDirectory: URL? = nil,
        installedPluginRoots: [URL] = [],
        nativeCapabilities: [String: Int] = [:]
    ) throws -> PluginDiscoveryResult {
        var candidates: [(url: URL, source: PluginSource)] = []
        var failures: [PluginDiscoveryFailure] = []
        for root in bundledPluginRoots {
            do { candidates += try pluginRoots(in: root).map { ($0, .bundled) } }
            catch { failures.append(.init(path: root.path, pluginID: nil,
                message: error.localizedDescription)) }
        }
        candidates += installedPluginRoots.map { ($0, .installed) }
        if let developmentDirectory {
            do { candidates += try pluginRoots(in: developmentDirectory).map { ($0, .development) } }
            catch { failures.append(.init(path: developmentDirectory.path,
                pluginID: nil, message: error.localizedDescription)) }
        }

        var canonicalSources: [String: PluginSource] = [:]
        var loadedByID: [String: LoadedPlugin] = [:]
        var sourcePathByID: [String: String] = [:]
        var pluginIDByCanonicalPath: [String: String] = [:]
        var invalidIDs = Set<String>()
        for candidate in candidates.sorted(by: { $0.url.path < $1.url.path }) {
            let canonical = candidate.url.standardizedFileURL.resolvingSymlinksInPath().path
            if canonicalSources.updateValue(candidate.source, forKey: canonical) != nil {
                if let id = pluginIDByCanonicalPath[canonical] {
                    loadedByID.removeValue(forKey: id)
                    sourcePathByID.removeValue(forKey: id)
                    invalidIDs.insert(id)
                }
                failures.append(.init(path: canonical, pluginID: nil,
                    message: PluginLoadError.sourceConflict(canonical).localizedDescription))
                failures.append(.init(path: canonical, pluginID: nil,
                    message: PluginLoadError.sourceConflict(canonical).localizedDescription))
                continue
            }
            do {
                let raw = try loader.load(from: candidate.url)
                if candidate.source == .installed,
                   candidate.url.deletingLastPathComponent().lastPathComponent != raw.manifest.id {
                    throw PluginLoadError.sourceConflict(raw.manifest.id)
                }
                let loaded = LoadedPlugin(manifest: raw.manifest, rootURL: raw.rootURL,
                    configSchema: raw.configSchema, source: candidate.source)
                let id = loaded.manifest.id
                if invalidIDs.contains(id) {
                    failures.append(.init(path: canonical, pluginID: id,
                        message: PluginLoadError.duplicatePluginID(id).localizedDescription))
                    continue
                }
                if let existing = loadedByID.removeValue(forKey: id) {
                    invalidIDs.insert(id)
                    let error: PluginLoadError = existing.source == loaded.source
                        ? .duplicatePluginID(id) : .sourceConflict(id)
                    failures.append(.init(path: sourcePathByID.removeValue(forKey: id) ?? existing.rootURL.path,
                        pluginID: id, message: error.localizedDescription))
                    failures.append(.init(path: canonical, pluginID: id,
                        message: error.localizedDescription))
                    continue
                }
                loadedByID[id] = loaded
                sourcePathByID[id] = canonical
                pluginIDByCanonicalPath[canonical] = id
            } catch {
                failures.append(.init(path: canonical, pluginID: nil,
                    message: error.localizedDescription))
            }
        }
        let plugins = loadedByID.values.sorted(by: { $0.manifest.id < $1.manifest.id })
        return PluginDiscoveryResult(
            plugins: plugins,
            dependencyIssues: DependencyGraphValidator.issues(
                in: plugins, nativeCapabilities: nativeCapabilities
            ),
            failures: failures.sorted { ($0.path, $0.message) < ($1.path, $1.message) }
        )
    }

    private func pluginRoots(in selectedURL: URL) throws -> [URL] {
        let selected = selectedURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: selected.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw CocoaError(.fileNoSuchFile)
        }
        if FileManager.default.fileExists(atPath: selected.appendingPathComponent("plugin.toml").path) {
            return [selected]
        }
        let children = try FileManager.default.contentsOfDirectory(
            at: selected,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return children.filter { child in
            var childIsDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: child.path, isDirectory: &childIsDirectory)
                && childIsDirectory.boolValue
                && FileManager.default.fileExists(atPath: child.appendingPathComponent("plugin.toml").path)
        }.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
    }
}
