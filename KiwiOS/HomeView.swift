import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var runtime: HubRuntime
    @State private var editing = false
    let openPlugins: () -> Void
    let openSettings: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Mac mini hub").font(.largeTitle.weight(.semibold))
                        Text("\(runtime.plugins.filter { $0.lifecycle == .active }.count) active plugins")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(editing ? "Done" : "Edit Home") { editing.toggle() }
                }
                if let error = runtime.discoveryError { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                setupGuide
                if editing { LayoutEditor() }
                if visibleWidgets.isEmpty {
                    ContentUnavailableView("No widgets", systemImage: "square.grid.2x2",
                        description: Text("Add a plugin, then choose its widgets using Edit Home."))
                }
                ForEach(visibleWidgets, id: \.key) { item in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(item.widget.title).font(.headline)
                        PluginContentView(plugin: item.plugin, kind: item.widget.kind,
                            source: item.widget.source, showsMetadata: false)
                    }
                    .padding(18)
                    .frame(maxWidth: runtime.layout.wideWidgets.contains(item.key) ? .infinity : 520, alignment: .leading)
                    .background(KiwiTheme.card, in: RoundedRectangle(cornerRadius: 14))
                }
            }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
        }.navigationTitle("Home")
    }

    private var setupComplete: Bool {
        doctorReady && firstPluginReady && launchAtLoginReady && runtime.remote.enabled && runtime.remote.origin != nil
    }

    private var doctorReady: Bool {
        DoctorReadiness.hostIsReady(runtime.doctorFindings, excluding: ["launch-at-login"])
    }

    private var firstPluginReady: Bool {
        runtime.plugins.contains { $0.lifecycle == .active }
    }

    private var launchAtLoginReady: Bool {
        runtime.doctorFindings.first(where: { $0.id == "launch-at-login" })?.status == .passed
    }

    @ViewBuilder private var setupGuide: some View {
        if setupComplete {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Setup complete").font(.headline)
                    if let origin = runtime.remote.origin {
                        Text("KiwiOS is available on your tailnet at \(origin.absoluteString)")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(KiwiTheme.card, in: RoundedRectangle(cornerRadius: 14))
        } else {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Set up this Mac").font(.title2.weight(.semibold))
                    Text("Complete these checks at the Mac before relying on KiwiOS from your phone.")
                        .foregroundStyle(.secondary)
                }
                SetupStep(number: 1, title: "Check the Mac with Doctor", complete: doctorReady,
                    detail: doctorReady ? "Core host checks passed." : "Resolve blocked or unknown host prerequisites.",
                    action: "Open Doctor", perform: openSettings)
                SetupStep(number: 2, title: "Add a plugin", complete: firstPluginReady,
                    detail: firstPluginReady ? "At least one plugin is ready." : "Inspect its source and disclosures before trusting it.",
                    action: "Review plugins", perform: openPlugins)
                SetupStep(number: 3, title: "Start KiwiOS after login", complete: launchAtLoginReady,
                    detail: launchAtLoginReady ? "Launch at login is enabled." : "Enable launch at login for the owning Mac user.",
                    action: "Open Settings", perform: openSettings)
                VStack(alignment: .leading, spacing: 10) {
                    SetupStep(number: 4, title: "Connect your phone", complete: runtime.remote.enabled && runtime.remote.origin != nil,
                        detail: runtime.remote.enabled ? "Tailnet browser access is active." : "Publish KiwiOS through its managed Tailscale Serve origin.",
                        action: nil, perform: {})
                    RemoteAccessPanel()
                }
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(KiwiTheme.card, in: RoundedRectangle(cornerRadius: 14))
        }
    }
    private var visibleWidgets: [(key: String, plugin: PluginState, widget: PluginWidget)] {
        runtime.layout.widgets.compactMap { key in
            guard !runtime.layout.hiddenWidgets.contains(key) else { return nil }
            let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2, let plugin = runtime.plugins.first(where: { $0.id == parts[0] && $0.lifecycle == .active }),
                  let widget = plugin.manifest.ui.widgets.first(where: { $0.id == parts[1] }) else { return nil }
            return (key, plugin, widget)
        }
    }
}

private struct SetupStep: View {
    let number: Int
    let title: String
    let complete: Bool
    let detail: String
    let action: String?
    let perform: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: complete ? "checkmark.circle.fill" : "\(number).circle")
                .font(.title3).foregroundStyle(complete ? .green : KiwiTheme.accent)
                .accessibilityLabel(complete ? "Complete" : "Step \(number)")
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !complete, let action {
                Button(action, action: perform)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct LayoutEditor: View {
    @EnvironmentObject private var runtime: HubRuntime
    var body: some View {
        GroupBox("Home widgets") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(runtime.plugins.filter { $0.lifecycle == .active }) { plugin in
                    ForEach(plugin.manifest.ui.widgets) { widget in
                        let key = "\(plugin.id)/\(widget.id)"
                        HStack {
                            Toggle("\(plugin.manifest.name): \(widget.title)", isOn: Binding(
                                get: { runtime.layout.widgets.contains(key) && !runtime.layout.hiddenWidgets.contains(key) },
                                set: { selected in
                                    var layout = runtime.layout
                                    if selected {
                                        if !layout.widgets.contains(key) { layout.widgets.append(key) }
                                        layout.hiddenWidgets.remove(key)
                                    } else { layout.hiddenWidgets.insert(key) }
                                    Task { await runtime.changeLayout(layout) }
                                }))
                            Toggle("Wide", isOn: Binding(get: { runtime.layout.wideWidgets.contains(key) }, set: { wide in
                                var layout = runtime.layout
                                if wide { layout.wideWidgets.insert(key) } else { layout.wideWidgets.remove(key) }
                                Task { await runtime.changeLayout(layout) }
                            })).toggleStyle(.checkbox)
                            Button("Move up", systemImage: "arrow.up") {
                                var layout = runtime.layout
                                if let index = layout.widgets.firstIndex(of: key), index > 0 { layout.widgets.swapAt(index, index - 1) }
                                Task { await runtime.changeLayout(layout) }
                            }.labelStyle(.iconOnly).accessibilityLabel("Move \(widget.title) up")
                        }
                    }
                }
            }.padding(8)
        }
    }
}
