import SwiftUI
import AppKit

struct RemoteAccessPanel: View {
    @EnvironmentObject private var runtime: HubRuntime
    @State private var tailscaleState: TailscaleServeState?
    var body: some View {
        GroupBox("Tailnet browser access") {
            VStack(alignment: .leading, spacing: 12) {
                Label(runtime.remote.message, systemImage: runtime.remote.enabled ? "checkmark.circle.fill" : "network.slash")
                    .foregroundStyle(runtime.remote.enabled ? Color.green : Color.primary)
                    .textSelection(.enabled)
                if let origin = runtime.remote.origin {
                    Link("Open KiwiOS in your browser", destination: origin)
                    Text(origin.absoluteString).font(.caption.monospaced()).textSelection(.enabled)
                }
                if !runtime.remote.enabled {
                    readiness
                }
                Text("KiwiOS binds only to loopback and manages one tailnet-only Tailscale Serve origin. Your Tailscale policy determines which human identities can administer this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    if runtime.remote.desired {
                        Button("Stop remote access", role: .destructive) { Task { await runtime.stopRemoteAccess() } }
                            .disabled(runtime.remote.starting || runtime.remote.stopping)
                    } else {
                        Button("Enable through Tailscale Serve") {
                            Task {
                                await runtime.refreshDoctor()
                                await inspectTailscale()
                                await runtime.startRemoteAccess()
                            }
                        }
                        .disabled(runtime.remote.starting || runtime.remote.stopping || !doctorReady || hasPendingOperations || !tailscaleReady)
                    }
                    if runtime.remote.starting || runtime.remote.stopping { ProgressView().controlSize(.small) }
                }
                Text("Local recovery stays available when Tailscale is offline. After a cold FileVault restart, somebody must unlock and log in to the Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(8)
        }
        .task {
            if runtime.doctorFindings.isEmpty { await runtime.refreshDoctor() }
            await inspectTailscale()
        }
    }

    private var doctorReady: Bool {
        DoctorReadiness.hostIsReady(runtime.doctorFindings)
    }

    private var hasPendingOperations: Bool {
        runtime.jobs.contains { !$0.status.isTerminal }
    }

    private var tailscaleReady: Bool {
        guard let tailscaleState else { return false }
        return switch tailscaleState.status {
        case .available(_), .managed(_): true
        case .unavailable(_), .conflict(_): false
        }
    }

    @ViewBuilder private var readiness: some View {
        VStack(alignment: .leading, spacing: 7) {
            ReadinessRow(ready: doctorReady, text: doctorReady ? "Doctor checks passed" : "Resolve Doctor findings first")
            ReadinessRow(ready: !hasPendingOperations,
                text: hasPendingOperations ? "Finish or cancel pending operations" : "No pending operations")
            if let tailscaleState {
                switch tailscaleState.status {
                case .available(let origin):
                    ReadinessRow(ready: true, text: "Tailscale is ready at \(origin.host ?? origin.absoluteString)")
                case .managed(let origin):
                    ReadinessRow(ready: true, text: "KiwiOS manages Serve at \(origin.host ?? origin.absoluteString)")
                case .unavailable(let detail):
                    ReadinessRow(ready: false, text: detail)
                case .conflict(let detail):
                    ReadinessRow(ready: false, text: detail)
                }
            } else {
                ReadinessRow(ready: false, text: "Checking Tailscale…")
            }
            HStack {
                Button("Refresh readiness") {
                    Task {
                        await runtime.refreshDoctor()
                        await inspectTailscale()
                    }
                }
                if FileManager.default.fileExists(atPath: "/Applications/Tailscale.app") {
                    Button("Open Tailscale") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Tailscale.app"))
                    }
                } else if needsTailscaleInstallation {
                    Link("Get Tailscale", destination: URL(string: "https://tailscale.com/download/mac")!)
                } else if tailscaleState?.unavailability == .loggedOut {
                    Text("Sign in with the Tailscale CLI, then refresh.").font(.caption)
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func inspectTailscale() async {
        tailscaleState = await runtime.inspectRemoteReadiness()
    }

    private var needsTailscaleInstallation: Bool {
        tailscaleState?.unavailability == .executableMissing
    }
}

private struct ReadinessRow: View {
    let ready: Bool
    let text: String
    var body: some View {
        Label(text, systemImage: ready ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(ready ? Color.secondary : Color.orange)
            .textSelection(.enabled)
    }
}
