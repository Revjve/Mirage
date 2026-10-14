// Four screens: where to go, a route to walk, the one-time setup, and the log
// you'll actually need when the tunnel misbehaves.

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var controller: SpoofController

    var body: some View {
        TabView {
            MapTab()
                .tabItem { Label("Location", systemImage: "mappin.and.ellipse") }
            RouteTab()
                .tabItem { Label("Route", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
            SetupTab()
                .tabItem { Label("Setup", systemImage: "gearshape") }
            LogTab()
                .tabItem { Label("Log", systemImage: "list.bullet.rectangle") }
        }
    }
}

/// Shared status line: what the engine is doing and whether the tunnel is up.
struct StatusPill: View {
    @EnvironmentObject private var controller: SpoofController

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tint)
                .frame(width: 9, height: 9)
                .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 0.5))
            Text(label)
                .font(.footnote.weight(.medium))
            if controller.busy {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar, in: Capsule())
        .overlay(Capsule().stroke(.separator, lineWidth: 0.5))
    }

    private var label: String {
        switch controller.mode {
        case .real: return controller.connected ? "Real GPS · linked" : "Real GPS"
        case .holding: return controller.position.map { "Holding \(SpoofController.format($0))" } ?? "Holding"
        case .moving: return "Moving · \(Int(controller.progress * 100))%"
        }
    }

    private var tint: Color {
        if !controller.lastError.isEmpty { return .orange }
        switch controller.mode {
        case .real: return .secondary
        case .holding: return .blue
        case .moving: return .green
        }
    }
}
