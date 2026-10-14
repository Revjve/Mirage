// GPX routes. Speed is distance-based (see RouteWalker), so a 12-point track and a
// 1200-point one drive at the same pace.

import CoreLocation
import SwiftUI
import UniformTypeIdentifiers

struct RouteTab: View {
    @EnvironmentObject private var controller: SpoofController
    @State private var points: [CLLocationCoordinate2D] = []
    @State private var fileName = ""
    @State private var importing = false
    @State private var importError = ""

    private var metres: Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + Geo.distance($1.0, $1.1) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        Haptic.tap()
                        importing = true
                    } label: {
                        Label(points.isEmpty ? "Import GPX…" : "Replace GPX…",
                              systemImage: "square.and.arrow.down")
                    }

                    if !points.isEmpty {
                        LabeledContent("File") {
                            Text(fileName).lineLimit(1).truncationMode(.middle)
                        }
                        LabeledContent("Points") { Text("\(points.count)").numeric() }
                        LabeledContent("Distance") { Text(distanceText).numeric() }
                        LabeledContent("Duration") { Text(eta).numeric() }
                    }
                    if !importError.isEmpty {
                        Label(importError, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                } header: {
                    Text("Track")
                } footer: {
                    Text("Reads track points, then route points, then waypoints — whichever the file has first.")
                }

                Section("Speed") {
                    SpeedControl()
                        .padding(.vertical, 4)
                    Toggle("Loop at the end", isOn: $controller.loopRoute)
                }

                Section {
                    if controller.mode == .moving {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: controller.progress).tint(.green)
                            Text("\(Int(controller.progress * 100))% complete")
                                .font(.caption).numeric().foregroundStyle(.secondary)
                        }
                        Button(role: .destructive) {
                            Haptic.tap(.medium)
                            Task { await controller.stop() }
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }
                    } else {
                        Button {
                            Haptic.tap(.medium)
                            controller.startRoute(points,
                                                  speedKmh: controller.speedKmh,
                                                  loop: controller.loopRoute)
                        } label: {
                            Label("Drive this track", systemImage: "play.fill")
                        }
                        .disabled(points.count < 2 || controller.busy)
                    }
                } footer: {
                    Text("Keep Mirage in the foreground. iOS suspends the one-second tick in the background and the route stalls.")
                }

                Section {
                    Text("To build a route by tapping instead — with roads followed properly — use the Drive panel on the Location tab.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Routes")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { StatusPill() } }
            .fileImporter(isPresented: $importing,
                          allowedContentTypes: [UTType(filenameExtension: "gpx") ?? .xml, .xml]) { result in
                load(result)
            }
        }
    }

    private var distanceText: String {
        controller.useMPH
            ? String(format: "%.2f mi", metres / 1609.344)
            : String(format: "%.2f km", metres / 1000)
    }

    private var eta: String {
        let seconds = metres / max(0.1, controller.speedKmh * 1000 / 3600)
        let minutes = Int((seconds / 60).rounded())
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }

    private func load(_ result: Result<URL, Error>) {
        importError = ""
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let parsed = GPXReader.read(try Data(contentsOf: url))
            guard parsed.count >= 2 else {
                importError = "No track, route or waypoints with 2+ points in that file."
                Haptic.notify(.error)
                return
            }
            points = parsed
            fileName = url.lastPathComponent
            Haptic.notify(.success)
        } catch {
            importError = error.localizedDescription
            Haptic.notify(.error)
        }
    }
}
