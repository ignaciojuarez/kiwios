import Foundation
import TOMLDecoder

struct PluginManifest: Decodable, Equatable, Sendable {
    let id: String
    let name: String
    let description: String?
    let version: String
    let kiwiosAPI: String
    let license: String
    let checks: [PluginCheck]
    let actions: [PluginAction]
    let ui: PluginUI
    let depends: [String: String]
    let brew: [String]
    let permissions: PluginPermissions
    let config: PluginConfig?
    let watch: PluginWatch?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, name, description, version, license, checks, actions, ui, depends, brew, permissions, config, watch
        case kiwiosAPI = "kiwios_api"
    }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        version = try container.decode(String.self, forKey: .version)
        kiwiosAPI = try container.decode(String.self, forKey: .kiwiosAPI)
        license = try container.decode(String.self, forKey: .license)
        checks = try container.decodeIfPresent([PluginCheck].self, forKey: .checks) ?? []
        actions = try container.decodeIfPresent([PluginAction].self, forKey: .actions) ?? []
        ui = try container.decodeIfPresent(PluginUI.self, forKey: .ui) ?? PluginUI()
        depends = try container.decodeIfPresent([String: String].self, forKey: .depends) ?? [:]
        brew = try container.decodeIfPresent([String].self, forKey: .brew) ?? []
        permissions = try container.decodeIfPresent(PluginPermissions.self, forKey: .permissions) ?? PluginPermissions()
        config = try container.decodeIfPresent(PluginConfig.self, forKey: .config)
        watch = try container.decodeIfPresent(PluginWatch.self, forKey: .watch)
    }
}

struct PluginWatch: Decodable, Equatable, Sendable {
    let status: String
    let start: String?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case status, start
    }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(String.self, forKey: .status)
        start = try container.decodeIfPresent(String.self, forKey: .start)
    }
}

struct PluginCheck: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let label: String
    let command: [String]
    let every: PluginDuration?
    let timeout: PluginDuration?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, label, command, every, timeout
    }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        command = try container.decode([String].self, forKey: .command)
        every = try container.decodeIfPresent(PluginDuration.self, forKey: .every)
        timeout = try container.decodeIfPresent(PluginDuration.self, forKey: .timeout)
    }
}

struct PluginAction: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let label: String
    let confirm: Bool
    let command: [String]
    let timeout: PluginDuration?
    let lock: String?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, label, confirm, command, timeout, lock
    }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        confirm = try container.decode(Bool.self, forKey: .confirm)
        command = try container.decode([String].self, forKey: .command)
        timeout = try container.decodeIfPresent(PluginDuration.self, forKey: .timeout)
        lock = try container.decodeIfPresent(String.self, forKey: .lock)
    }
}

struct PluginDuration: Decodable, Equatable, Sendable {
    let rawValue: String
    let seconds: TimeInterval

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let seconds = Self.parse(value) else {
            throw PluginLoadError.invalidDuration(value)
        }
        rawValue = value
        self.seconds = seconds
    }

    private static func parse(_ value: String) -> TimeInterval? {
        let units: [(suffix: String, nanoseconds: Int64)] = [
            ("ms", 1_000_000), ("s", 1_000_000_000),
            ("m", 60_000_000_000), ("h", 3_600_000_000_000),
        ]
        guard let unit = units.first(where: { value.hasSuffix($0.suffix) }) else { return nil }
        let digits = value.dropLast(unit.suffix.count)
        guard !digits.isEmpty,
              digits.allSatisfy(\.isNumber),
              let amount = Int64(digits),
              amount > 0 else { return nil }
        let product = amount.multipliedReportingOverflow(by: unit.nanoseconds)
        guard !product.overflow else { return nil }
        return Double(product.partialValue) / 1_000_000_000
    }
}

struct PluginUI: Decodable, Equatable, Sendable {
    let pages: [PluginPage]
    let sidebar: [PluginSidebarItem]
    let widgets: [PluginWidget]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case pages, sidebar, widgets
    }

    init(pages: [PluginPage] = [], sidebar: [PluginSidebarItem] = [], widgets: [PluginWidget] = []) {
        self.pages = pages
        self.sidebar = sidebar
        self.widgets = widgets
    }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pages = try container.decodeIfPresent([PluginPage].self, forKey: .pages) ?? []
        sidebar = try container.decodeIfPresent([PluginSidebarItem].self, forKey: .sidebar) ?? []
        widgets = try container.decodeIfPresent([PluginWidget].self, forKey: .widgets) ?? []
    }
}

