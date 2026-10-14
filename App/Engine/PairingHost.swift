// Generates a pairing file on-device, so StikPair isn't needed.
//
// Mirage plays the part of a pairing *host* — the role a Mac normally fills. The flow,
// mirroring idevice's own tools/src/pair_host.rs reference implementation:
//
//   pairable_host_prepare()            -> host identity + mDNS TXT records
//   bind a TCP listener on any port
//   advertise _remotepairing-pairable-host._tcp with those TXT records
//   the DEVICE discovers us and connects, driving the rppairing conversation
//   pairable_host_accept_fd(fd)        -> the pairing file
//   rp_pairing_file_write(path)        -> Application Support/Pairing/
//
// Everything here blocks, so the whole run happens on a background queue.

import Foundation
import IDevice

/// Box so the C PIN callback can reach a Swift closure through its void* context.
private final class PinBox {
    let onPin: (String) -> Void
    init(_ onPin: @escaping (String) -> Void) { self.onPin = onPin }
}

private let pinTrampoline: @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = { pin, ctx in
    guard let pin, let ctx else { return }
    Unmanaged<PinBox>.fromOpaque(ctx).takeUnretainedValue().onPin(String(cString: pin))
}

@MainActor
final class PairingHost: ObservableObject {
    enum State: Equatable {
        case idle
        case waiting(service: String, port: UInt16)
        case pin(String)
        case paired
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private let queue = DispatchQueue(label: "mirage.pairing", qos: .userInitiated)
    private var advertisement: NetService?
    private var listenerFD: Int32 = -1

    var isRunning: Bool {
        switch state {
        case .waiting, .pin: return true
        default: return false
        }
    }

    // MARK: Run

    func start() {
        guard !isRunning else { return }
        state = .idle

        var handle: OpaquePointer?
        var serviceIDPtr: UnsafeMutablePointer<CChar>?
        var txtPtr: UnsafeMutablePointer<UInt8>?
        var txtLen = 0

        // nil model falls back to idevice's own default ("Mac17,7"); pinless pairing
        // avoids making the user transcribe a code when the device doesn't demand one.
        let err = pairable_host_prepare("Mirage", nil, true,
                                        &handle, &serviceIDPtr, &txtPtr, &txtLen, nil)
        if let message = Self.message(err) {
            return fail("Prepare pairing host: \(message)")
        }
        guard let handle, let serviceIDPtr else {
            return fail("Pairing host prepared without a handle")
        }

        let serviceID = String(cString: serviceIDPtr)
        idevice_string_free(serviceIDPtr)

        let txt: [String: String]
        if let txtPtr {
            txt = Self.parseTXT(Data(bytes: txtPtr, count: txtLen))
            idevice_data_free(txtPtr, UInt(txtLen))
        } else {
            txt = [:]
        }

        // Bind before advertising so the real port can be published.
        guard let port = openListener() else {
            pairable_host_free(handle)
            return fail("Couldn't open a listening socket")
        }

        advertise(serviceID: serviceID, port: port, txt: txt)
        state = .waiting(service: serviceID, port: port)

        let listener = listenerFD
        queue.async { [weak self] in
            // accept() blocks until the device dials in, or until stop() closes the fd.
            let client = accept(listener, nil, nil)
            guard client >= 0 else {
                Task { @MainActor in
                    if self?.isRunning == true { self?.fail("No device connected") }
                    self?.teardown(handle)
                }
                return
            }
            self?.handshake(handle: handle, clientFD: client)
        }
    }

    func stop() {
        closeListener()
        advertisement?.stop()
        advertisement = nil
        if isRunning { state = .idle }
    }

    // MARK: Steps

    private func handshake(handle: OpaquePointer, clientFD: Int32) {
        let box = PinBox { pin in
            Task { @MainActor in self.state = .pin(pin) }
        }
        let ctx = Unmanaged.passRetained(box).toOpaque()
        defer {
            Unmanaged<PinBox>.fromOpaque(ctx).release()
            close(clientFD)
        }

        var pairingFile: OpaquePointer?
        let err = pairable_host_accept_fd(handle, clientFD, pinTrampoline, ctx, nil, &pairingFile)

        if let message = Self.message(err) {
            Task { @MainActor in
                self.fail("Pairing handshake: \(message)")
                self.teardown(handle)
            }
            return
        }
        guard let pairingFile else {
            Task { @MainActor in
                self.fail("Handshake finished without a pairing file")
                self.teardown(handle)
            }
            return
        }

        let destination = PairingStore.url
        let writeErr = rp_pairing_file_write(pairingFile, destination.path)
        rp_pairing_file_free(pairingFile)

        Task { @MainActor in
            if let message = Self.message(writeErr) {
                self.fail("Saving pairing file: \(message)")
            } else {
                self.state = .paired
                Haptic.notify(.success)
            }
            self.teardown(handle)
        }
    }

    /// BSD sockets rather than Network.framework: pairable_host_accept_fd needs a raw fd,
    /// and NWConnection doesn't hand one out.
    private func openListener() -> UInt16? {
        closeListener()
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0 // kernel picks a free one
        addr.sin_addr.s_addr = INADDR_ANY

        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 1) == 0 else {
            close(fd)
            return nil
        }

        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else {
            close(fd)
            return nil
        }

        listenerFD = fd
        return UInt16(bigEndian: actual.sin_port)
    }

    private func closeListener() {
        if listenerFD >= 0 { close(listenerFD) }
        listenerFD = -1
    }

    private func advertise(serviceID: String, port: UInt16, txt: [String: String]) {
        let service = NetService(domain: "local.",
                                 type: "_remotepairing-pairable-host._tcp",
                                 name: serviceID,
                                 port: Int32(port))
        let encoded = txt.compactMapValues { $0.data(using: .utf8) }
        service.setTXTRecord(NetService.data(fromTXTRecord: encoded))
        service.publish()
        advertisement = service
    }

    private func teardown(_ handle: OpaquePointer) {
        pairable_host_free(handle)
        closeListener()
        advertisement?.stop()
        advertisement = nil
    }

    private func fail(_ message: String) {
        state = .failed(message)
        Haptic.notify(.error)
    }

    // MARK: Helpers

    /// The TXT blob comes back as an XML plist dictionary of strings.
    private static func parseTXT(_ data: Data) -> [String: String] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any] else { return [:] }
        return dict.compactMapValues { $0 as? String }
    }

    private static func message(_ err: UnsafeMutablePointer<IdeviceFfiError>?) -> String? {
        guard let err else { return nil }
        let detail = err.pointee.message.map { String(cString: $0) } ?? "error \(err.pointee.code)"
        idevice_error_free(err)
        return detail
    }
}
