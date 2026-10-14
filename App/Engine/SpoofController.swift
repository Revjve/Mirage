// What the phone should be doing right now: real GPS, holding a spot, or driving a route.
// Mirrors locsim's Controller: re-send the held spot every few seconds (iOS drops the
// simulated fix if the channel goes quiet), reconnect with backoff when the link drops.

import CoreLocation
import Foundation
import SwiftUI

@MainActor
final class SpoofController: ObservableObject {
    enum Mode: Equatable { case real, holding, moving }

    @Published private(set) var mode: Mode = .real
    @Published private(set) var position: CLLocationCoordinate2D?
    @Published private(set) var routePoints: [CLLocationCoordinate2D] = []
    @Published private(set) var progress = 0.0
    @Published private(set) var busy = false
    @Published private(set) var building = false
    @Published private(set) var connected = false
    @Published private(set) var lastError = ""
    @Published private(set) var log: [String] = []

    /// Where we're driving to. Kept here so the map can pin it across tab switches.
    @Published var destination: CLLocationCoordinate2D?

    /// Extra waypoints for a multi-stop route (Routes tab). The common case is a single
    /// destination, which needs none of these.
    @Published var waypoints: [CLLocationCoordinate2D] = []

    // @AppStorage only republishes when it's read from inside a View, so the
    // settings the engine itself reads are kept in UserDefaults by hand.
    @Published var targetAddress: String { didSet { defaults.set(targetAddress, forKey: "targetAddress") } }
    @Published var jitter: Double { didSet { defaults.set(jitter, forKey: "jitter") } }
    @Published var speedKmh: Double { didSet { defaults.set(speedKmh, forKey: "speedKmh") } }
    @Published var loopRoute: Bool { didSet { defaults.set(loopRoute, forKey: "loopRoute") } }
    @Published var useMPH: Bool { didSet { defaults.set(useMPH, forKey: "useMPH") } }
    @Published var snapToRoads: Bool { didSet { defaults.set(snapToRoads, forKey: "snapToRoads") } }

    /// The engine is metric internally; mph is purely a presentation unit.
    var speedMPH: Double {
        get { Speed.mph(fromKMH: speedKmh) }
        set { speedKmh = Speed.kmh(fromMPH: newValue) }
    }

    var speedDisplay: Double {
        get { useMPH ? speedMPH : speedKmh }
        set { if useMPH { speedMPH = newValue } else { speedKmh = newValue } }
    }

    var speedUnit: String { useMPH ? "mph" : "km/h" }
    /// Generous upper bound so highway speeds are reachable in either unit.
    var speedRange: ClosedRange<Double> { useMPH ? 1...120 : 1...193 }

    static let heartbeatSeconds = 4.0
    static let tickSeconds = 1.0
    private static let maxBackoff = 30.0
    private static let logLimit = 300

    private let defaults = UserDefaults.standard
    private let link = DeviceLink()
    private let linkQueue = DispatchQueue(label: "mirage.link", qos: .userInitiated)
    private var heartbeat: Task<Void, Never>?
    private var route: Task<Void, Never>?
    private var failures = 0

    init() {
        targetAddress = defaults.string(forKey: "targetAddress") ?? "10.7.0.1"
        jitter = defaults.object(forKey: "jitter") as? Double ?? 0.1
        // ~30 mph: a driving default, since that's the common case.
        speedKmh = defaults.object(forKey: "speedKmh") as? Double ?? 48
        loopRoute = defaults.bool(forKey: "loopRoute")
        useMPH = defaults.object(forKey: "useMPH") as? Bool ?? true
        snapToRoads = defaults.object(forKey: "snapToRoads") as? Bool ?? true
    }

    // MARK: Waypoints

    func addWaypoint(_ coordinate: CLLocationCoordinate2D) {
        waypoints.append(coordinate)
    }

    func removeLastWaypoint() {
        guard !waypoints.isEmpty else { return }
        waypoints.removeLast()
    }

