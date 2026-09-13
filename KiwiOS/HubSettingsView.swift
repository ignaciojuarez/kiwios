import SwiftUI
import AppKit
import ServiceManagement

struct HubSettingsView: View {
    @EnvironmentObject private var runtime: HubRuntime
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var secretName = ""
    @State private var secretValue = ""
    @State private var repository = ""
    @State private var commit = ""
    @State private var pluginPath = "."
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .frame(width: 64, height: 64)
                        .accessibilityLabel("KiwiOS app icon")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Attended setup").font(.largeTitle)
                        Text("Use the web UI for day-to-day administration. These controls stay on the Mac because they can require local trust or macOS prompts.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                if let error = runtime.operationError {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(error).textSelection(.enabled)
                        Spacer()
                        Button("Dismiss") { runtime.clearError() }
                    }
                    .padding(12).background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                }
                GroupBox("Operation mode") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Mode", selection: Binding(get: { runtime.mode }, set: { mode in Task { await runtime.setMode(mode) } })) {
                            Text("Attended setup").tag(OperationMode.setup)
                            Text("Remote policy").tag(OperationMode.remote)
                        }.pickerStyle(.segmented)
                        Text("Remote policy blocks new setup prompts. Publish the browser UI through Tailscale Serve below after Doctor is ready.")
                            .foregroundStyle(.secondary)
                        Toggle("Launch KiwiOS at login", isOn: Binding(get: { loginEnabled }, set: { enabled in
                            do {
                                if enabled { try SMAppService.mainApp.register() }
                                else { try SMAppService.mainApp.unregister() }
                                loginEnabled = SMAppService.mainApp.status == .enabled
                                loginError = nil
                                Task { await runtime.refreshDoctor() }
                            } catch {
                                loginEnabled = SMAppService.mainApp.status == .enabled
                                loginError = error.localizedDescription
                                Task { await runtime.refreshDoctor() }
                            }
                        })).disabled(runtime.mode != .setup)
                        if let loginError { Text(loginError).foregroundStyle(.orange) }
                        Text("KiwiOS becomes available only after the owning user logs in and unlocks FileVault.").font(.caption)
                    }.padding(8)
                }
                RemoteAccessPanel()
                GroupBox("Doctor") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack { Text("Prompt-free prerequisite checks"); Spacer(); Button("Refresh") { Task { await runtime.refreshDoctor() } } }
                        ForEach(runtime.doctorFindings) { finding in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Image(systemName: finding.status == .passed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                        .foregroundStyle(finding.status == .passed ? .green : .orange)
                                    Text("\(finding.title) — \(finding.status.rawValue)").font(.headline)
                                    Spacer()
                                    if let destination = systemSettingsDestination(for: finding), finding.status != .passed {
                                        Button("Open System Settings") { NSWorkspace.shared.open(destination) }
                                    }
                                }
                                Text(finding.detail).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }.padding(8)
                }
                GroupBox("Development plugins") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(runtime.developmentDirectory?.path ?? "No development directory selected").textSelection(.enabled)
                        HStack {
                            Button("Choose directory…") { selectDirectory() }.disabled(runtime.mode != .setup)
                            Button("Remove directory") { Task { await runtime.setDevelopmentDirectory(nil) } }
                                .disabled(runtime.developmentDirectory == nil || runtime.mode != .setup)
                        }
                        Text("KiwiOS loads a plugin folder or its immediate plugin subfolders. Each source still requires explicit trust.").font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
                GroupBox("Named Keychain secrets") {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("Secret name declared by a plugin", text: $secretName)
                        SecureField("Secret value", text: $secretValue)
                        Button("Save secret") {
                            let name = secretName, value = secretValue
                            secretValue = ""
                            Task { await runtime.saveSecret(name: name, value: value) }
                        }.disabled(runtime.mode != .setup || secretName.isEmpty || secretValue.isEmpty)
                        Text("Only declared names are delivered to an enabled plugin. Reads never open a Keychain prompt.").font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
                repositoryInstallation
                localPluginSetup
            }.padding(28).frame(maxWidth: 900, alignment: .leading)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginEnabled = SMAppService.mainApp.status == .enabled
            Task { await runtime.refreshDoctor() }
        }
        .sheet(item: $runtime.pendingReview) { PluginApprovalView(review: $0).environmentObject(runtime) }
        .sheet(item: $runtime.pendingInstallation) { InstallationApprovalView(review: $0).environmentObject(runtime) }
        .sheet(item: $runtime.pendingRemoval) { PluginRemovalView(review: $0).environmentObject(runtime) }
        .sheet(item: $runtime.native.pendingConfirmation) { confirmation in
            VStack(alignment: .leading, spacing: 18) {
                Text(confirmation.title).font(.title2)
                if let detail = confirmation.operation.confirmationDetail { Text(detail).textSelection(.enabled) }
                Text("KiwiOS will record and run this operation after confirmation. Confirmation expires after one minute.")
                HStack {
                    Button("Cancel", role: .cancel) { Task { await runtime.cancelNativeConfirmation(confirmation) } }
                    Spacer()
                    Button("Confirm action") { Task { await runtime.confirmNativeOperation(confirmation) } }
                        .buttonStyle(.borderedProminent)
                }
            }.padding(28).frame(width: 480)
        }
    }

    private var repositoryInstallation: some View {
        GroupBox("Install or update an exact revision") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Use a public GitHub HTTPS repository and a complete commit SHA. Branches, tags, and abbreviated SHAs are not accepted.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("https://github.com/owner/repository", text: $repository)
                    .textContentType(.URL)
                TextField("40-character commit SHA", text: $commit)
                    .font(.body.monospaced())
                TextField("Plugin subfolder (use . for repository root)", text: $pluginPath)
                HStack {
                    if runtime.marketplaceBusy { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Stage for review") {
                        Task {
                            await runtime.stageInstallation(
                                repository: repository.trimmingCharacters(in: .whitespacesAndNewlines),
                                commit: commit.trimmingCharacters(in: .whitespacesAndNewlines),
                                path: pluginPath.trimmingCharacters(in: .whitespacesAndNewlines)
                            )
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(runtime.mode != .setup || runtime.marketplaceBusy
                              || repository.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || !validCommit || pluginPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if runtime.mode != .setup {
                    Text("Switch to Attended setup mode before staging or approving repository code.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }.padding(8)
        }
    }

    private var localPluginSetup: some View {
        GroupBox("Plugin trust and configuration") {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Adding trusted code, supplying write-only configuration, and removing installed data are attended operations.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reload", systemImage: "arrow.clockwise") { Task { await runtime.reload() } }
                        .labelStyle(.iconOnly).accessibilityLabel("Reload plugin sources")
                }
                if let error = runtime.discoveryError { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                if runtime.plugins.isEmpty { Text("No plugin sources are available.").foregroundStyle(.secondary) }
                ForEach(runtime.plugins) { plugin in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(plugin.manifest.name).font(.headline)
                            Text(plugin.manifest.version).font(.caption.monospaced()).foregroundStyle(.secondary)
                            Spacer()
                            Text(plugin.lifecycle.rawValue).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(plugin.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        HStack {
                            if isAdded(plugin) {
                                Button("Remove…", role: .destructive) { runtime.requestRemoval(pluginID: plugin.id) }
                                    .disabled(runtime.mode != .setup)
                            } else {
                                Button("Review and add…") { Task { await runtime.requestEnable(pluginID: plugin.id) } }
                            }
                        }
                        if isAdded(plugin), runtime.schema(pluginID: plugin.id) != nil {
                            DisclosureGroup("Configuration") {
                                PluginContentView(plugin: plugin)
                            }
                        }
                    }
                    .padding(12).background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
                if runtime.mode != .setup {
                    Text("Switch to Attended setup mode before removing a plugin or its installed data.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }.padding(8)
        }
    }

    private var validCommit: Bool {
        let value = commit.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.count == 40 && value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (65...70).contains($0.value) || (97...102).contains($0.value)
        }
    }

    private func isAdded(_ plugin: PluginState) -> Bool {
        [.active, .needsSetup, .missingDependency].contains(plugin.lifecycle)
    }
    private func selectDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select plugin directory"
        panel.begin { result in
            if result == .OK, let url = panel.url { Task { await runtime.setDevelopmentDirectory(url) } }
        }
    }
    private func systemSettingsDestination(for finding: DoctorFinding) -> URL? {
        if finding.id == "launch-at-login" {
            return URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
        }
        if finding.id.hasSuffix("/accessibility") {
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        }
        if finding.id.hasSuffix("/screen-recording") {
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        }
        return nil
    }
}
