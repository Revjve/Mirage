// Turns tapped waypoints into something that follows actual roads.
//
// MKDirections is part of MapKit, so there's no API key and no account: it returns the
// same driving geometry Maps would. Without this, a two-tap "route" is a straight line
// that cuts through buildings, which reads as obviously synthetic.

import CoreLocation
import MapKit

enum Routing {
    /// Road-following driving geometry through every waypoint, in order.
    ///
    /// One MKDirections request per leg, because a single request takes only a source and
    /// a destination. Apple throttles these, so legs run sequentially rather than in
    /// parallel — a dozen waypoints is fine, hundreds is not the intended use.
    static func drivingRoute(through waypoints: [CLLocationCoordinate2D]) async throws -> [CLLocationCoordinate2D] {
        guard waypoints.count >= 2 else {
            throw LinkError(message: "A route needs at least 2 points")
        }

        var combined: [CLLocationCoordinate2D] = []
        for (index, pair) in zip(waypoints, waypoints.dropFirst()).enumerated() {
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: pair.0))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: pair.1))
            request.transportType = .automobile
            request.requestsAlternateRoutes = false

            let leg: MKRoute
            do {
                guard let first = try await MKDirections(request: request).calculate().routes.first else {
                    throw LinkError(message: "No road route for leg \(index + 1)")
                }
                leg = first
            } catch let error as LinkError {
                throw error
            } catch {
                // Usually "no route between these points" — e.g. across water, or a tap
                // in the middle of the ocean.
                throw LinkError(message: "Leg \(index + 1): \(error.localizedDescription)")
            }

            let coordinates = leg.polyline.coordinates
            // Drop the shared vertex so the seam between legs isn't a duplicate point.
            combined.append(contentsOf: combined.isEmpty ? coordinates : Array(coordinates.dropFirst()))
        }
        return combined
    }

    /// Resolve a typed place name to a coordinate, so a destination can be an address
    /// rather than a pair of decimals.
    static func locate(_ query: String, near region: MKCoordinateRegion?) async throws -> CLLocationCoordinate2D {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let region { request.region = region }
        let response = try await MKLocalSearch(request: request).start()
        guard let item = response.mapItems.first else {
            throw LinkError(message: "Couldn't find that place")
        }
        return item.placemark.coordinate
    }
}

extension MKPolyline {
    var coordinates: [CLLocationCoordinate2D] {
        var result = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: pointCount)
        getCoordinates(&result, range: NSRange(location: 0, length: pointCount))
        return result
    }
}

enum Speed {
    static let kmhPerMPH = 1.609344

    static func kmh(fromMPH mph: Double) -> Double { mph * kmhPerMPH }
    static func mph(fromKMH kmh: Double) -> Double { kmh / kmhPerMPH }
}
