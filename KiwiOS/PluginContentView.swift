import SwiftUI

struct PluginContentView: View {
    let plugin: PluginState

    var body: some View {
        PluginFormView(plugin: plugin)
    }
}
private struct PluginFormView: View {
    @EnvironmentObject private var runtime: HubRuntime
    let plugin: PluginState
    @State private var text: [String: String] = [:]
    @State private var booleans: [String: Bool] = [:]
    @State private var selections: [String: Int] = [:]
    @State private var loadedValues: [String: JSONValue] = [:]
    @State private var revision: Int64?
    @State private var dirtyKeys: Set<String> = []
    @State private var saving = false
    @State private var message: String?

    var body: some View {
        if let schema = runtime.schema(pluginID: plugin.id) {
            VStack(alignment: .leading, spacing: 14) {
                if let title = schema.title { Text(title).font(.headline) }
                if let description = schema.description { Text(description).foregroundStyle(.secondary) }
                ForEach(schema.properties.keys.sorted(), id: \.self) { key in
                    if let field = schema.properties[key] { fieldView(key, field) }
                }
                HStack {
                    Button("Save") { Task { await save(schema) } }
                        .disabled(revision == nil || dirtyKeys.isEmpty || saving)
                        .accessibilityLabel("Save \(plugin.manifest.name) configuration")
                    Button("Reload") { Task { await load(schema) } }
                        .disabled(saving)
                    if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                }
            }
            .task(id: plugin.id) { await load(schema) }
        } else {
            ContentUnavailableView("No configuration", systemImage: "slider.horizontal.3", description: Text("This plugin has no config schema."))
        }
    }

