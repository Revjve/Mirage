// Route math, ported from locsim.py so the phone moves exactly like the PC tool does.

import CoreLocation
import Foundation

enum Geo {
    /// Great-circle distance in metres.
    static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let r = 6_371_000.0
        let p1 = a.latitude * .pi / 180, p2 = b.latitude * .pi / 180
        let dp = p2 - p1, dl = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }

    /// Straight-line interpolation. Fine for route points metres-to-km apart.
    static func lerp(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, _ t: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                               longitude: a.longitude + (b.longitude - a.longitude) * t)
    }

    /// CLLocationCoordinate2D is not Equatable, and a retroactive conformance to a type
    /// from another module warns under Swift 6 — so compare the components explicitly.
    static func same(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D?) -> Bool {
        guard let b else { return false }
        return a.latitude == b.latitude && a.longitude == b.longitude
    }

    /// "40.6892, -74.0445" → coordinate. Latitude first.
    static func parse(_ text: String) -> CLLocationCoordinate2D? {
        let parts = text.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Double($0) }
        guard parts.count == 2, abs(parts[0]) <= 90, abs(parts[1]) <= 180 else { return nil }
        return CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1])
    }
}

/// Walks a polyline at a steady speed: one position per tick, each tick advancing
/// speed × tick metres (± jitter), so speed doesn't depend on how far apart the points are.
struct RouteWalker {
    let points: [CLLocationCoordinate2D]
    let segments: [Double]
    let total: Double
    private var index = 0
    private var into = 0.0
    private(set) var travelled = 0.0

    init(points: [CLLocationCoordinate2D]) {
        self.points = points
        segments = zip(points, points.dropFirst()).map { Geo.distance($0, $1) }
        total = segments.reduce(0, +)
    }

    var position: CLLocationCoordinate2D {
        let len = segments[index]
        return Geo.lerp(points[index], points[index + 1], len > 0 ? into / len : 1)
    }

    var finished: Bool { index == segments.count - 1 && into >= segments[index] }
    var progress: Double { total > 0 ? min(1, travelled / total) : 1 }

    mutating func advance(metres: Double) {
        travelled += metres
        into += metres
        while index < segments.count - 1 && into > segments[index] {
            into -= segments[index]
            index += 1
        }
        into = min(into, segments[index])
    }
}

/// Reads track points, else route points, else waypoints from a GPX file.
final class GPXReader: NSObject, XMLParserDelegate {
    private var found: [String: [CLLocationCoordinate2D]] = [:]

    static func read(_ data: Data) -> [CLLocationCoordinate2D] {
        let reader = GPXReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.parse()
        return ["trkpt", "rtept", "wpt"].lazy.compactMap { reader.found[$0] }.first { !$0.isEmpty } ?? []
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        let tag = name.split(separator: ":").last.map(String.init) ?? name
        guard ["trkpt", "rtept", "wpt"].contains(tag),
              let lat = attributes["lat"].flatMap(Double.init),
              let lon = attributes["lon"].flatMap(Double.init) else { return }
        found[tag, default: []].append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
    }
}
