import Foundation

enum PluginConfigFieldType: String, Equatable, Sendable {
    case string, number, integer, boolean
}

struct PluginConfigField: Equatable, Sendable {
    let type: PluginConfigFieldType
    let title: String?
    let description: String?
    let enumValues: [JSONValue]?
    let defaultValue: JSONValue?
    let writeOnly: Bool
    let required: Bool
}

struct PluginConfigSchema: Equatable, Sendable {
    static let maximumBytes = 256 * 1024

    let title: String?
    let description: String?
    let properties: [String: PluginConfigField]

    static func load(_ config: PluginConfig?, from pluginRoot: URL) throws -> Self? {
        guard let config else { return nil }
        let path = config.schema
        guard PluginLexicalValidator.relativePath(path, allowRoot: false) else { throw PluginLoadError.invalidConfigPath(path) }
        let root = pluginRoot.standardizedFileURL.resolvingSymlinksInPath()
        let url = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(root.path + "/") else { throw PluginLoadError.invalidConfigPath(path) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        else { throw PluginLoadError.configSchemaMissing(path) }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= maximumBytes else { throw PluginLoadError.configSchemaTooLarge }
        return try decode(data)
    }

    static func decode(_ data: Data) throws -> Self {
        let value: JSONValue
        do { value = try JSONDecoder().decode(JSONValue.self, from: data) }
        catch { throw PluginLoadError.invalidConfigSchema("invalid JSON") }
        guard case .object(let root) = value else {
            throw PluginLoadError.invalidConfigSchema("root must be an object")
        }
        try rejectUnknown(root, allowed: ["type", "title", "description", "properties", "required"], scope: "root")
        guard root["type"] == .string("object") else {
            throw PluginLoadError.invalidConfigSchema("root type must be object")
        }
        let title = try optionalString(root["title"], at: "title")
        let description = try optionalString(root["description"], at: "description")
        guard case .object(let rawProperties)? = root["properties"] else {
            throw PluginLoadError.invalidConfigSchema("properties must be an object")
        }
        let required = try requiredNames(root["required"])
        guard required.isSubset(of: Set(rawProperties.keys)) else {
            throw PluginLoadError.invalidConfigSchema("required references an unknown property")
        }
        var properties: [String: PluginConfigField] = [:]
        for (name, rawField) in rawProperties.sorted(by: { $0.key < $1.key }) {
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PluginLoadError.invalidConfigSchema("invalid property name \(name)")
            }
            guard case .object(let field) = rawField else {
                throw PluginLoadError.invalidConfigSchema("property \(name) must be an object")
            }
            try rejectUnknown(
                field, allowed: ["type", "title", "description", "enum", "default", "writeOnly"],
                scope: "properties.\(name)"
            )
            guard case .string(let rawType)? = field["type"], let type = PluginConfigFieldType(rawValue: rawType) else {
                throw PluginLoadError.invalidConfigSchema("property \(name) has unsupported type")
            }
            let enumValues: [JSONValue]?
            if let enumValue = field["enum"] {
                guard case .array(let values) = enumValue, !values.isEmpty else {
                    throw PluginLoadError.invalidConfigSchema("property \(name) enum must be a nonempty array")
                }
                guard values.allSatisfy({ matches($0, type: type) }) else {
                    throw PluginLoadError.invalidConfigSchema("property \(name) enum has a mismatched value")
                }
                enumValues = values
            } else { enumValues = nil }
            let defaultValue = field["default"]
            if let defaultValue {
                guard matches(defaultValue, type: type) else {
                    throw PluginLoadError.invalidConfigSchema("property \(name) default has the wrong type")
                }
                if let enumValues, !enumValues.contains(defaultValue) {
                    throw PluginLoadError.invalidConfigSchema("property \(name) default is outside enum")
                }
            }
            let writeOnly: Bool
            if let raw = field["writeOnly"] {
                guard case .bool(let value) = raw else {
                    throw PluginLoadError.invalidConfigSchema("property \(name) writeOnly must be boolean")
                }
                writeOnly = value
            } else { writeOnly = false }
            if writeOnly && defaultValue != nil {
                throw PluginLoadError.invalidConfigSchema("property \(name) cannot give a writeOnly field a default")
            }
            properties[name] = PluginConfigField(
                type: type,
                title: try optionalString(field["title"], at: "properties.\(name).title"),
                description: try optionalString(field["description"], at: "properties.\(name).description"),
                enumValues: enumValues,
                defaultValue: defaultValue,
                writeOnly: writeOnly,
                required: required.contains(name)
            )
        }
        return Self(title: title, description: description, properties: properties)
    }

    func validated(values: [String: JSONValue]) throws -> [String: JSONValue] {
        if let unknown = values.keys.filter({ properties[$0] == nil }).sorted().first {
            throw PluginLoadError.invalidConfigSchema("unknown config value \(unknown)")
        }
        var effective = values
        for (name, field) in properties.sorted(by: { $0.key < $1.key }) {
            guard let value = values[name] else {
                if let defaultValue = field.defaultValue {
                    effective[name] = defaultValue
                } else if field.required {
                    throw PluginLoadError.invalidConfigSchema("missing required config value \(name)")
                }
                continue
            }
            guard Self.matches(value, type: field.type) else {
                throw PluginLoadError.invalidConfigSchema("config value \(name) has the wrong type")
            }
            if let choices = field.enumValues, !choices.contains(value) {
                throw PluginLoadError.invalidConfigSchema("config value \(name) is outside enum")
            }
        }
        return effective
    }

    private static func rejectUnknown(
        _ object: [String: JSONValue], allowed: Set<String>, scope: String
    ) throws {
        if let key = object.keys.filter({ !allowed.contains($0) }).sorted().first {
            throw PluginLoadError.invalidConfigSchema("unsupported keyword \(scope).\(key)")
        }
    }

    private static func optionalString(_ value: JSONValue?, at path: String) throws -> String? {
        guard let value else { return nil }
        guard case .string(let string) = value,
              !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PluginLoadError.invalidConfigSchema("\(path) must be a nonblank string")
        }
        return string
    }

    private static func requiredNames(_ value: JSONValue?) throws -> Set<String> {
        guard let value else { return [] }
        guard case .array(let items) = value else {
            throw PluginLoadError.invalidConfigSchema("required must be an array")
        }
        var names = Set<String>()
        for item in items {
            guard case .string(let name) = item else {
                throw PluginLoadError.invalidConfigSchema("required entries must be strings")
            }
            guard names.insert(name).inserted else {
                throw PluginLoadError.invalidConfigSchema("required contains duplicate \(name)")
            }
        }
        return names
    }

    private static func matches(_ value: JSONValue, type: PluginConfigFieldType) -> Bool {
        switch (type, value) {
        case (.string, .string), (.boolean, .bool): true
        case (.number, .number(let number)): number.isFinite
        case (.integer, .number(let number)):
            number.isFinite && number.rounded() == number
                && abs(number) <= PluginLexicalValidator.maximumSafeInteger
        default: false
        }
    }

}