    @ViewBuilder private func fieldView(_ key: String, _ field: PluginConfigField) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(field.title ?? key).fontWeight(.medium)
            if let description = field.description { Text(description).font(.caption).foregroundStyle(.secondary) }
            if let warning = field.warning { Text(warning).font(.caption).foregroundStyle(Color(red: 1, green: 0.38, blue: 0)) }
            if field.writeOnly {
                SecureField("Leave blank to keep the current value", text: textBinding(key, field))
                    .disabled(!isSetup)
                    .accessibilityLabel(field.title ?? key)
                if !isSetup { Text("Secret fields require setup mode.").font(.caption2).foregroundStyle(.secondary) }
            } else if let choices = field.enumValues {
                Picker(field.title ?? key, selection: Binding(
                    get: { selections[key] ?? -1 }, set: { value in
                        selections[key] = value
                        updateDirty(key, field)
                    }
                )) {
                    Text("Choose…").tag(-1)
                    ForEach(choices.indices, id: \.self) { index in Text(choices[index].displayText).tag(index) }
                }.labelsHidden().accessibilityLabel(field.title ?? key)
            } else if field.type == .boolean {
                Toggle("Enabled", isOn: Binding(get: { booleans[key] ?? false }, set: { value in
                    booleans[key] = value
                    updateDirty(key, field)
                }))
                    .accessibilityLabel(field.title ?? key)
            } else {
                TextField(field.type == .string ? "Value" : "Number", text: textBinding(key, field))
                    .accessibilityLabel(field.title ?? key)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func textBinding(_ key: String, _ field: PluginConfigField) -> Binding<String> {
        Binding(get: { text[key] ?? "" }, set: { value in
            text[key] = value
            updateDirty(key, field)
        })
    }

    private var isSetup: Bool {
        if case .setup = runtime.mode { return true }
        return false
    }

    @MainActor private func load(_ schema: PluginConfigSchema) async {
        guard let snapshot = await runtime.configSnapshot(pluginID: plugin.id) else {
            message = "Could not load configuration; see the reported error."
            return
        }
        text.removeAll()
        booleans.removeAll()
        selections.removeAll()
        loadedValues = snapshot.values
        revision = snapshot.revision
        for (key, field) in schema.properties {
            let value = snapshot.values[key] ?? field.defaultValue
            if let choices = field.enumValues, let value { selections[key] = choices.firstIndex(of: value) ?? -1 }
            else if case .bool(let value)? = value { booleans[key] = value }
            else if field.type == .integer, case .number(let number)? = value {
                text[key] = abs(number) <= PluginLexicalValidator.maximumSafeInteger
                    ? String(Int64(number)) : String(number)
            }
            else if !field.writeOnly, let value {
                text[key] = value.displayText
            }
        }
        dirtyKeys.removeAll()
        message = nil
    }

    @MainActor private func save(_ schema: PluginConfigSchema) async {
        guard let revision else { return }
        saving = true
        defer { saving = false }
        var values: [String: JSONValue] = [:]
        for key in dirtyKeys.sorted() {
            guard let field = schema.properties[key] else { continue }
            if field.writeOnly {
                let raw = text[key] ?? ""
                if raw.isEmpty { continue }
                guard let value = parsed(raw, as: field.type, label: field.title ?? key) else { return }
                if let choices = field.enumValues, !choices.contains(value) {
                    message = "Choose an allowed value for \(field.title ?? key)."; return
                }
                values[key] = value
            } else if let choices = field.enumValues {
                guard let index = selections[key], choices.indices.contains(index) else {
                    if field.required { message = "Choose \(field.title ?? key)."; return }
                    continue
                }
                values[key] = choices[index]
            } else if field.type == .boolean {
                values[key] = .bool(booleans[key] ?? false)
            } else {
                let raw = text[key] ?? ""
                if raw.isEmpty && field.type != .string && !field.required { continue }
                switch field.type {
                case .string: values[key] = .string(raw)
                case .number:
                    guard let number = Double(raw), number.isFinite else { message = "Enter a valid number for \(field.title ?? key)."; return }
                    values[key] = .number(number)
                case .integer:
                    guard let number = Double(raw), number.isFinite, number.rounded() == number,
                          abs(number) <= PluginLexicalValidator.maximumSafeInteger else {
                        message = "Enter a safe whole number for \(field.title ?? key)."; return
                    }
                    values[key] = .number(number)
                case .boolean: break
                }
            }
        }
        guard let saved = await runtime.saveConfig(
            pluginID: plugin.id, patch: values, expectedRevision: revision
        ) else {
            message = "Could not save. Configuration may have changed elsewhere; reload and review your edits."
            return
        }
        loadedValues = saved.values
        self.revision = saved.revision
        dirtyKeys.removeAll()
        message = "Saved"
        for (key, field) in schema.properties where field.writeOnly { text[key] = "" }
    }

    private func updateDirty(_ key: String, _ field: PluginConfigField) {
        let baseline = loadedValues[key] ?? field.defaultValue
        let current: JSONValue?
        if field.writeOnly {
            current = (text[key] ?? "").isEmpty ? nil : .string(text[key] ?? "")
            if current == nil { dirtyKeys.remove(key); return }
        } else if let choices = field.enumValues {
            guard let index = selections[key], choices.indices.contains(index) else {
                dirtyKeys.remove(key)
                return
            }
            current = choices[index]
        } else if field.type == .boolean {
            current = .bool(booleans[key] ?? false)
        } else if field.type == .string {
            current = .string(text[key] ?? "")
        } else {
            let raw = text[key] ?? ""
            guard !raw.isEmpty else {
                dirtyKeys.remove(key)
                return
            }
            guard let number = Double(raw), number.isFinite else {
                dirtyKeys.insert(key)
                return
            }
            current = .number(number)
        }
        if !field.writeOnly, current == baseline { dirtyKeys.remove(key) }
        else { dirtyKeys.insert(key) }
    }

    private func parsed(_ raw: String, as type: PluginConfigFieldType, label: String) -> JSONValue? {
        switch type {
        case .string: return .string(raw)
        case .boolean:
            guard let value = Bool(raw) else { message = "Enter true or false for \(label)."; return nil }
            return .bool(value)
        case .number:
            guard let value = Double(raw), value.isFinite else { message = "Enter a valid number for \(label)."; return nil }
            return .number(value)
        case .integer:
            guard let value = Double(raw), value.isFinite, value.rounded() == value,
                  abs(value) <= PluginLexicalValidator.maximumSafeInteger else {
                message = "Enter a safe whole number for \(label)."; return nil
            }
            return .number(value)
        }
    }
}