struct PluginPage: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let kind: PluginUIKind
    let source: String

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, title, kind, source
    }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        kind = try container.decode(PluginUIKind.self, forKey: .kind)
        source = try container.decode(String.self, forKey: .source)
    }
}

struct PluginSidebarItem: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let label: String
    let page: String

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, label, page
    }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        page = try container.decode(String.self, forKey: .page)
    }
}

struct PluginWidget: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let kind: PluginUIKind
    let source: String
    let size: String

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, title, kind, source, size
    }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        kind = try container.decode(PluginUIKind.self, forKey: .kind)
        source = try container.decode(String.self, forKey: .source)
        size = try container.decode(String.self, forKey: .size)
    }
}

enum PluginUIKind: String, Equatable, Sendable {
    case stat, checks, actions, table, log, form, watchers
}

extension PluginUIKind: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let kind = Self(rawValue: value) else { throw PluginLoadError.invalidUIKind(value) }
        self = kind
    }
}

struct LoadedPlugin: Sendable {
    let manifest: PluginManifest
    let rootURL: URL
    let configSchema: PluginConfigSchema?
    let source: PluginSource

    init(
        manifest: PluginManifest,
        rootURL: URL,
        configSchema: PluginConfigSchema? = nil,
        source: PluginSource = .direct
    ) {
        self.manifest = manifest
        self.rootURL = rootURL
        self.configSchema = configSchema
        self.source = source
    }
}

enum PluginLoadError: LocalizedError, Equatable {
    case manifestTooLarge
    case unsupportedAPI(String)
    case unknownField(String)
    case invalidID(String)
    case invalidVersion(String)
    case emptyField(String)
    case invalidContributionID(String)
    case duplicateCommandID(String)
    case duplicateDescriptorID(String)
    case emptyCommand(String)
    case invalidCommandArgument(String)
    case invalidCommandPath(String)
    case executableMissingOrNotExecutable(String)
    case invalidDuration(String)
    case invalidLock(String)
    case invalidUIKind(String)
    case invalidSource(String)
    case invalidPageReference(String)
    case invalidWidgetSize(String)
    case invalidWatchReference(String)
    case invalidDependency(String)
    case missingDependency(plugin: String, dependency: String)
    case incompatibleDependency(plugin: String, dependency: String, required: String, actual: String)
    case dependencyCycle([String])
    case invalidPermission(field: String, value: String)
    case duplicatePermission(field: String, value: String)
    case invalidConfigPath(String)
    case configSchemaMissing(String)
    case configSchemaTooLarge
    case invalidConfigSchema(String)
    case duplicatePluginID(String)
    case sourceConflict(String)

    var errorDescription: String? {
        switch self {
        case .manifestTooLarge: "plugin.toml exceeds 256 KB"
        case .unsupportedAPI(let version): "Unsupported kiwios_api \(version)"
        case .unknownField(let field): "Unknown manifest field \(field)"
        case .invalidID(let id): "Invalid plugin id \(id)"
        case .invalidVersion(let version): "Invalid plugin version \(version)"
        case .emptyField(let field): "Manifest field \(field) cannot be blank"
        case .invalidContributionID(let id): "Invalid contribution id \(id)"
        case .duplicateCommandID(let id): "Duplicate command id \(id)"
        case .duplicateDescriptorID(let id): "Duplicate UI descriptor id \(id)"
        case .emptyCommand(let id): "Command \(id) has no argv"
        case .invalidCommandArgument(let id): "Command \(id) contains an invalid control character"
        case .invalidCommandPath(let id): "Command \(id) must be a bare executable or a ./ path inside the plugin"
        case .executableMissingOrNotExecutable(let id): "Command \(id) references a missing or non-executable local file"
        case .invalidDuration(let value): "Invalid duration \(value)"
        case .invalidLock(let value): "Invalid action lock \(value)"
        case .invalidUIKind(let value): "Invalid UI kind \(value)"
        case .invalidSource(let value): "Invalid UI source \(value)"
        case .invalidPageReference(let value): "Unknown UI page \(value)"
        case .invalidWidgetSize(let value): "Invalid widget size \(value)"
        case .invalidWatchReference(let value): "Invalid watch reference \(value)"
        case .invalidDependency(let value): "Invalid dependency declaration \(value)"
        case .missingDependency(let plugin, let dependency): "Plugin \(plugin) is missing dependency \(dependency)"
        case .incompatibleDependency(let plugin, let dependency, let required, let actual):
            "Plugin \(plugin) requires \(dependency) \(required), found \(actual)"
        case .dependencyCycle(let ids): "Plugin dependency cycle: \(ids.joined(separator: " -> "))"
        case .invalidPermission(let field, let value): "Invalid permission \(field): \(value)"
        case .duplicatePermission(let field, let value): "Duplicate permission \(field): \(value)"
        case .invalidConfigPath(let value): "Invalid config schema path \(value)"
        case .configSchemaMissing(let value): "Config schema is missing: \(value)"
        case .configSchemaTooLarge: "Config schema exceeds 256 KB"
        case .invalidConfigSchema(let reason): "Invalid config schema: \(reason)"
        case .duplicatePluginID(let id): "Duplicate plugin id \(id)"
        case .sourceConflict(let path): "Plugin source is selected more than once: \(path)"
        }
    }
}

