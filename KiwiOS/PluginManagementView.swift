import SwiftUI
import AppKit

struct PluginsView: View {
    @EnvironmentObject private var runtime: HubRuntime
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Plugins").font(.largeTitle)
                    Spacer()
                    Button("Reload sources", systemImage: "arrow.clockwise") { Task { await runtime.reload() } }
                }
                if let error = runtime.discoveryError { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                if runtime.plugins.isEmpty {
                    ContentUnavailableView("No plugins available", systemImage: "puzzlepiece.extension",
                        description: Text("Bundled plugins and the development folder selected in Settings are validated before loading."))
                }
                ForEach(runtime.plugins) { plugin in
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text(plugin.manifest.name).font(.title2)
                            Text(plugin.manifest.version).font(.caption.monospaced()).foregroundStyle(.secondary)
                            Spacer()
                            Text(isAdded(plugin) ? "Added" : "Not added").font(.callout)
                        }
                        Text(plugin.message).foregroundStyle(.secondary).textSelection(.enabled)
                        brewRequirements(plugin.manifest.brew)
                        HStack {
                            if isAdded(plugin) {
                                Button("Remove", role: .destructive) {
                                    runtime.requestRemoval(pluginID: plugin.id)
                                }
                            } else {
                                Button("Add") { Task { await runtime.requestEnable(pluginID: plugin.id) } }
                            }
                        }
                        if isAdded(plugin), runtime.schema(pluginID: plugin.id) != nil {
                            DisclosureGroup("Configuration") {
                                PluginContentView(plugin: plugin, kind: .form, source: "config")
                            }
                        }
                        if plugin.lifecycle == .active {
                            if !plugin.manifest.checks.isEmpty { PluginContentView(plugin: plugin, kind: .checks, source: "checks") }
                            if !plugin.manifest.actions.isEmpty { PluginContentView(plugin: plugin, kind: .actions, source: "actions") }
                            ForEach(plugin.manifest.ui.pages.filter { $0.kind != .form }) { page in
                                DisclosureGroup(page.title) { PluginContentView(plugin: plugin, kind: page.kind, source: page.source) }
                            }
                        }
                    }
                    .padding(18).background(KiwiTheme.card, in: RoundedRectangle(cornerRadius: 14))
                }
            }.padding(28)
        }.navigationTitle("Plugins")
    }

    private func isAdded(_ plugin: PluginState) -> Bool {
        [.active, .needsSetup, .missingDependency].contains(plugin.lifecycle)
    }
}

struct PluginApprovalView: View {
    @EnvironmentObject private var runtime: HubRuntime
    let review: PluginReview
    @State private var submitting = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add \(review.name)?").font(.title2)
            Text("Plugins are trusted programs with your Mac user's access. Permission disclosures describe intent; they do not sandbox the program.")
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Version \(review.version) · \(review.license)")
                    Text("Source: \(review.fingerprint.source)").textSelection(.enabled)
                    Button("Inspect source in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: review.fingerprint.source)) }
                    Text("Content SHA-256").font(.caption).foregroundStyle(.secondary)
                    Text(review.fingerprint.contentDigest).font(.caption.monospaced()).textSelection(.enabled)
                    Text("Manifest SHA-256").font(.caption).foregroundStyle(.secondary)
                    Text(review.fingerprint.manifestDigest).font(.caption.monospaced()).textSelection(.enabled)
                    Text("Declared access").font(.headline)
                    if review.disclosures.isEmpty { Text("No access is disclosed. The program still has the user's ambient access.") }
                    ForEach(review.disclosures, id: \.self) { Text($0).textSelection(.enabled) }
                    if let plugin = runtime.plugins.first(where: { $0.id == review.pluginID }) {
                        Text("Required dependencies").font(.headline)
                        if plugin.manifest.depends.isEmpty { Text("None") }
                        ForEach(plugin.manifest.depends.keys.sorted(), id: \.self) { key in Text("\(key): \(plugin.manifest.depends[key] ?? "")") }
                        Text("Homebrew packages").font(.headline)
                        brewRequirements(plugin.manifest.brew, emptyText: "None")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Cancel", role: .cancel) { runtime.pendingReview = nil }
                Spacer()
                Button("Trust and add") {
                    submitting = true
                    Task { await runtime.approvePlugin(review); submitting = false }
                }.buttonStyle(.borderedProminent).disabled(submitting)
            }
        }.padding(28).frame(width: 600, height: 620)
    }
}

@ViewBuilder private func brewRequirements(_ packages: [String], emptyText: String = "Homebrew packages: None") -> some View {
    if packages.isEmpty {
        Text(emptyText).foregroundStyle(.secondary)
    } else {
        ForEach(packages.sorted(), id: \.self) { formula in
            let installed = BrewFormulaStatus.isInstalled(formula)
            Label("\(formula) — \(installed ? "Installed" : "Missing")",
                  systemImage: installed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(installed ? .green : .orange)
        }
    }
}
