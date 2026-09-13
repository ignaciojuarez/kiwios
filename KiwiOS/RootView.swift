import SwiftUI
import AppKit

struct RootView: View {
    @EnvironmentObject private var runtime: HubRuntime
    @State private var selection: String? = "home"

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Home", systemImage: "house").tag("home")
                Label("Tools", systemImage: "wrench.and.screwdriver").tag("tools")
                Label("Events", systemImage: "terminal").tag("events")
                Label("Plugins", systemImage: "puzzlepiece.extension").tag("plugins")
                Label("Discover", systemImage: "shippingbox").tag("discover")
                ForEach(runtime.layout.sidebar, id: \.self) { key in
                    if let entry = sidebarEntry(key) {
                        Label(entry.label, systemImage: "rectangle.grid.1x2").tag("page:\(entry.pluginID)/\(entry.pageID)")
                    }
                }
                Label("Settings", systemImage: "gearshape").tag("settings")
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            VStack(spacing: 0) {
                if let error = runtime.operationError {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle")
                        Text(error).textSelection(.enabled)
                        Spacer()
                        Button("Dismiss") { runtime.clearError() }
                    }
                    .padding().background(Color.orange.opacity(0.12))
                    .accessibilityElement(children: .contain)
                }
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(KiwiTheme.bg)
        }
        .tint(KiwiTheme.accent)
        .preferredColorScheme(.dark)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await runtime.refreshDoctor() }
        }
        .sheet(item: $runtime.pendingReview) { review in
            PluginApprovalView(review: review)
                .environmentObject(runtime)
        }
        .sheet(item: $runtime.pendingInstallation) { review in InstallationApprovalView(review: review).environmentObject(runtime) }
        .sheet(item: $runtime.pendingRemoval) { review in PluginRemovalView(review: review).environmentObject(runtime) }
        .sheet(item: $runtime.native.pendingConfirmation) { confirmation in
            VStack(alignment: .leading, spacing: 18) {
                Text(confirmation.title).font(.title2)
                if let detail = confirmation.operation.confirmationDetail {
                    Text(detail).textSelection(.enabled)
                }
                Text("KiwiOS will record and run this operation after confirmation. Confirmation expires after one minute.")
                HStack {
                    Button("Cancel", role: .cancel) {
                        Task { await runtime.cancelNativeConfirmation(confirmation) }
                    }
                    Spacer()
                    Button("Confirm action") { Task { await runtime.confirmNativeOperation(confirmation) } }
                        .buttonStyle(.borderedProminent)
                }
            }.padding(28).frame(width: 480)
        }
        .sheet(item: $runtime.pendingConfirmation) { confirmation in
            VStack(alignment: .leading, spacing: 18) {
                Text("Run \(confirmation.label)?").font(.title2)
                Text("This action runs as your Mac user. Review the plugin and action before continuing.")
                Text("Confirmation expires after one minute.").foregroundStyle(.secondary)
                HStack {
                    Button("Cancel", role: .cancel) { runtime.pendingConfirmation = nil }
                    Spacer()
                    Button("Run action") { Task { await runtime.confirmAction(confirmation) } }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(28).frame(width: 460)
        }
    }

    @ViewBuilder private var content: some View {
        switch selection ?? "home" {
        case "home": HomeView(
            openPlugins: { selection = "plugins" },
            openSettings: { selection = "settings" }
        )
        case "tools": NativeToolsView(snapshot: runtime.native.toolsSnapshot, mode: runtime.mode,
            peers: runtime.native.peers, isRefreshing: runtime.native.toolsRefreshing,
            isBusy: { runtime.isNativeBusy($0) }, refresh: { await runtime.refreshNativeTools() },
            request: { runtime.requestNativeOperation($0) },
            addPeer: { peer in await runtime.addSSHPeer(peer) },
            removePeer: { peer in Task { await runtime.removeSSHPeer(peer) } })
            .task { if runtime.native.toolsSnapshot == nil { await runtime.refreshNativeTools() } }
        case "discover": PluginMarketplaceView()
        case "events": EventsView()
        case "plugins": PluginsView()
        case "settings": HubSettingsView()
        default:
            if let descriptor = selectedPage {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(descriptor.page.title).font(.largeTitle)
                        PluginContentView(plugin: descriptor.plugin, kind: descriptor.page.kind, source: descriptor.page.source)
                    }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
                }.navigationTitle(descriptor.page.title)
            } else {
                ContentUnavailableView("Page unavailable", systemImage: "rectangle.slash",
                    description: Text("The saved page belongs to a plugin that is not currently available."))
            }
        }
    }
    private var selectedPage: (plugin: PluginState, page: PluginPage)? {
        guard let selection, selection.hasPrefix("page:") else { return nil }
        let parts = selection.dropFirst(5).split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, let plugin = runtime.plugins.first(where: { $0.id == parts[0] && $0.lifecycle == .active }),
              let page = plugin.manifest.ui.pages.first(where: { $0.id == parts[1] }) else { return nil }
        return (plugin, page)
    }
    private func sidebarEntry(_ key: String) -> (label: String, pluginID: String, pageID: String)? {
        let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, let plugin = runtime.plugins.first(where: { $0.id == parts[0] && $0.lifecycle == .active }),
              let item = plugin.manifest.ui.sidebar.first(where: { $0.id == parts[1] }) else { return nil }
        return (item.label, plugin.id, item.page)
    }
}


enum KiwiTheme {
    static let accent = Color(red: 0.72, green: 0.95, blue: 0.29)
    static let bg = Color(red: 0.06, green: 0.06, blue: 0.07)
    static let card = Color(red: 0.11, green: 0.11, blue: 0.12)
}
