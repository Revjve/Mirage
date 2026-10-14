// Load a GPX and walk it. Speed is metres-per-tick, so a coarse track and a dense
// one move at the same pace — see RouteWalker.

import CoreLocation
import SwiftUI
import UniformTypeIdentifiers

struct RouteTab: View {
    @EnvironmentObject private var controller: SpoofController
    @State private var points: [CLLocationCoordinate2D] = []
    @State private var fileName = ""
    @State private var importing = false
    @State private var importError = ""

    private var distanceKm: Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + Geo.distance($1.0, $1.1) } / 1000
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Track") {
                    Button {
                        importing = true
                    } label: {
                        Label(points.isEmpty ? "Import GPX…" : "Replace GPX…",
                              systemImage: "square.and.arrow.down")
                    }

                    if !points.isEmpty {
                        LabeledContent("File", value: fileName)
                        LabeledContent("Points", value: "\(points.count)")
                        LabeledContent("Distance", value: String(format: "%.2f km", distanceKm))
                        LabeledContent("Duration", value: eta)
                    }
                    if !importError.isEmpty {
                        Text(importError).font(.caption).foregroundStyle(.orange)
                    }
                }

                Section("Pace") {
                    VStack(alignment: .leading) {
                        LabeledContent("Speed", value: String(format: "%.0f km/h", controller.speedKmh))
                        Slider(value: $controller.speedKmh, in: 1...120, step: 1)
                        Text(paceHint).font(.caption2).foregroundStyle(.secondary)
                    }
                    Toggle("Loop at the end", isOn: $controller.loopRoute)
                }

                Section {
                    if controller.mode == .moving {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: controller.progress)
                            Text("\(Int(controller.progress * 100))% complete")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Button(role: .destructive) {
                            Task { await controller.stop() }
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }
                    } else {
                        Button {
                            controller.startRoute(points,
                                                  speedKmh: controller.speedKmh,
                                                  loop: controller.loopRoute)
                        } label: {
                            Label("Start walking", systemImage: "play.fill")
                        }
                        .disabled(points.count < 2 || controller.busy)
                    }
                } footer: {
                    Text("The route is re-sent once a second. Leaving Mirage suspended in the background will stall it — iOS drops the simulated fix when the channel goes quiet.")
                }
            }
            .navigationTitle("Route")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { StatusPill() } }
            .fileImporter(isPresented: $importing,
                          allowedContentTypes: [UTType(filenameExtension: "gpx") ?? .xml, .xml]) { result in
                load(result)
            }
        }
    }

    private var eta: String {
        let hours = distanceKm / max(1, controller.speedKmh)
        let minutes = Int((hours * 60).rounded())
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }

    private var paceHint: String {
        switch controller.speedKmh {
        case ..<7: return "Walking"
        case ..<20: return "Running"
        case ..<35: return "Cycling"
        default: return "Driving"
        }
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
                return
            }
            points = parsed
            fileName = url.lastPathComponent
        } catch {
            importError = error.localizedDescription
        }
    }
}
