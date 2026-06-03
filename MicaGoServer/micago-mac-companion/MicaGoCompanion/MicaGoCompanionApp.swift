import SwiftUI

@main
struct MicaGoCompanionApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var runtime = RuntimeMonitor()

    var body: some Scene {
        WindowGroup("MicaGo Companion") {
            ContentView()
                .environmentObject(model)
                .environmentObject(runtime)
        }
        // Give the main window a concrete default size and a centered position so
        // it always appears (avoids a zero-size / off-screen restored frame after
        // the layout changed to NavigationSplitView). Resizable down to the
        // content's minimum.
        .defaultSize(width: 1000, height: 720)
        .defaultPosition(.center)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {} // single-window controller; no "New"
        }
    }
}
