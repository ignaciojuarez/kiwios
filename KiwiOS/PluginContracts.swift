import Foundation

enum PluginLexicalValidator {
    static let maximumSafeInteger = 9_007_199_254_740_991.0

    static func pluginID(_ value: String) -> Bool {
        value.range(of: #"\A[a-z0-9]+(?:[.-][a-z0-9]+)*\z"#, options: .regularExpression) != nil
    }

    static func commitSHA(_ value: String) -> Bool {
        value.range(of: #"\A[0-9a-f]{40}\z"#, options: .regularExpression) != nil
    }

    static func relativePath(_ value: String, allowRoot: Bool) -> Bool {
        if allowRoot && value == "." { return true }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return !value.isEmpty && !value.hasPrefix("/") && !value.hasSuffix("/")
            && !value.hasPrefix("~") && !value.contains("\\")
            && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

struct PluginConfig: Decodable, Equatable, Sendable {
    let schema: String

    enum CodingKeys: String, CodingKey, CaseIterable { case schema }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        schema = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .schema)
    }
}

struct PluginPermissions: Decodable, Equatable, Sendable {
    let exec: [String]
    let readPaths: [String]
    let writePaths: [String]
    let network: [String]
    let sshPeers: [String]
    let secrets: [String]
    let tcc: [String]
    let notify: Bool

    enum CodingKeys: String, CodingKey, CaseIterable {
        case exec, network, secrets, tcc, notify
        case readPaths = "read_paths"
        case writePaths = "write_paths"
        case sshPeers = "ssh_peers"
    }

    init(
        exec: [String] = [], readPaths: [String] = [], writePaths: [String] = [],
        network: [String] = [], sshPeers: [String] = [], secrets: [String] = [],
        tcc: [String] = [], notify: Bool = false
    ) {
        self.exec = exec
        self.readPaths = readPaths
        self.writePaths = writePaths
        self.network = network
        self.sshPeers = sshPeers
        self.secrets = secrets
        self.tcc = tcc
        self.notify = notify
    }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        exec = try container.decodeIfPresent([String].self, forKey: .exec) ?? []
        readPaths = try container.decodeIfPresent([String].self, forKey: .readPaths) ?? []
        writePaths = try container.decodeIfPresent([String].self, forKey: .writePaths) ?? []
        network = try container.decodeIfPresent([String].self, forKey: .network) ?? []
        sshPeers = try container.decodeIfPresent([String].self, forKey: .sshPeers) ?? []
        secrets = try container.decodeIfPresent([String].self, forKey: .secrets) ?? []
        tcc = try container.decodeIfPresent([String].self, forKey: .tcc) ?? []
        notify = try container.decodeIfPresent(Bool.self, forKey: .notify) ?? false
    }

    func validate(pluginID: String? = nil) throws {
        // API 1 accepts only grants KiwiOS can verify without opening a macOS prompt.
        let tccValues = Set(["accessibility", "screen-recording"])
        try validateList(exec, field: "exec") { !$0.contains("/") && Self.isName($0) }
        try validateList(readPaths, field: "read_paths", validator: Self.isDisclosedPath)
        try validateList(writePaths, field: "write_paths", validator: Self.isDisclosedPath)
        try validateList(network, field: "network", validator: Self.isName)
        try validateList(sshPeers, field: "ssh_peers", validator: Self.isName)
        try validateList(secrets, field: "secrets", validator: Self.isName)
        if pluginID != nil, let reserved = secrets.first(where: {
            $0.range(of: #"^[a-z0-9]+(?:[.-][a-z0-9]+)*\.config\."#,
                options: .regularExpression) != nil
        }) {
            throw PluginLoadError.invalidPermission(field: "secrets", value: reserved)
        }
        try validateList(tcc, field: "tcc") { tccValues.contains($0) }
    }

    var disclosureLines: [String] {
        var lines: [String] = []
        let groups = [
            ("Execute", exec), ("Read", readPaths), ("Write", writePaths),
            ("Network", network), ("SSH peers", sshPeers), ("Secrets", secrets), ("macOS access", tcc),
        ]
        for (label, values) in groups where !values.isEmpty {
            lines.append("\(label): \(values.joined(separator: ", "))")
        }
        if notify { lines.append("Notifications") }
        return lines
    }

    private func validateList(
        _ values: [String], field: String, validator: (String) -> Bool
    ) throws {
        var seen = Set<String>()
        for value in values {
            guard validator(value) else { throw PluginLoadError.invalidPermission(field: field, value: value) }
            guard seen.insert(value).inserted else {
                throw PluginLoadError.duplicatePermission(field: field, value: value)
            }
        }
    }

    private static func isName(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:@-]*$"#, options: .regularExpression) != nil
    }

    private static func isDisclosedPath(_ value: String) -> Bool {
        guard value.hasPrefix("/") || value.hasPrefix("~/") else { return false }
        return !value.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }
}

struct SemanticVersion: Comparable, Equatable, Sendable {
    let major: String
    let minor: String
    let patch: String
    private let prerelease: [String]