struct PluginLoader {
    static let maximumManifestBytes = 256 * 1024
    private static let contributionIDPattern = #"^[a-z0-9]+(?:-[a-z0-9]+)*$"#

    func load(from rootURL: URL) throws -> LoadedPlugin {
        let data = try Data(contentsOf: rootURL.appendingPathComponent("plugin.toml"), options: .mappedIfSafe)
        guard data.count <= Self.maximumManifestBytes else { throw PluginLoadError.manifestTooLarge }

        let manifest = try TOMLDecoder(isLenient: false).decode(PluginManifest.self, from: data)
        guard manifest.kiwiosAPI == "1" else { throw PluginLoadError.unsupportedAPI(manifest.kiwiosAPI) }
        guard Self.matches(manifest.id, #"^[a-z0-9]+(?:[.-][a-z0-9]+)*$"#) else {
            throw PluginLoadError.invalidID(manifest.id)
        }
        guard Self.isSemanticVersion(manifest.version) else {
            throw PluginLoadError.invalidVersion(manifest.version)
        }
        try validateDisplayText(manifest)
        try DependencyGraphValidator.validateDeclarations(manifest)
        try validateBrewPackages(manifest.brew)
        try manifest.permissions.validate(pluginID: manifest.id)

        try validateCommands(manifest.checks.map { ($0.id, $0.command) }, rootURL: rootURL)
        try validateCommands(manifest.actions.map { ($0.id, $0.command) }, rootURL: rootURL)
        for action in manifest.actions {
            if let lock = action.lock, !Self.matches(lock, Self.contributionIDPattern) {
                throw PluginLoadError.invalidLock(lock)
            }
        }
        let configSchema = try PluginConfigSchema.load(manifest.config, from: rootURL)
        try validateUI(manifest, hasConfigSchema: configSchema != nil)
        try validateWatch(manifest)

        return LoadedPlugin(manifest: manifest, rootURL: rootURL, configSchema: configSchema)
    }