    func clearWaypoints() {
        waypoints = []
        if mode != .moving { routePoints = [] }
    }

    /// Snap the tapped waypoints to roads (if asked) and start driving them.
    func driveWaypoints() async {
        guard waypoints.count >= 2 else { return fail("Tap at least 2 points on the map") }

        var points = waypoints
        if snapToRoads {
            building = true
            note("Snapping \(waypoints.count) waypoints to roads…")
            do {
                points = try await Routing.drivingRoute(through: waypoints)
                note("Road route: \(points.count) points")
            } catch {
                building = false
                return fail(error.localizedDescription)
            }
            building = false
        }
        startRoute(points, speedKmh: speedKmh, loop: loopRoute)
    }

    /// The main flow: route from where you are to a destination along real roads, drive
    /// it at the set speed, then hold at the far end.
    ///
    /// `loop` is forced off — arriving and staying put is the whole point, and
    /// startRoute() already switches to .holding with a heartbeat when a route finishes.
    func driveTo(_ target: CLLocationCoordinate2D, from origin: CLLocationCoordinate2D) async {
        destination = target
        building = true
        note("Routing to \(Self.format(target))…")
        do {
            let points = snapToRoads
                ? try await Routing.drivingRoute(through: [origin, target])
                : [origin, target]
            building = false
            startRoute(points, speedKmh: speedKmh, loop: false)
        } catch {
            building = false
            fail(error.localizedDescription)
        }
    }

    // MARK: Public actions

    func teleport(to coordinate: CLLocationCoordinate2D) async {
        stopRoute()
        guard await send(coordinate) else { return }
        mode = .holding
        startHeartbeat()
        note("Holding \(Self.format(coordinate))")
    }

    func startRoute(_ points: [CLLocationCoordinate2D], speedKmh: Double, loop: Bool) {
        guard points.count >= 2 else { return fail("A route needs at least 2 points") }
        stopRoute()
        heartbeat?.cancel()
        heartbeat = nil
        mode = .moving
        progress = 0
        routePoints = points

        // Distance per tick, not per route point, so speed is independent of how
        // finely the route happens to be sampled.
        let metresPerTick = max(0.1, speedKmh) * 1000 / 3600 * Self.tickSeconds
        let walkerSource = RouteWalker(points: points)
        note(String(format: "Driving %.2f km at %.0f %@%@",
                    walkerSource.total / 1000,
                    useMPH ? Speed.mph(fromKMH: speedKmh) : speedKmh,
                    speedUnit,
                    loop ? ", looping" : ""))

        route = Task { [weak self] in
            var walker = walkerSource
            while !Task.isCancelled {
                guard let self else { return }

                // Jitter keeps the trace from looking metronomic.
                let wobble = self.jitter > 0 ? 1 + Double.random(in: -self.jitter...self.jitter) : 1
                walker.advance(metres: metresPerTick * max(0, wobble))

                let delivered = await self.send(walker.position)
                if Task.isCancelled { return }
                self.progress = walker.progress

                if !delivered {
                    // send() already logged and bumped the backoff; wait it out and retry
                    // the same position rather than silently skipping ahead.
                    try? await Task.sleep(for: .seconds(self.backoffDelay))
                    continue
                }

                if walker.finished {
                    if loop {
                        walker = walkerSource
                        self.note("Route complete — looping")
                    } else {
                        self.note("Route complete")
                        self.mode = .holding
                        self.startHeartbeat()
                        Haptic.notify(.success)
                        return
                    }
                }
                try? await Task.sleep(for: .seconds(Self.tickSeconds))
            }
        }
    }

    /// Hand control back to the phone's real GPS, but keep the tunnel up.
    func stop() async {
        stopRoute()
        heartbeat?.cancel()
        heartbeat = nil
        if await linkIsOpen() {
            do {
                try await perform { try $0.clear() }
                note("Back to real GPS")
            } catch {
                fail(error.localizedDescription)
            }
        }
        mode = .real
        position = nil
        progress = 0
        routePoints = []
    }