    init?(_ value: String) {
        let pattern = #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              match.range == NSRange(value.startIndex..., in: value),
              let majorRange = Range(match.range(at: 1), in: value),
              let minorRange = Range(match.range(at: 2), in: value),
              let patchRange = Range(match.range(at: 3), in: value)
        else { return nil }
        let major = String(value[majorRange]), minor = String(value[minorRange]), patch = String(value[patchRange])
        var prerelease: [String] = []
        if match.range(at: 4).location != NSNotFound, let range = Range(match.range(at: 4), in: value) {
            prerelease = value[range].split(separator: ".").map(String.init)
            guard prerelease.allSatisfy({ !$0.allSatisfy(\.isNumber) || $0 == "0" || $0.first != "0" }) else {
                return nil
            }
        }
        self.major = major; self.minor = minor; self.patch = patch; self.prerelease = prerelease
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return numericLess(lhs.major, rhs.major) }
        if lhs.minor != rhs.minor { return numericLess(lhs.minor, rhs.minor) }
        if lhs.patch != rhs.patch { return numericLess(lhs.patch, rhs.patch) }
        if lhs.prerelease.isEmpty != rhs.prerelease.isEmpty { return !lhs.prerelease.isEmpty }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            let leftNumeric = left.allSatisfy(\.isNumber), rightNumeric = right.allSatisfy(\.isNumber)
            if leftNumeric && rightNumeric {
                return left.count == right.count ? left < right : left.count < right.count
            }
            if leftNumeric { return true }
            if rightNumeric { return false }
            return left < right
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    private static func numericLess(_ lhs: String, _ rhs: String) -> Bool {
        lhs.count == rhs.count ? lhs < rhs : lhs.count < rhs.count
    }
}

struct DependencyGraphValidator {
    static func validateDeclarations(_ manifest: PluginManifest) throws {
        for (id, requirement) in manifest.depends {
            guard id.range(of: #"^[a-z0-9]+(?:[.-][a-z0-9]+)*$"#, options: .regularExpression) != nil else {
                throw PluginLoadError.invalidDependency(id)
            }
            if id.hasPrefix("native.") {
                guard requirement.range(of: #"^(0|[1-9][0-9]*)$"#, options: .regularExpression) != nil else {
                    throw PluginLoadError.invalidDependency("\(id) = \(requirement)")
                }
            } else {
                let version = requirement.hasPrefix("^") ? String(requirement.dropFirst()) : requirement
                guard SemanticVersion(version) != nil else {
                    throw PluginLoadError.invalidDependency("\(id) = \(requirement)")
                }
            }
        }
    }

    static func issues(
        in plugins: [LoadedPlugin], nativeCapabilities: [String: Int]
    ) -> [String: [PluginDependencyIssue]] {
        let byID = Dictionary(uniqueKeysWithValues: plugins.map { ($0.manifest.id, $0) })
        var issues: [String: [PluginDependencyIssue]] = [:]
        for plugin in plugins.sorted(by: { $0.manifest.id < $1.manifest.id }) {
            for (dependency, requirement) in plugin.manifest.depends.sorted(by: { $0.key < $1.key }) {
                if dependency.hasPrefix("native.") {
                    guard let actual = nativeCapabilities[dependency] else {
                        issues[plugin.manifest.id, default: []].append(.missing(dependency))
                        continue
                    }
                    guard String(actual) == requirement else {
                        issues[plugin.manifest.id, default: []].append(
                            .incompatible(dependency: dependency, required: requirement, actual: String(actual))
                        )
                        continue
                    }
                } else {
                    guard let target = byID[dependency] else {
                        issues[plugin.manifest.id, default: []].append(.missing(dependency))
                        continue
                    }
                    guard isCompatible(target.manifest.version, with: requirement) else {
                        issues[plugin.manifest.id, default: []].append(
                            .incompatible(
                                dependency: dependency, required: requirement, actual: target.manifest.version
                            )
                        )
                        continue
                    }
                }
            }
        }
        var remaining = byID
        while let cycle = dependencyCycle(remaining) {
            for id in Set(cycle.dropLast()) { issues[id, default: []].append(.cycle(cycle)) }
            for id in cycle.dropLast() { remaining.removeValue(forKey: id) }
        }
        return issues
    }

    private static func isCompatible(_ actual: String, with requirement: String) -> Bool {
        guard let actualVersion = SemanticVersion(actual) else { return false }
        guard requirement.hasPrefix("^") else { return actual == requirement }
        guard let lower = SemanticVersion(String(requirement.dropFirst())) else { return false }
        guard actualVersion >= lower else { return false }
        if lower.major != "0" { return actualVersion.major == lower.major }
        if lower.minor != "0" { return actualVersion.major == "0" && actualVersion.minor == lower.minor }
        return actualVersion.major == "0" && actualVersion.minor == "0" && actualVersion.patch == lower.patch
    }

    private static func dependencyCycle(_ plugins: [String: LoadedPlugin]) -> [String]? {
        var visited = Set<String>(), stack: [String] = []
        func visit(_ id: String) -> [String]? {
            if let index = stack.firstIndex(of: id) {
                return Array(stack[index...]) + [id]
            }
            guard !visited.contains(id) else { return nil }
            stack.append(id)
            for dependency in plugins[id]!.manifest.depends.keys.sorted()
                where !dependency.hasPrefix("native.") && plugins[dependency] != nil {
                if let cycle = visit(dependency) { return cycle }
            }
            _ = stack.popLast(); visited.insert(id)
            return nil
        }
        for id in plugins.keys.sorted() {
            if let cycle = visit(id) { return cycle }
        }
        return nil
    }
}

enum PluginDependencyIssue: Equatable, Sendable {
    case missing(String)
    case incompatible(dependency: String, required: String, actual: String)
    case cycle([String])


}