    private func validateCommands(_ commands: [(id: String, argv: [String])], rootURL: URL) throws {
        var ids = Set<String>()
        for command in commands {
            guard Self.matches(command.id, Self.contributionIDPattern) else {
                throw PluginLoadError.invalidContributionID(command.id)
            }
            guard !command.argv.isEmpty else { throw PluginLoadError.emptyCommand(command.id) }
            guard !command.argv.contains(where: { argument in
                argument.unicodeScalars.contains(where: { $0.value == 0 })
            }), !command.argv[0].unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            }) else {
                throw PluginLoadError.invalidCommandArgument(command.id)
            }
            guard Self.isAllowedExecutable(command.argv[0]) else {
                throw PluginLoadError.invalidCommandPath(command.id)
            }
            guard ids.insert(command.id).inserted else { throw PluginLoadError.duplicateCommandID(command.id) }
            try validateLocalExecutable(command.argv[0], id: command.id, rootURL: rootURL)
        }
    }

    private func validateDisplayText(_ manifest: PluginManifest) throws {
        var fields = [("name", manifest.name), ("license", manifest.license)]
        if let description = manifest.description { fields.append(("description", description)) }
        fields += manifest.checks.map { ("checks.\($0.id).label", $0.label) }
        fields += manifest.actions.map { ("actions.\($0.id).label", $0.label) }
        fields += manifest.ui.pages.map { ("ui.pages.\($0.id).title", $0.title) }
        fields += manifest.ui.sidebar.map { ("ui.sidebar.\($0.id).label", $0.label) }
        fields += manifest.ui.widgets.map { ("ui.widgets.\($0.id).title", $0.title) }
        if let blank = fields.first(where: {
            $0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            throw PluginLoadError.emptyField(blank.0)
        }
    }

    private func validateBrewPackages(_ packages: [String]) throws {
        guard Set(packages).count == packages.count,
              packages.allSatisfy({
                  $0.range(of: #"^[a-z0-9][a-z0-9@+._-]{0,159}$"#, options: .regularExpression) != nil
              }) else {
            throw PluginLoadError.invalidDependency("brew packages must be unique Homebrew core formula names")
        }
    }

    private func validateLocalExecutable(_ executable: String, id: String, rootURL: URL) throws {
        guard executable.hasPrefix("./") else { return }
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let relativePath = String(executable.dropFirst(2))
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(root.path + "/") else {
            throw PluginLoadError.invalidCommandPath(id)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              (try? candidate.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              FileManager.default.isExecutableFile(atPath: candidate.path) else {
            throw PluginLoadError.executableMissingOrNotExecutable(id)
        }
    }

    private func validateUI(_ manifest: PluginManifest, hasConfigSchema: Bool) throws {
        try validateDescriptorIDs(manifest.ui.pages.map(\.id))
        try validateDescriptorIDs(manifest.ui.sidebar.map(\.id))
        try validateDescriptorIDs(manifest.ui.widgets.map(\.id))

        let pageIDs = Set(manifest.ui.pages.map(\.id))
        for item in manifest.ui.sidebar where !pageIDs.contains(item.page) {
            throw PluginLoadError.invalidPageReference(item.page)
        }
        for widget in manifest.ui.widgets where !["1x1", "2x1"].contains(widget.size) {
            throw PluginLoadError.invalidWidgetSize(widget.size)
        }

        let checkIDs = Set(manifest.checks.map(\.id))
        let actionIDs = Set(manifest.actions.map(\.id))
        for descriptor in manifest.ui.pages.map({ ($0.kind, $0.source) })
            + manifest.ui.widgets.map({ ($0.kind, $0.source) }) {
            guard Self.isValidSource(
                descriptor.1,
                for: descriptor.0,
                checks: checkIDs,
                actions: actionIDs,
                hasConfigSchema: hasConfigSchema
            ) else {
                throw PluginLoadError.invalidSource(descriptor.1)
            }
        }
    }

    private func validateWatch(_ manifest: PluginManifest) throws {
        guard let watch = manifest.watch else { return }
        guard manifest.checks.contains(where: { $0.id == watch.status }) else {
            throw PluginLoadError.invalidWatchReference("checks.\(watch.status)")
        }
        if let start = watch.start,
           !manifest.actions.contains(where: { $0.id == start }) {
            throw PluginLoadError.invalidWatchReference("actions.\(start)")
        }
    }

    private func validateDescriptorIDs(_ ids: [String]) throws {
        var seen = Set<String>()
        for id in ids {
            guard Self.matches(id, Self.contributionIDPattern) else {
                throw PluginLoadError.invalidContributionID(id)
            }
            guard seen.insert(id).inserted else { throw PluginLoadError.duplicateDescriptorID(id) }
        }
    }

    private static func isValidSource(
        _ source: String,
        for kind: PluginUIKind,
        checks: Set<String>,
        actions: Set<String>,
        hasConfigSchema: Bool
    ) -> Bool {
        let components = source.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let exactCheck = components.count == 2 && components[0] == "checks" && checks.contains(components[1])
        let exactAction = components.count == 2 && components[0] == "actions" && actions.contains(components[1])
        switch kind {
        case .stat, .table:
            return exactCheck
        case .checks:
            return source == "checks" || exactCheck
        case .actions:
            return source == "actions" || exactAction
        case .log:
            return exactCheck || exactAction
        case .form:
            return source == "config" && hasConfigSchema
        case .watchers:
            return source == "watchers"
        }
    }

    private static func isAllowedExecutable(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != "./"
            && !value.hasPrefix("/")
            && !value.split(separator: "/", omittingEmptySubsequences: false).contains("..")
            && (!value.contains("/") || value.hasPrefix("./"))
    }

    static func isSemanticVersion(_ value: String) -> Bool {
        SemanticVersion(value) != nil
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}

private struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

extension Decoder {
    func rejectUnknownKeys<Key>(_ keyType: Key.Type) throws
    where Key: CodingKey & CaseIterable {
        let raw = try container(keyedBy: AnyCodingKey.self)
        let allowed = Set(Key.allCases.map(\.stringValue))
        guard let unknown = raw.allKeys.map(\.stringValue).filter({ !allowed.contains($0) }).sorted().first else {
            return
        }
        let path = (codingPath.map(\.stringValue) + [unknown]).joined(separator: ".")
        throw PluginLoadError.unknownField(path)
    }
}
