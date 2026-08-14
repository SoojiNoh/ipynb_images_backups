import SwiftUI

@main
struct AssetBridgeApp: App {

    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
        }
    }
}
