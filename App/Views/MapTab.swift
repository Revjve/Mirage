// The main screen. Map runs full-bleed under the Dynamic Island with the controls
// floating in glass above the home indicator, so the cartography is never letterboxed.
//
// Two panels: Hold pins one spot, Drive builds a route by tapping and then drives it.

import CoreLocation
import MapKit
import SwiftUI

struct MapTab: View {
    enum Panel: String, CaseIterable, Identifiable {
        case hold = "Hold", drive = "Drive"
        var id: Self { self }
        var icon: String { self == .hold ? "mappin.circle.fill" : "car.fill" }
    }

    @EnvironmentObject private var controller: SpoofController
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var panel: Panel = .hold
    @State private var typed = ""
    @State private var pending: CLLocationCoordinate2D?

    private var target: CLLocationCoordinate2D? { pending ?? Geo.parse(typed) }

    var body: some View {
        MapReader { proxy in
            map
                .onTapGesture { point in
                    guard let spot = proxy.convert(point, from: .local) else { return }
                    handleTap(spot)
                }
        }
        .ignoresSafeArea()
        .safeAreaInset(edge: .top) { statusBar }
        .safeAreaInset(edge: .bottom) { controls }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: panel)
        .animation(.default, value: controller.waypoints.count)
    }

    // MARK: Map

    private var map: some View {
        Map(position: $camera) {
            // The driven polyline, once it exists.
            if controller.routePoints.count > 1 {
                MapPolyline(coordinates: controller.routePoints)
                    .stroke(.blue.gradient, style: .init(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }

            // The raw tapped waypoints, dashed — visibly provisional until snapped.
            if controller.waypoints.count > 1, controller.routePoints.isEmpty {
                MapPolyline(coordinates: controller.waypoints)
                    .stroke(.orange.opacity(0.8), style: .init(lineWidth: 3, lineCap: .round, dash: [8, 6]))
            }

            ForEach(Array(controller.waypoints.enumerated()), id: \.offset) { item in
                Annotation("", coordinate: item.element) {
                    WaypointPin(number: item.offset + 1)
                }
            }

            if let live = controller.position {
                Annotation("", coordinate: live) {
                    LivePin(moving: controller.mode == .moving)
                }
            }

            if let pending, !Geo.same(pending, controller.position), panel == .hold {
                Annotation("", coordinate: pending) {
                    WaypointPin(number: nil)
                }
            }
        }
        .mapStyle(.standard(elevation: .realistic))
        .annotationTitles(.hidden)
        .mapControls {
            MapCompass()
            MapScaleView()
        }
    }

    // MARK: Top status

    private var statusBar: some View {
        HStack {
            StatusPill()
            Spacer(minLength: 0)
            if controller.mode != .real {
                Button {
                    Haptic.tap()
                    Task { await controller.stop() }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.red.gradient, in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, 4)
    }

    // MARK: Bottom controls

    private var controls: some View {
        GlassCard {
            VStack(spacing: 14) {
                Picker("Panel", selection: $panel) {
                    ForEach(Panel.allCases) { Label($0.rawValue, systemImage: $0.icon).tag($0) }
                }
                .pickerStyle(.segmented)

                if !controller.lastError.isEmpty {
                    Label(controller.lastError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                switch panel {
                case .hold: holdPanel
                case .drive: drivePanel
                }
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.bottom, 6)
    }

    private var holdPanel: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "mappin.and.ellipse").foregroundStyle(.secondary)
                TextField("40.6892, -74.0445", text: $typed)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                    .font(.callout.monospaced())
                    .onSubmit(teleport)
                    .onChange(of: typed) { _, new in
                        if let parsed = Geo.parse(new) { pending = parsed }
                    }
                if !typed.isEmpty {
                    Button { typed = ""; pending = nil } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: Metrics.innerCorner, style: .continuous))

            Text("Or tap anywhere on the map")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            HStack(spacing: 10) {
                Button { recenter() } label: {
                    Image(systemName: "scope")
                }
                .buttonStyle(SubtleActionStyle())
                .disabled(controller.position == nil && target == nil)

                Button("Hold this spot", action: teleport)
                    .buttonStyle(PrimaryActionStyle(tint: .blue, enabled: target != nil && !controller.busy))
                    .disabled(target == nil || controller.busy)
            }
        }
    }

    private var drivePanel: some View {
        VStack(spacing: 14) {
            SpeedControl()

            // Waypoint tally + edit affordances
            HStack(spacing: 10) {
                Label("\(controller.waypoints.count) waypoint\(controller.waypoints.count == 1 ? "" : "s")",
                      systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(controller.waypoints.count >= 2 ? .primary : .secondary)

                Spacer(minLength: 0)

                Button { Haptic.tap(); controller.removeLastWaypoint() } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(SubtleActionStyle())
                .disabled(controller.waypoints.isEmpty)

                Button { Haptic.tap(); controller.clearWaypoints() } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(SubtleActionStyle())
                .disabled(controller.waypoints.isEmpty)
            }

            if controller.waypoints.count < 2 {
                Text("Tap the map to drop waypoints, then drive them.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 16) {
                Toggle(isOn: $controller.snapToRoads) {
                    Text("Follow roads").font(.footnote)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)

                Toggle(isOn: $controller.loopRoute) {
                    Text("Loop").font(.footnote)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
            }

            if controller.mode == .moving {
                VStack(spacing: 6) {
                    ProgressView(value: controller.progress)
                        .tint(.green)
                    HStack {
                        Text("\(Int(controller.progress * 100))%").numeric()
                        Spacer()
                        Text(remaining)
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                }
                Button(role: .destructive) {
                    Haptic.tap(.medium)
                    Task { await controller.stop() }
                } label: {
                    Label("Stop driving", systemImage: "stop.fill")
                }
                .buttonStyle(PrimaryActionStyle(tint: .red))
            } else {
                Button {
                    Haptic.tap(.medium)
                    Task { await controller.driveWaypoints() }
                } label: {
                    if controller.building {
                        Label("Snapping to roads…", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    } else {
                        Label("Drive route", systemImage: "play.fill")
                    }
                }
                .buttonStyle(PrimaryActionStyle(
                    tint: .green,
                    enabled: controller.waypoints.count >= 2 && !controller.building))
                .disabled(controller.waypoints.count < 2 || controller.building)
            }
        }
    }

    // MARK: Behaviour

    private var remaining: String {
        let total = zip(controller.routePoints, controller.routePoints.dropFirst())
            .reduce(0) { $0 + Geo.distance($1.0, $1.1) }
        let left = total * (1 - controller.progress)
        let seconds = left / max(0.1, controller.speedKmh * 1000 / 3600)
        let minutes = Int((seconds / 60).rounded())
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) m left" : "\(minutes) min left"
    }

    private func handleTap(_ spot: CLLocationCoordinate2D) {
        Haptic.tap()
        switch panel {
        case .hold:
            pending = spot
            typed = SpoofController.format(spot)
        case .drive:
            controller.addWaypoint(spot)
        }
    }

    private func teleport() {
        guard let target else { return }
        Haptic.tap(.medium)
        pending = target
        Task { await controller.teleport(to: target) }
    }

    private func recenter() {
        guard let spot = controller.position ?? target else { return }
        withAnimation {
            camera = .region(MKCoordinateRegion(
                center: spot,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)))
        }
    }
}

// MARK: - Pins

private struct WaypointPin: View {
    let number: Int?

    var body: some View {
        ZStack {
            Circle().fill(.orange.gradient)
            Circle().strokeBorder(.white, lineWidth: 2)
            if let number {
                Text("\(number)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 26, height: 26)
        .shadow(radius: 3, y: 1)
    }
}

private struct LivePin: View {
    let moving: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill((moving ? Color.green : .blue).opacity(0.25))
                .frame(width: pulse ? 44 : 28, height: pulse ? 44 : 28)
            Circle()
                .fill((moving ? Color.green : .blue).gradient)
                .frame(width: 18, height: 18)
            Circle().strokeBorder(.white, lineWidth: 2.5).frame(width: 18, height: 18)
        }
        .shadow(radius: 4, y: 1)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}
