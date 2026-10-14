// The main screen: see where you are, set a destination, drive there on roads at the
// speed you pick, then stay put.
//
// LAYOUT NOTE — this is what was broken before. Only the Map ignores the safe area; the
// control stack is a plain ZStack sibling, so it lays out *inside* the safe area and
// clears both the Dynamic Island and the TabView's tab bar. Applying .safeAreaInset on
// top of a view that already called .ignoresSafeArea() measures against the physical
// screen instead, which is what pushed the controls under the island and the tab bar.

import CoreLocation
import MapKit
import SwiftUI

struct MapTab: View {
    @EnvironmentObject private var controller: SpoofController
    @EnvironmentObject private var realLocation: RealLocation

    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var visibleRegion: MKCoordinateRegion?
    @State private var typed = ""
    @State private var resolving = false

    /// Drive from wherever we currently are: the simulated spot if we're holding one,
    /// otherwise the last genuinely real fix.
    private var origin: CLLocationCoordinate2D? {
        controller.position ?? realLocation.origin ?? realLocation.current
    }

    private var canDrive: Bool {
        origin != nil && (controller.destination != nil || !typed.isEmpty)
            && !controller.building && !resolving && controller.mode != .moving
    }

    var body: some View {
        ZStack {
            mapLayer

            VStack(spacing: 0) {
                StatusPill()
                Spacer(minLength: 12)
                card
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .onAppear { realLocation.start() }
        .onChange(of: controller.mode) { _, mode in
            // Tell RealLocation when fixes stop being trustworthy, so it keeps the last
            // real one as the route origin.
            realLocation.spoofing = mode != .real
        }
    }

    // MARK: Map

    private var mapLayer: some View {
        MapReader { proxy in
            Map(position: $camera) {
                // Whatever iOS currently reports — real GPS when idle, the simulated
                // position once the channel is live.
                UserAnnotation()

                if controller.routePoints.count > 1 {
                    MapPolyline(coordinates: controller.routePoints)
                        .stroke(.blue.gradient, style: .init(lineWidth: 5, lineCap: .round, lineJoin: .round))
                }

                if let destination = controller.destination {
                    Annotation("", coordinate: destination) { DestinationPin() }
                }

                if let live = controller.position {
                    Annotation("", coordinate: live) { LivePin(moving: controller.mode == .moving) }
                }
            }
            .mapStyle(.standard(elevation: .realistic))
            .mapControls { MapCompass() }
            .onMapCameraChange { context in visibleRegion = context.region }
            .onTapGesture { point in
                guard let spot = proxy.convert(point, from: .local) else { return }
                Haptic.tap()
                controller.destination = spot
                typed = SpoofController.format(spot)
            }
        }
        .ignoresSafeArea()
    }

    // MARK: Controls

    private var card: some View {
        GlassCard {
            VStack(spacing: 12) {
                destinationField

                if !controller.lastError.isEmpty {
                    Label(controller.lastError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if locationHint != nil {
                    Text(locationHint!)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                speedRow

                if controller.mode == .moving {
                    ProgressView(value: controller.progress).tint(.green)
                }

                actions
            }
        }
    }

    private var destinationField: some View {
        HStack(spacing: 8) {
            Image(systemName: "flag.checkered")
                .font(.footnote)
                .foregroundStyle(.secondary)

            TextField("Address, place, or lat, lon", text: $typed)
                .font(.callout)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit(drive)

            if !typed.isEmpty {
                Button {
                    typed = ""
                    controller.destination = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }

            Button {
                Haptic.tap()
                withAnimation { camera = .userLocation(fallback: .automatic) }
            } label: {
                Image(systemName: "location.fill").font(.footnote)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: Metrics.innerCorner, style: .continuous))
    }

    private var speedRow: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "speedometer").font(.footnote).foregroundStyle(.secondary)

                Text(controller.speedDisplay, format: .number.precision(.fractionLength(0)))
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .numeric()

                Button {
                    Haptic.tap()
                    controller.useMPH.toggle()
                } label: {
                    Text(controller.speedUnit)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)

                Stepper("") {
                    step(+1)
                } onDecrement: {
                    step(-1)
                }
                .labelsHidden()
            }

            Slider(value: Binding(get: { controller.speedDisplay },
                                  set: { controller.speedDisplay = $0 }),
                   in: controller.speedRange, step: 1)
                .tint(.green)
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            if controller.mode == .moving {
                Button(role: .destructive) {
                    Haptic.tap(.medium)
                    Task { await controller.stop() }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(PrimaryActionStyle(tint: .red))
            } else {
                Button {
                    Haptic.tap()
                    jump()
                } label: {
                    Text("Jump")
                }
                .buttonStyle(SubtleActionStyle())
                .disabled(!canDrive)

                Button {
                    Haptic.tap(.medium)
                    drive()
                } label: {
                    if controller.building || resolving {
                        Label("Routing…", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    } else {
                        Label("Drive here", systemImage: "car.fill")
                    }
                }
                .buttonStyle(PrimaryActionStyle(tint: .green, enabled: canDrive))
                .disabled(!canDrive)
            }
        }
    }

    private var locationHint: String? {
        if realLocation.denied {
            return "Location access is off — Settings › Privacy › Location Services. Without it there's no starting point to drive from."
        }
        if origin == nil { return "Waiting for a GPS fix…" }
        if controller.mode == .holding, controller.destination != nil { return "Arrived — holding this spot." }
        return nil
    }

    // MARK: Behaviour

    private func step(_ delta: Double) {
        Haptic.tap()
        let range = controller.speedRange
        controller.speedDisplay = min(range.upperBound,
                                      max(range.lowerBound, (controller.speedDisplay + delta).rounded()))
    }

    /// Resolve whatever's in the field: coordinates first, else a place-name search.
    private func resolveTarget() async -> CLLocationCoordinate2D? {
        if let parsed = Geo.parse(typed) { return parsed }
        if let pinned = controller.destination, typed.isEmpty { return pinned }
        guard !typed.isEmpty else { return controller.destination }
        resolving = true
        defer { resolving = false }
        do {
            return try await Routing.locate(typed, near: visibleRegion)
        } catch {
            return controller.destination
        }
    }

    private func drive() {
        guard let origin else { return }
        Task {
            guard let target = await resolveTarget() else { return }
            controller.destination = target
            typed = SpoofController.format(target)
            await controller.driveTo(target, from: origin)
        }
    }

    private func jump() {
        Task {
            guard let target = await resolveTarget() else { return }
            controller.destination = target
            typed = SpoofController.format(target)
            await controller.teleport(to: target)
        }
    }
}

// MARK: - Pins

private struct DestinationPin: View {
    var body: some View {
        ZStack {
            Circle().fill(.red.gradient)
            Circle().strokeBorder(.white, lineWidth: 2)
            Image(systemName: "flag.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 28, height: 28)
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
                .frame(width: pulse ? 42 : 26, height: pulse ? 42 : 26)
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
