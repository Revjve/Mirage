// Pick a spot and hold it. Tap the map or type "lat, lon" — same format locsim took.

import CoreLocation
import MapKit
import SwiftUI

struct MapTab: View {
    @EnvironmentObject private var controller: SpoofController
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var typed = ""
    @State private var pending: CLLocationCoordinate2D?

    private var target: CLLocationCoordinate2D? { pending ?? Geo.parse(typed) }

    var body: some View {
        NavigationStack {
            MapReader { proxy in
                Map(position: $camera) {
                    if controller.routePoints.count > 1 {
                        MapPolyline(coordinates: controller.routePoints)
                            .stroke(.blue.opacity(0.7), lineWidth: 4)
                    }
                    if let live = controller.position {
                        Marker("Simulated", systemImage: "location.fill", coordinate: live)
                            .tint(controller.mode == .moving ? .green : .blue)
                    }
                    if let pending, !Geo.same(pending, controller.position) {
                        Marker("Pending", systemImage: "mappin", coordinate: pending)
                            .tint(.orange)
                    }
                }
                .mapStyle(.standard(elevation: .realistic))
                .onTapGesture { point in
                    guard let spot = proxy.convert(point, from: .local) else { return }
                    pending = spot
                    typed = SpoofController.format(spot)
                }
            }
            .safeAreaInset(edge: .top) {
                StatusPill().padding(.top, 4)
            }
            .safeAreaInset(edge: .bottom) { controls }
            .navigationTitle("Location")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            if !controller.lastError.isEmpty {
                Text(controller.lastError)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                TextField("40.6892, -74.0445", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                    .onSubmit(teleport)
                    .onChange(of: typed) { _, new in
                        // Typing overrides a tapped pin, but don't fight the user mid-edit.
                        if let parsed = Geo.parse(new) { pending = parsed }
                    }

                Button("Go", action: teleport)
                    .buttonStyle(.borderedProminent)
                    .disabled(target == nil || controller.busy)
            }

            HStack(spacing: 8) {
                Button {
                    if let spot = controller.position ?? target {
                        camera = .region(MKCoordinateRegion(
                            center: spot,
                            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)))
                    }
                } label: {
                    Label("Recenter", systemImage: "scope")
                }
                .buttonStyle(.bordered)
                .disabled(controller.position == nil && target == nil)

                Spacer()

                Button(role: .destructive) {
                    Task { await controller.stop() }
                } label: {
                    Label("Real GPS", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .disabled(controller.mode == .real)
            }
        }
        .padding(12)
        .background(.bar)
    }

    private func teleport() {
        guard let target else { return }
        pending = target
        Task { await controller.teleport(to: target) }
    }
}
