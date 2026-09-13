import SwiftUI

struct NativeToolsView: View {
    let snapshot: NativeToolsSnapshot?
    let mode: OperationMode
    let peers: [NamedSSHPeer]
    let isRefreshing: Bool
    let isBusy: (NativeOperation) -> Bool
    let refresh: @MainActor () async -> Void
    let request: @MainActor (NativeOperation) -> Void
    let addPeer: @MainActor (NamedSSHPeer) async -> Bool
    let removePeer: @MainActor (NamedSSHPeer) -> Void

    @State private var addingPeer = false
    @State private var notificationTitle = "KiwiOS"
    @State private var notificationBody = "This Mac is reachable."

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Tools").font(.largeTitle)
                    Spacer()
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await refresh() } }
                        .disabled(isRefreshing)
                }
                if let snapshot {
                    power(snapshot.power)
                    processes(snapshot.processes)
                    launchAgents(snapshot.launchAgents, warning: snapshot.launchAgentWarning)
                    homebrew(snapshot.homebrew)
                    sshPeers
                    notifications(snapshot.notificationAuthorization)
                    Text("Sampled \(snapshot.sampledAt, style: .relative)")
                        .font(.caption).foregroundStyle(.secondary)
                } else if isRefreshing {
                    ProgressView("Inspecting native tools…")
                } else {
                    ContentUnavailableView("No tool status", systemImage: "wrench.and.screwdriver",
                                           description: Text("Refresh to inspect prompt-free host capabilities."))
                }
            }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Tools")
        .sheet(isPresented: $addingPeer) {
            AddSSHPeerView(save: addPeer)
        }
    }

    private func power(_ status: NativePowerStatus) -> some View {
        section("Power", icon: "power") {
            LabeledContent("Low Power Mode", value: status.lowPowerModeEnabled ? "On" : "Off")
            LabeledContent("FileVault", value: status.fileVault)
            Text(status.restartSupport).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func processes(_ processes: [NativeProcessIdentity]) -> some View {
        section("Applications", icon: "app.badge") {
            if processes.isEmpty { Text("No regular applications found").foregroundStyle(.secondary) }
            ForEach(processes) { process in
                HStack {
                    Text(process.displayName)
                    Spacer()
                    let operation = NativeOperation.terminateProcess(process)
                    Button("Quit", role: .destructive) { request(operation) }
                        .disabled(!process.canTerminate || isBusy(operation))
                        .help(process.canTerminate ? "Send SIGTERM to this application" : "Only non-Apple apps from an Applications folder are available")
                }
            }
        }
    }

    private func launchAgents(_ agents: [NativeLaunchAgent], warning: String?) -> some View {
        section("User launch agents", icon: "arrow.trianglehead.2.clockwise.rotate.90") {
            if let warning { Text(warning).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            if agents.isEmpty { Text("No owned agents in ~/Library/LaunchAgents").foregroundStyle(.secondary) }
            ForEach(agents) { agent in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(agent.label)
                            Text(agent.isLoaded.map { $0 ? "Loaded" : "Not loaded" } ?? "Unknown")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text(agent.plistPath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        if let issue = agent.issue { Text(issue).font(.caption).foregroundStyle(.orange) }
                    }
                    Spacer()
                    let operation = NativeOperation.kickstartLaunchAgent(label: agent.label)
                    Button("Restart") { request(operation) }
                        .disabled(mode == .remote || agent.issue != nil || isBusy(operation))
                }
            }
        }
    }

    private func homebrew(_ status: NativeHomebrewStatus) -> some View {
        section("Homebrew", icon: "mug") {
            switch status {
            case .unavailable:
                Text("Homebrew is not installed in a supported location").foregroundStyle(.secondary)
            case .error(let path, let message):
                Text(path).font(.caption.monospaced()).textSelection(.enabled)
                Text(message).foregroundStyle(.orange).textSelection(.enabled)
            case .available(let path, let formulae, let casks):
                Text(path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                Text("\(formulae.count) outdated formulae · \(casks.count) outdated casks")
                HStack {
                    let update = NativeOperation.homebrewUpdate
                    Button("Update metadata") { request(update) }
                        .disabled(mode == .remote || isBusy(update))
                    let packages = formulae + casks
                    let upgrade = NativeOperation.homebrewUpgrade(packages: packages)
                    Button("Upgrade listed items") { request(upgrade) }
                        .disabled(mode == .remote || packages.isEmpty || packages.count > 50 || isBusy(upgrade))
                }
                if mode == .remote {
                    Text("Homebrew changes are disabled in remote policy mode.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var sshPeers: some View {
        section("Named SSH peers", icon: "network") {
            HStack {
                Text("Checks use your Aqua user's ambient OpenSSH configuration, including keys, known-host files, proxies, forwarding, and local-command rules. Review that configuration during attended setup. KiwiOS also forces BatchMode, strict host-key checking, one attempt, and a bounded timeout.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Add peer") { addingPeer = true }.disabled(mode == .remote)
            }
            if peers.isEmpty { Text("No peers configured").foregroundStyle(.secondary) }
            ForEach(peers) { peer in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(peer.name)
                        Text("\(peer.destination):\(peer.port)").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    let operation = NativeOperation.probeSSH(peerName: peer.name)
                    Button("Check") { request(operation) }.disabled(isBusy(operation))
                    Button("Remove", role: .destructive) { removePeer(peer) }.disabled(mode == .remote)
                }
            }
        }
    }

    private func notifications(_ authorization: NativeNotificationAuthorization) -> some View {
        section("Notification outbox", icon: "bell") {
            LabeledContent("Authorization", value: authorization.rawValue)
            if authorization == .notDetermined {
                let operation = NativeOperation.requestNotificationAuthorization
                Button("Request access…") { request(operation) }
                    .disabled(mode == .remote || isBusy(operation))
            }
            TextField("Title", text: $notificationTitle)
            TextField("Message", text: $notificationBody, axis: .vertical).lineLimit(2...5)
            let operation = NativeOperation.deliverNotification(title: notificationTitle, body: notificationBody)
            Button("Send local notification") { request(operation) }
                .disabled(authorization != .authorized || isBusy(operation))
        }
    }

    private func section<Content: View>(
        _ title: String, icon: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon).font(.title2)
            content()
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(KiwiTheme.card, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct AddSSHPeerView: View {
    let save: @MainActor (NamedSSHPeer) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var destination = ""
    @State private var port = "22"
    @State private var saving = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add SSH peer").font(.title2)
            Text("Add peers while attended. KiwiOS never accepts passwords, new host keys, or device prompts during a check.")
                .foregroundStyle(.secondary)
            TextField("Name", text: $name)
            TextField("user@host", text: $destination)
                .textContentType(.URL)
            TextField("Port", text: $port)
            if let message { Text(message).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button("Add") {
                    guard let portNumber = UInt16(port), portNumber > 0 else { return }
                    saving = true
                    message = nil
                    Task {
                        if await save(NamedSSHPeer(name: name, destination: destination, port: portNumber)) {
                            dismiss()
                        } else {
                            message = "Could not save this peer. Review the reported error and try again."
                        }
                        saving = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(saving
                          || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || UInt16(port).map { $0 > 0 } != true)
            }
        }.padding(28).frame(width: 460)
    }
}
