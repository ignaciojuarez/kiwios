import SwiftUI

struct PluginContentView: View {
    @EnvironmentObject private var runtime: HubRuntime
    let plugin: PluginState
    let kind: PluginUIKind
    let source: String
    var showsMetadata = true

    var body: some View {
        Group {
            switch kind {
            case .stat: stat
            case .checks: checks
            case .actions: actions
            case .table: table
            case .log: log
            case .watchers: watchers
            case .form:
                if source == "config" {
                    PluginFormView(plugin: plugin)
                } else {
                    invalid("Invalid form source", "Forms must use the config source.")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var stat: some View {
        let busy = runtime.isBusy(pluginID: plugin.id, source: source)
        let live = plugin.liveResults[source]
        let result = plugin.results[source]
        let selectedState = busy ? (live?.state ?? result?.state) : result?.state
        if let selectedState {
            if let state = StatState(selectedState) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(state.value).font(.system(.title, design: .rounded).weight(.semibold))
                        if let unit = state.unit { Text(unit).foregroundStyle(.secondary) }
                    }
                    if showsMetadata {
                        if let detail = state.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                        if let delta = state.delta { Text(delta).font(.caption.weight(.medium)).foregroundStyle(.secondary) }
                        if busy { LiveFooter(snapshot: live) }
                        else if let result { ResultFooter(result: result, date: plugin.resultDates[source]) }
                    }
                }
            } else {
                invalid("Invalid stat data", "State.value must be a string or number; unit, detail, and delta must be strings.")
            }
        } else if busy { unavailable("Running", "Waiting for stat data.") }
        else { unavailable("No result", "Run the check to populate this value.") }
    }

    @ViewBuilder private var checks: some View {
        let visible = plugin.manifest.checks.filter { source == "checks" || source == "checks.\($0.id)" }
        if visible.isEmpty {
            unavailable("No checks", "This source has no matching check.")
        } else {
            VStack(spacing: 8) {
                ForEach(visible) { check in
                    let key = "checks.\(check.id)"
                    let busy = runtime.isBusy(pluginID: plugin.id, source: key)
                    HStack(alignment: .top, spacing: 12) {
                        OutcomeDot(outcome: plugin.results[key]?.outcome, running: busy)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(check.label).fontWeight(.medium)
                            Text(busy ? "Running…" : (plugin.results[key]?.message ?? "Unavailable"))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            ProgressSummary(progress: busy ? plugin.liveResults[key]?.progress : plugin.results[key]?.progress)
                        }
                        Spacer()
                        Button("Run") {
                            Task { await runtime.runCheck(pluginID: plugin.id, checkID: check.id) }
                        }
                        .accessibilityLabel("Run \(check.label)")
                        .disabled(!canRun || busy)
                    }
                    .padding(10)
                    .background(KiwiTheme.card.opacity(0.7), in: RoundedRectangle(cornerRadius: 9))
                }
            }
        }
    }

