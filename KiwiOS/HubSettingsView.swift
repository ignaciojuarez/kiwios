import SwiftUI
import AppKit
import ServiceManagement

struct HubSettingsView: View {
    @EnvironmentObject private var runtime: HubRuntime
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var secretName = ""
    @State private var secretValue = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Settings").font(.largeTitle)
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
                GroupBox("Sidebar pages") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(runtime.plugins) { plugin in
                            ForEach(plugin.manifest.ui.sidebar) { item in
                                let key = "\(plugin.id)/\(item.id)"
                                HStack {
                                    Toggle("\(plugin.manifest.name): \(item.label)", isOn: Binding(get: { runtime.layout.sidebar.contains(key) }, set: { included in
                                        var layout = runtime.layout
                                        if included { layout.sidebar.append(key) } else { layout.sidebar.removeAll { $0 == key } }
                                        Task { await runtime.changeLayout(layout) }
                                    }))
                                    Button("Move up", systemImage: "arrow.up") {
                                        var layout = runtime.layout
                                        if let index = layout.sidebar.firstIndex(of: key), index > 0 { layout.sidebar.swapAt(index, index - 1) }
                                        Task { await runtime.changeLayout(layout) }
                                    }.labelStyle(.iconOnly).accessibilityLabel("Move \(item.label) up")
                                }
                            }
                        }
                    }.padding(8)
                }
            }.padding(28).frame(maxWidth: 900, alignment: .leading)
        }
        .navigationTitle("Settings")
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginEnabled = SMAppService.mainApp.status == .enabled
        }
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
