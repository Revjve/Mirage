// Entry point. One controller for the whole app — the engine holds a single tunnel,
// so there's nothing to gain from more than one.

import SwiftUI

@main
struct MirageApp: App {
    @StateObject private var controller = SpoofController()
    @StateObject private var realLocation = RealLocation()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(controller)
                .environmentObject(realLocation)
        }
    }
}
