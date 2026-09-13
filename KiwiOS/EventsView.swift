import SwiftUI

struct EventsView: View {
    @EnvironmentObject private var runtime: HubRuntime

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Events").font(.largeTitle)
                Text("Latest line from each plugin").font(.caption).foregroundStyle(.secondary)
                ForEach(runtime.plugins) { plugin in
                    let event = latestEvent(for: plugin)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if let date = event.date { Text(date, style: .time).foregroundStyle(.tertiary) }
                        else { Text("--:--:--").foregroundStyle(.tertiary) }
                        Text("[\(event.level)]").foregroundStyle(event.color)
                        Text(plugin.id).foregroundStyle(.secondary)
                        Text(event.message).lineLimit(1).textSelection(.enabled)
                    }
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Events")
    }

    private func latestEvent(for plugin: PluginState) -> (date: Date?, level: String, message: String, color: Color) {
        if let live = plugin.liveResults.values.first(where: { !$0.logs.isEmpty || !$0.protocolWarnings.isEmpty }) {
            if let warning = live.protocolWarnings.last {
                return (nil, "WARN", warning, .orange)
            }
            let log = live.logs.last!
            return (nil, log.level?.rawValue.uppercased() ?? "INFO", log.message,
                    log.level == .error ? .red : log.level == .warn ? .orange : .primary)
        }
        if let source = plugin.resultDates.max(by: { $0.value < $1.value })?.key,
           let result = plugin.results[source] {
            if let warning = result.protocolWarnings.last {
                return (plugin.resultDates[source], "WARN", warning, .orange)
            }
            if ![.succeeded, .warning].contains(result.outcome) {
                return (plugin.resultDates[source], "ERROR", result.message, .red)
            }
            if result.outcome == .warning {
                return (plugin.resultDates[source], "WARN", result.message, .orange)
            }
            if let log = result.logs.last {
                return (plugin.resultDates[source], log.level?.rawValue.uppercased() ?? "INFO", log.message,
                        log.level == .error ? .red : log.level == .warn ? .orange : .primary)
            }
            return (plugin.resultDates[source], "OK", result.message, .green)
        }
        let level = plugin.lifecycle == .active ? "INFO" : plugin.lifecycle == .disabled ? "OFF" : "WARN"
        return (nil, level, plugin.message, plugin.lifecycle == .active ? .primary : .orange)
    }
}
