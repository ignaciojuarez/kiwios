import SwiftUI

private enum Nav: String, Hashable, CaseIterable {
    case home, monitor, jobs, plugins, settings
    var title: String {
        switch self {
        case .home: "Home"
        case .monitor: "Monitor"
        case .jobs: "Jobs"
        case .plugins: "Plugins"
        case .settings: "Settings"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var runtime: HubRuntime
    @State private var nav: Nav? = .home

    var body: some View {
        NavigationSplitView {
            List(Nav.allCases, id: \.self, selection: $nav) { item in
                Label(item.title, systemImage: icon(item))
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .listStyle(.sidebar)
        } detail: {
            switch nav ?? .home {
            case .home: HomeView()
            case .monitor: PlaceholderView(title: "Monitor", note: "CPU, RAM, disks — native.monitor")
            case .jobs: PlaceholderView(title: "Jobs", note: "Queue, lock, log — native.jobs")
            case .plugins: PluginsView()
            case .settings: PlaceholderView(title: "Settings", note: "Sidebar order, Serve, setup / remote")
            }
        }
        .tint(KiwiTheme.accent)
        .preferredColorScheme(.dark)
    }

    private func icon(_ item: Nav) -> String {
        switch item {
        case .home: "house"
        case .monitor: "waveform.path.ecg"
        case .jobs: "list.bullet.rectangle"
        case .plugins: "puzzlepiece.extension"
        case .settings: "gearshape"
        }
    }
}

private struct HomeView: View {
    @EnvironmentObject private var runtime: HubRuntime

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("KiwiOS")
                    .font(.largeTitle.weight(.semibold))
                Text("Mac mini hub")
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    StatCard(title: "Host", value: "—", footnote: "native.monitor")
                    StatCard(title: "Jobs", value: "0", footnote: "idle")
                    StatCard(
                        title: "Plugins",
                        value: "\(runtime.plugins.count)",
                        footnote: runtime.plugins.isEmpty ? "none discovered" : runtime.plugins.map(\.manifest.name).joined(separator: ", ")
                    )
                    StatCard(
                        title: "Checks",
                        value: "\(runtime.plugins.flatMap(\.manifest.checks).count)",
                        footnote: runtime.plugins.contains { $0.status == .running } ? "running" : "ready"
                    )
                }
            }
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
        }
        .background(KiwiTheme.bg)
        .navigationTitle("Home")
    }
}

private struct PluginsView: View {
    @EnvironmentObject private var runtime: HubRuntime
    @State private var pendingAction: PendingAction?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if runtime.plugins.isEmpty {
                    ContentUnavailableView(
                        "No plugins",
                        systemImage: "puzzlepiece.extension",
                        description: Text(runtime.discoveryError ?? "No bundled plugins were discovered")
                    )
                }

                ForEach(runtime.plugins) { plugin in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(plugin.manifest.name)
                                .font(.title2.weight(.medium))
                            Text(plugin.manifest.version)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(plugin.status.label)
                                .foregroundStyle(plugin.status.color)
                        }

                        Text(plugin.message)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)

                        HStack {
                            ForEach(plugin.manifest.checks) { check in
                                Button(check.label) {
                                    Task { await runtime.runCheck(pluginID: plugin.id, checkID: check.id) }
                                }
                                .disabled(plugin.status == .running)
                            }

                            ForEach(plugin.manifest.actions) { action in
                                Button(action.label) {
                                    if action.confirm {
                                        pendingAction = PendingAction(pluginID: plugin.id, action: action)
                                    } else {
                                        Task { await runtime.runAction(pluginID: plugin.id, actionID: action.id) }
                                    }
                                }
                                .disabled(plugin.status == .running)
                            }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(KiwiTheme.card, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(KiwiTheme.bg)
        .navigationTitle("Plugins")
        .confirmationDialog(
            "Run \(pendingAction?.action.label ?? "action")?",
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            )
        ) {
            Button("Run") {
                guard let pendingAction else { return }
                self.pendingAction = nil
                Task {
                    await runtime.runAction(
                        pluginID: pendingAction.pluginID,
                        actionID: pendingAction.action.id
                    )
                }
            }
            Button("Cancel", role: .cancel) { pendingAction = nil }
        }
    }
}

private struct PendingAction {
    let pluginID: String
    let action: PluginAction
}

private struct PlaceholderView: View {
    let title: String
    let note: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title2.weight(.medium))
            Text(note).foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(KiwiTheme.bg)
        .navigationTitle(title)
    }
}

private struct StatCard: View {
    let title: String
    let value: String
    let footnote: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title.weight(.semibold))
            Text(footnote)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KiwiTheme.card, in: RoundedRectangle(cornerRadius: 14))
    }
}

enum KiwiTheme {
    static let accent = Color(red: 0.72, green: 0.95, blue: 0.29)
    static let bg = Color(red: 0.06, green: 0.06, blue: 0.07)
    static let card = Color(red: 0.11, green: 0.11, blue: 0.12)
}

private extension PluginRunStatus {
    var color: Color {
        switch self {
        case .idle: .secondary
        case .running: .blue
        case .ok: .green
        case .warn: .orange
        case .error: .red
        }
    }
}
