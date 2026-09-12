import SwiftUI

@main
struct KiwiOSApp: App {
    @StateObject private var runtime = HubRuntime()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(runtime)
        }
        .defaultSize(width: 1100, height: 720)
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified(showsTitle: true))
    }
}
