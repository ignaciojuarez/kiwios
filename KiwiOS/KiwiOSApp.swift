import SwiftUI
import AppKit

@main
struct KiwiOSApp: App {
    @NSApplicationDelegateAdaptor(HubAppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(delegate.runtime)
        } label: {
            Image(systemName: "circle.grid.2x2.fill")
                .accessibilityLabel("KiwiOS")
        }

        Settings {
            HubSettingsView()
                .environmentObject(delegate.runtime)
                .frame(minWidth: 620, minHeight: 640)
                .preferredColorScheme(.dark)
                .tint(Color(red: 0.72, green: 0.95, blue: 0.29))
        }
    }
}

@MainActor
final class HubAppDelegate: NSObject, NSApplicationDelegate {
    let runtime = HubRuntime()

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await runtime.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

private struct MenuBarContent: View {
    @EnvironmentObject private var runtime: HubRuntime
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(status)
        Text(detail)
        Divider()
        Button("Open Web UI") {
            if let origin = runtime.remote.origin { NSWorkspace.shared.open(origin) }
        }
        .disabled(!runtime.remote.enabled || runtime.remote.origin == nil)
        Button("Attended Setup…") {
            openSettings()
            DispatchQueue.main.async {
                NSApp.activate()
                NSApp.windows.first(where: {
                    $0.isVisible && $0.canBecomeKey && !($0 is NSPanel)
                })?.makeKeyAndOrderFront(nil)
            }
        }
        Divider()
        Button("Quit KiwiOS") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var status: String {
        if runtime.operationError != nil || runtime.discoveryError != nil { return "KiwiOS needs attention" }
        if runtime.remote.desired && !runtime.remote.enabled {
            return runtime.remote.starting ? "KiwiOS is connecting" : "KiwiOS web UI unavailable"
        }
        if runtime.jobs.contains(where: { !$0.status.isTerminal }) { return "KiwiOS is working" }
        if runtime.remote.enabled { return "KiwiOS is online" }
        return "KiwiOS is running"
    }

    private var detail: String {
        if runtime.operationError != nil || runtime.discoveryError != nil { return "Open Attended Setup for details" }
        if let origin = runtime.remote.origin { return origin.host ?? origin.absoluteString }
        if runtime.remote.desired { return "Open Attended Setup to inspect remote access" }
        return "\(runtime.plugins.filter { $0.lifecycle == .active }.count) active plugins"
    }
}
