import SwiftUI

struct InstallationApprovalView: View {
    @EnvironmentObject private var runtime: HubRuntime
    let review: InstallationReview
    @State private var submitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Trust and install \(review.name)?").font(.title2)
            Text("This is executable code with your Mac user's access. Disclosures describe intent and do not sandbox the plugin.")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    details
                    digest("Content SHA-256", review.contentDigest)
                    digest("Manifest SHA-256", review.manifestDigest)
                    Button("Inspect staged source in Finder", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([review.loadedPlugin.rootURL])
                    }
                    disclosureChanges
                    values("Declared access", review.permissions,
                           empty: "No access is disclosed. The program still has the user's ambient access.")
                    values("Required dependencies", review.dependencies.keys.sorted().map {
                        "\($0): \(review.dependencies[$0] ?? "")"
                    }, empty: "None")
                    values("Homebrew packages", review.brew.sorted().map {
                        "\($0) — \(BrewFormulaStatus.isInstalled($0) ? "Installed" : "Missing")"
                    }, empty: "None")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Cancel", role: .cancel) { Task { await runtime.cancelInstallation() } }
                Spacer()
                Button("Trust and install") {
                    submitting = true
                    Task { await runtime.approveInstallation(review); submitting = false }
                }
                .buttonStyle(.borderedProminent)
                .disabled(submitting || runtime.marketplaceBusy)
            }
        }
        .padding(28)
        .frame(width: 660, height: 720)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Plugin", value: "\(review.name) (\(review.pluginID))")
            LabeledContent("Version", value: review.version)
            LabeledContent("License", value: review.license)
            LabeledContent("Repository") {
                Text(review.repository).font(.caption.monospaced()).textSelection(.enabled)
            }
            LabeledContent("Commit") {
                Text(review.commit).font(.caption.monospaced()).textSelection(.enabled)
            }
            if review.pluginPath != "." { LabeledContent("Subfolder", value: review.pluginPath) }
        }
    }

    @ViewBuilder private var disclosureChanges: some View {
        if !review.permissionChanges.added.isEmpty || !review.permissionChanges.removed.isEmpty {
            Text("Changes from installed revision").font(.headline)
            ForEach(review.permissionChanges.added, id: \.self) { Text("Added: \($0)").foregroundStyle(.orange) }
            ForEach(review.permissionChanges.removed, id: \.self) { Text("Removed: \($0)").foregroundStyle(.secondary) }
        }
    }

    private func digest(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.caption.monospaced()).textSelection(.enabled)
        }
    }

    private func values(_ title: String, _ values: [String], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.headline)
            if values.isEmpty { Text(empty).foregroundStyle(.secondary) }
            ForEach(values, id: \.self) { Text($0).textSelection(.enabled) }
        }
    }
}
struct PluginRemovalView: View {
    @EnvironmentObject private var runtime: HubRuntime
    let review: PluginRemovalReview
    @State private var homebrewFormulae: Set<String>
    @State private var submitting = false

    init(review: PluginRemovalReview) {
        self.review = review
        _homebrewFormulae = State(initialValue: Set(
            review.homebrew.filter(\.canUninstall).map(\.formula)
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Remove \(review.name)?").font(.title2)
            Text("KiwiOS will stop the plugin and permanently remove its approval, configuration, secrets, data, results, job history, logs, layout, and any KiwiOS-installed code revisions.")
                .foregroundStyle(.secondary)
            if !review.homebrew.isEmpty {
                Divider()
                Text("Homebrew cleanup").font(.headline)
                ForEach(review.homebrew) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        if item.canUninstall {
                            Toggle("Also uninstall \(item.formula)", isOn: Binding(
                                get: { homebrewFormulae.contains(item.formula) },
                                set: { enabled in
                                    if enabled { homebrewFormulae.insert(item.formula) }
                                    else { homebrewFormulae.remove(item.formula) }
                                }
                            ))
                        } else {
                            Text(item.formula)
                        }
                        Text(item.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("KiwiOS checks other plugins and installed Homebrew dependents. It cannot detect unrelated scripts or projects that call these tools.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Cancel", role: .cancel) { runtime.pendingRemoval = nil }
                Spacer()
                Button("Remove plugin", role: .destructive) {
                    submitting = true
                    Task {
                        await runtime.removePlugin(review, homebrewFormulae: homebrewFormulae.sorted())
                        submitting = false
                    }
                }
                .disabled(submitting)
            }
        }
        .padding(28)
        .frame(width: 560)
    }
}