    @ViewBuilder private var actions: some View {
        let visible = plugin.manifest.actions.filter { source == "actions" || source == "actions.\($0.id)" }
        if visible.isEmpty {
            unavailable("No actions", "This source has no matching action.")
        } else {
            VStack(spacing: 8) {
                ForEach(visible) { action in
                    let key = "actions.\(action.id)"
                    let busy = runtime.isBusy(pluginID: plugin.id, source: key)
                    HStack(alignment: .top, spacing: 12) {
                        OutcomeDot(outcome: plugin.results[key]?.outcome, running: busy)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(action.label).fontWeight(.medium)
                            Text(busy ? "Running…" : (plugin.results[key]?.message ?? "Not run yet"))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            ProgressSummary(progress: busy ? plugin.liveResults[key]?.progress : plugin.results[key]?.progress)
                            if !busy, let date = plugin.resultDates[key] { Text(age(date)).font(.caption2).foregroundStyle(.tertiary) }
                        }
                        Spacer()
                        Button(action.confirm ? "Review…" : "Run") {
                            Task { await runtime.runAction(pluginID: plugin.id, actionID: action.id) }
                        }
                        .accessibilityLabel("\(action.confirm ? "Review" : "Run") \(action.label)")
                        .disabled(!canRun || busy)
                    }
                    .padding(10)
                    .background(KiwiTheme.card.opacity(0.7), in: RoundedRectangle(cornerRadius: 9))
                }
            }
        }
    }

    @ViewBuilder private var table: some View {
        let busy = runtime.isBusy(pluginID: plugin.id, source: source)
        let live = plugin.liveResults[source]
        let result = plugin.results[source]
        let selectedState = busy ? live?.state : result?.state
        if let selectedState {
            switch TableState.parse(selectedState) {
            case .success(let state):
                ScrollView(.horizontal) {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                        GridRow {
                            ForEach(state.columns) { column in
                                Text(column.label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            }
                        }
                        Divider().gridCellColumns(state.columns.count)
                        ForEach(state.rows) { row in
                            GridRow {
                                ForEach(state.columns) { column in
                                    Text(row.values[column.id]?.displayText ?? "—").lineLimit(2)
                                }
                            }
                        }
                    }
                    .textSelection(.enabled)
                }
                if state.rows.isEmpty { Text("No rows").foregroundStyle(.secondary) }
                if busy { LiveFooter(snapshot: live) }
                else if let result { ResultFooter(result: result, date: plugin.resultDates[source]) }
            case .failure(let reason): invalid("Invalid table data", reason)
            }
        } else if busy { unavailable("Running", "Waiting for table data.") }
        else { unavailable("No table data", "Run the check to populate this table.") }
    }

    @ViewBuilder private var log: some View {
        let busy = runtime.isBusy(pluginID: plugin.id, source: source)
        let live = plugin.liveResults[source]
        let result = plugin.results[source]
        let logs = busy ? (live?.logs ?? []) : (result?.logs ?? [])
        if busy || result != nil {
            if logs.isEmpty {
                unavailable("No log output", busy ? "Waiting for log output." : "The latest run did not emit log text.")
            } else {
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(logs.enumerated()), id: \.offset) { _, entry in
                            Text("[\(entry.source.rawValue)] \(entry.message)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(entry.level == .error ? .red : .primary)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 100, maxHeight: 320)
                if busy { LiveFooter(snapshot: live) }
                else if let result { ResultFooter(result: result, date: plugin.resultDates[source]) }
            }
        } else { unavailable("No log", "Run this contribution to capture its output.") }
    }

    @ViewBuilder private var watchers: some View {
        let sessions = runtime.plugins.filter { $0.lifecycle == .active && $0.manifest.watch != nil }
        if sessions.isEmpty {
            unavailable("No watched sessions", "Active plugins can opt in with a status check and an optional start action.")
        } else {
            VStack(spacing: 8) {
                ForEach(sessions) { session in
                    if let watch = session.manifest.watch {
                        let statusKey = "checks.\(watch.status)"
                        let statusBusy = runtime.isBusy(pluginID: session.id, source: statusKey)
                        let status = session.results[statusKey]
                        let startKey = watch.start.map { "actions.\($0)" }
                        let startBusy = startKey.map { runtime.isBusy(pluginID: session.id, source: $0) } ?? false
                        let progress = startBusy
                            ? startKey.flatMap { session.liveResults[$0]?.progress }
                            : statusBusy ? session.liveResults[statusKey]?.progress : status?.progress
                        let log = startBusy
                            ? startKey.flatMap { session.liveResults[$0]?.logs.last?.message }
                            : statusBusy
                                ? session.liveResults[statusKey]?.logs.last?.message
                                : status?.logs.last?.message
                        let message = startBusy ? "Starting…" : statusBusy ? "Checking…" : status?.message ?? "Status unavailable"
                        HStack(alignment: .top, spacing: 12) {
                            OutcomeDot(outcome: status?.outcome, running: statusBusy || startBusy)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(session.manifest.name).fontWeight(.medium)
                                Text(message)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                if let log, log != message {
                                    Text(log).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
                                }
                                ProgressSummary(progress: progress)
                                if !statusBusy, let date = session.resultDates[statusKey] {
                                    Text(age(date)).font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                            Spacer()
                            if let actionID = watch.start,
                               !statusBusy,
                               ![.succeeded, .warning].contains(status?.outcome) {
                                Button(startBusy ? "Starting…" : "Start") {
                                    Task { await runtime.runAction(pluginID: session.id, actionID: actionID) }
                                }
                                .disabled(startBusy)
                            }
                        }
                        .padding(10)
                        .background(KiwiTheme.card.opacity(0.7), in: RoundedRectangle(cornerRadius: 9))
                    }
                }
            }
        }
    }

    private var canRun: Bool {
        if case .active = plugin.lifecycle { return true }
        return false
    }

    private func age(_ date: Date) -> String {
        RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }

    private func unavailable(_ title: String, _ detail: String) -> some View {
        ContentUnavailableView(title, systemImage: "questionmark.circle", description: Text(detail))
    }

    private func invalid(_ title: String, _ detail: String) -> some View {
        ContentUnavailableView(title, systemImage: "exclamationmark.triangle", description: Text(detail))
    }
}

private struct OutcomeDot: View {
    let outcome: WatchRunOutcome?
    var running = false
    var body: some View { Circle().fill(color).frame(width: 9, height: 9).padding(.top, 5).accessibilityLabel(label) }
    private var color: Color {
        if running { return .blue }
        return switch outcome { case .succeeded: .green; case .warning: .orange; case .failed, .timedOut, .canceled, .interrupted: .red; case nil: .secondary }
    }
    private var label: String { running ? "running" : (outcome?.rawValue ?? "unavailable") }
}

private struct ProgressSummary: View {
    let progress: WatchProgress?
    @ViewBuilder var body: some View {
        if let progress {
            VStack(alignment: .leading, spacing: 3) {
                if let percentage = progress.percentage { ProgressView(value: percentage, total: 100).frame(maxWidth: 220) }
                if let message = progress.message, !message.isEmpty { Text(message).font(.caption2).foregroundStyle(.secondary) }
                ForEach(progress.steps, id: \.id) { step in
                    HStack { Text(step.label); Spacer(); if let value = step.percentage { Text("\(Int(value))%") } }
                        .font(.caption2).foregroundStyle(.secondary).frame(maxWidth: 220)
                }
            }
        }
    }
}

private struct ResultFooter: View {
    let result: WatchRunResult
    let date: Date?
    var body: some View {
        HStack(spacing: 6) {
            Text(result.outcome.rawValue)
            if let date { Text("•"); Text(RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())) }
            if !result.protocolWarnings.isEmpty { Text("• protocol warning") }
        }
        .font(.caption2).foregroundStyle(.tertiary)
    }
}

private struct LiveFooter: View {
    let snapshot: WatchLiveSnapshot?
    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("Running")
            if snapshot?.protocolWarnings.isEmpty == false { Text("• protocol warning") }
        }
        .font(.caption2).foregroundStyle(.secondary)
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