    /// Tear the whole chain down. The DDI stays mounted until the phone reboots.
    func disconnect() async {
        await stop()
        await run { $0.close() }
        connected = false
        failures = 0
        note("Disconnected")
    }

    func clearLog() { log = [] }

    // MARK: Plumbing

    private func stopRoute() {
        route?.cancel()
        route = nil
    }

    private func startHeartbeat() {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.heartbeatSeconds))
                guard let self, !Task.isCancelled,
                      self.mode == .holding, let spot = self.position else { return }
                _ = await self.send(spot)
            }
        }
    }

    /// One location update, bringing the link up first if it isn't already.
    private func send(_ coordinate: CLLocationCoordinate2D) async -> Bool {
        do {
            try await ensureConnected()
            try await perform { try $0.set(latitude: coordinate.latitude, longitude: coordinate.longitude) }
            position = coordinate
            if !lastError.isEmpty { lastError = "" }
            failures = 0
            return true
        } catch {
            failures += 1
            fail(error.localizedDescription)
            // Drop the handles so the next attempt rebuilds the tunnel from scratch.
            await run { $0.close() }
            connected = false
            return false
        }
    }

    private var backoffDelay: Double {
        min(Self.maxBackoff, pow(2, Double(max(0, failures - 1))))
    }

    private func ensureConnected() async throws {
        if await linkIsOpen() {
            connected = true
            return
        }
        guard PairingStore.exists else {
            throw LinkError(message: "No pairing file yet — add one in Setup")
        }
        guard DDIStore.isReady else {
            throw LinkError(message: "Developer disk image missing — download it in Setup")
        }

        busy = true
        defer { busy = false }
        if failures > 0 {
            note(String(format: "Reconnecting in %.0fs (attempt %d)", backoffDelay, failures + 1))
            try? await Task.sleep(for: .seconds(backoffDelay))
        } else {
            note("Connecting to \(targetAddress)…")
        }

        let address = targetAddress
        let folder = DDIStore.folder
        let cryptex = DDIStore.useCryptex
        let pairing = PairingStore.url

        try await perform { [weak self] device in
            try device.open(pairingFile: pairing, address: address,
                            ddiFolder: folder, useCryptex: cryptex) { message in
                Task { @MainActor in self?.note(message) }
            }
        }
        connected = true
        note("Connected")
    }

    private func linkIsOpen() async -> Bool {
        await run { $0.isOpen }
    }

    // MARK: Queue bridge

    // Every idevice call blocks, so it runs on linkQueue and never on the main actor.
    // DeviceLink is only ever touched from that one serial queue.

    private func perform<T: Sendable>(_ work: @escaping @Sendable (DeviceLink) throws -> T) async throws -> T {
        let device = link
        return try await withCheckedThrowingContinuation { continuation in
            linkQueue.async {
                do { continuation.resume(returning: try work(device)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    // Deliberately a different name, not an overload: `run { $0.close() }` and
    // `perform { try $0.clear() }` would be ambiguous to overload resolution.
    private func run<T: Sendable>(_ work: @escaping @Sendable (DeviceLink) -> T) async -> T {
        let device = link
        return await withCheckedContinuation { continuation in
            linkQueue.async { continuation.resume(returning: work(device)) }
        }
    }

    // MARK: Log

    private func fail(_ message: String) {
        lastError = message
        note("⚠︎ \(message)")
        Haptic.notify(.error)
    }

    private func note(_ message: String) {
        log.append("[\(Date().formatted(date: .omitted, time: .standard))] \(message)")
        if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit) }
    }

    static func format(_ c: CLLocationCoordinate2D) -> String {
        String(format: "%.5f, %.5f", c.latitude, c.longitude)
    }
}
