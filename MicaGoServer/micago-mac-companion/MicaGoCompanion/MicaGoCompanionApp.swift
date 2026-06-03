import SwiftUI

@main
struct MicaGoCompanionApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("MicaGo Companion") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 580, minHeight: 680)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {} // single-window controller; no "New"
        }
    }
}
