import SwiftUI
import AppKit

@main
struct KiwiOSApp: App {
    @NSApplicationDelegateAdaptor(HubAppDelegate.self) private var delegate
    @StateObject private var runtime = HubRuntime()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(runtime)
                .onAppear { delegate.runtime = runtime }
        }
        .defaultSize(width: 1100, height: 720)
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified(showsTitle: true))
    }
}

@MainActor
final class HubAppDelegate: NSObject, NSApplicationDelegate {
    weak var runtime: HubRuntime?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let runtime else { return .terminateNow }
        Task {
            await runtime.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
