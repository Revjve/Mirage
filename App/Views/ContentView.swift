// Four screens: the map (hold a spot or drive a route), GPX routes, the one-time
// setup, and the log you'll want when the tunnel misbehaves.

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var controller: SpoofController

    var body: some View {
        TabView {
            MapTab()
                .tabItem { Label("Location", systemImage: "map.fill") }
            RouteTab()
                .tabItem { Label("Routes", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
            SetupTab()
                .tabItem { Label("Setup", systemImage: "gearshape.fill") }
            LogTab()
                .tabItem { Label("Log", systemImage: "list.bullet.rectangle.portrait.fill") }
        }
        .tint(controller.mode.tint == .secondary ? .blue : controller.mode.tint)
    }
}

/// Shared status capsule: what the engine is doing, and whether the tunnel is up.
struct StatusPill: View {
    @EnvironmentObject private var controller: SpoofController

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: controller.mode.icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 1) {
                Text(controller.mode.title)
                    .font(.caption.weight(.semibold))
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .numeric()
                        .foregroundStyle(.secondary)
                }
            }

            if controller.busy || controller.building {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 1))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: controller.mode)
    }

    private var detail: String? {
        if !controller.lastError.isEmpty { return "error — see Log" }
        switch controller.mode {
        case .real:
            return controller.connected ? "linked" : nil
        case .holding:
            return controller.position.map { SpoofController.format($0) }
        case .moving:
            let shown = controller.useMPH
                ? Speed.mph(fromKMH: controller.speedKmh)
                : controller.speedKmh
            return String(format: "%.0f %@ · %d%%", shown, controller.speedUnit,
                          Int(controller.progress * 100))
        }
    }

    private var tint: Color {
        controller.lastError.isEmpty ? controller.mode.tint : .orange
    }
}
