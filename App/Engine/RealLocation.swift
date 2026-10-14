// The phone's own location, used as the starting point for a drive.
//
// Important: once Mirage is simulating, CoreLocation reports the SIMULATED position —
// that's the whole point of the DVT channel, it replaces location system-wide. So
// `origin` latches the last fix seen while the engine was idle, which is the last
// genuinely real one.

import CoreLocation

final class RealLocation: NSObject, ObservableObject, CLLocationManagerDelegate {
    /// Whatever iOS currently believes: real GPS when idle, the simulated spot when active.
    @Published private(set) var current: CLLocationCoordinate2D?
    /// Last fix observed while not spoofing — the honest one.
    @Published private(set) var origin: CLLocationCoordinate2D?
    @Published private(set) var status: CLAuthorizationStatus

    /// Set by the controller so we know whether an incoming fix is real or simulated.
    var spoofing = false

    private let manager = CLLocationManager()

    override init() {
        status = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
    }

    var denied: Bool { status == .denied || status == .restricted }

    func start() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        manager.startUpdatingLocation()
    }

    // Delegate callbacks arrive on the queue the manager was created on — the main
    // thread here — so publishing directly is safe.

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        current = last.coordinate
        if !spoofing { origin = last.coordinate }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        status = manager.authorizationStatus
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Transient (no fix yet, airplane mode). Nothing to do but wait for the next one.
    }
}
