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
                .frame(minWidth: 860, minHeight: 640)
        }
        .commands {
            CommandGroup(replacing: .newItem) {} // single-window controller; no "New"
        }
    }
}
