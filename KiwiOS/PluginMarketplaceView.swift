import SwiftUI
import AppKit

struct PluginMarketplaceView: View {
    @EnvironmentObject private var runtime: HubRuntime
    @State private var query = ""
    @State private var repository = ""
    @State private var commit = ""
    @State private var pluginPath = "."
    @State private var selectedCuratedEntry: CuratedPluginEntry?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Plugin marketplace").font(.largeTitle)
                        Text("Discover source on GitHub, then review and trust one exact commit.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if runtime.marketplaceBusy { ProgressView().controlSize(.small) }
                }
                installed
                installForm
                reviewedCommits
                communityResults
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Marketplace")
    }

    private var installed: some View {
        marketplaceSection("Installed revisions", icon: "shippingbox") {
            if runtime.installedRecords.isEmpty {
                Text("No repository plugins are installed.").foregroundStyle(.secondary)
            }
            ForEach(runtime.installedRecords.values.sorted(by: { $0.name < $1.name }), id: \.id) { record in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(record.name).font(.headline)
                        Text(record.version).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Spacer()
                        Button("Update") {
                            repository = record.sourceRepository ?? ""
                            commit = ""
                            pluginPath = "."
                            selectedCuratedEntry = nil
                        }
                        Button("Remove", role: .destructive) { runtime.requestRemoval(pluginID: record.id) }
                    }
                    if let source = record.sourceRepository {
                        Text(source).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if let sha = record.sourceCommit {
                        Text(sha).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                .padding(12)
                .background(KiwiTheme.bg.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
            }
            HStack {
                Text("KiwiOS can revisit package cleanup left by a removed plugin.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Review package cleanup…") { runtime.requestManagedHomebrewCleanup() }
                    .disabled(runtime.marketplaceBusy || runtime.mode == .remote)
            }
        }
    }

    private var installForm: some View {
        marketplaceSection("Install an exact revision", icon: "square.and.arrow.down") {
            Text("Installation accepts public GitHub HTTPS repositories. Branches, tags, and abbreviated SHAs are not accepted.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("https://github.com/owner/repository", text: $repository)
                .textContentType(.URL)
            TextField("40-character commit SHA", text: $commit)
                .font(.body.monospaced())
            TextField("Plugin subfolder (use . for repository root)", text: $pluginPath)
            if matchingCuratedEntry != nil {
                Label("Selected reviewed catalog revision", systemImage: "checkmark.seal")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Stage for review") {
                    Task {
                        if let entry = matchingCuratedEntry {
                            await runtime.stageCuratedInstallation(entry)
                        } else {
                            await runtime.stageInstallation(
                                repository: repository.trimmingCharacters(in: .whitespacesAndNewlines),
                                commit: commit.trimmingCharacters(in: .whitespacesAndNewlines),
                                path: pluginPath.trimmingCharacters(in: .whitespacesAndNewlines)
                            )
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(runtime.marketplaceBusy || repository.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || !validCommit
                          || pluginPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var reviewedCommits: some View {
        marketplaceSection("Reviewed commits", icon: "checkmark.seal") {
            Text("These exact commits are listed in KiwiOS's bundled catalog. Review the source and trust sheet before installing.")
                .font(.caption).foregroundStyle(.secondary)
            if runtime.curatedEntries.isEmpty {
                Text("No reviewed commits are published in this build.").foregroundStyle(.secondary)
            }
            ForEach(runtime.curatedEntries) { entry in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(entry.name).font(.headline)
                            Text(entry.version).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Text(entry.repository).font(.caption.monospaced()).textSelection(.enabled)
                        Text(entry.commit).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        Text("License \(entry.license) · API \(entry.kiwiosAPI)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Select") {
                        selectedCuratedEntry = entry
                        repository = entry.repository
                        commit = entry.commit
                        pluginPath = entry.path
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    private var communityResults: some View {
        marketplaceSection("Community discovery", icon: "globe") {
            Text("Results are unreviewed GitHub repositories with the kiwios-plugin topic. Stars indicate interest, not trust.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Search repositories", text: $query)
                    .onSubmit { search() }
                Button("Search") { search() }.disabled(runtime.marketplaceBusy)
            }
            if runtime.marketplaceResults.isEmpty {
                Text("Search GitHub when you want to browse community plugins.").foregroundStyle(.secondary)
            }
            ForEach(runtime.marketplaceResults) { result in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(result.owner)/\(result.name)").font(.headline)
                        if let description = result.description, !description.isEmpty {
                            Text(description).foregroundStyle(.secondary).lineLimit(3)
                        }
                        Text("\(result.stars) stars · updated \(result.updatedAt, style: .relative)")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(result.repository).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    Spacer()
                    Button("Select") {
                        selectedCuratedEntry = nil
                        repository = result.repository
                        commit = ""
                        pluginPath = "."
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    private func search() {
        Task { await runtime.searchPlugins(query) }
    }

    private var validCommit: Bool {
        let value = commit.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.count == 40 && value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (65...70).contains($0.value) || (97...102).contains($0.value)
        }
    }

    private var matchingCuratedEntry: CuratedPluginEntry? {
        guard let entry = selectedCuratedEntry,
              repository.trimmingCharacters(in: .whitespacesAndNewlines) == entry.repository,
              commit.trimmingCharacters(in: .whitespacesAndNewlines) == entry.commit,
              pluginPath.trimmingCharacters(in: .whitespacesAndNewlines) == entry.path else { return nil }
        return entry
    }

    private func marketplaceSection<Content: View>(
        _ title: String, icon: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon).font(.title2)
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KiwiTheme.card, in: RoundedRectangle(cornerRadius: 14))
    }
}

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
