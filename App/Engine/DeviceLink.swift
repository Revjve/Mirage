// DeviceLink: the on-phone version of what locsim does from the PC.
//
// Chain (same as Vanish / StikDebug, all inside this app):
//   LocalDevVPN loopback (10.7.0.1)  ->  RemotePairing tunnel (port 49152, pairing file)
//     ->  RSD handshake  ->  Developer Disk Image mounted  ->  DVT "LocationSimulation" channel
//
// Every call here blocks, so SpoofController only calls it from its own serial queue.

import Darwin
import Foundation
// Upstream names the module IDevice (capital I, capital D) in swift/include/module.modulemap,
// and ships libplist as a *separate* module — plist_t / plist_free / plist_get_uint_val
// below come from that one, not from IDevice.
import IDevice
import plist

struct LinkError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// Unchecked because the pointers below aren't thread-safe on their own: safety comes
// from SpoofController only ever touching a DeviceLink from its single serial queue.
final class DeviceLink: @unchecked Sendable {
    private var adapter: OpaquePointer?
    private var handshake: OpaquePointer?
    private var remoteServer: OpaquePointer?
    private var locationSim: OpaquePointer?

    var isOpen: Bool { locationSim != nil }

    deinit { close() }

    // MARK: Connection

    func open(pairingFile: URL, address: String, ddiFolder: URL, useCryptex: Bool, log: (String) -> Void) throws {
        close()
        do {
            try openTunnel(pairingFile: pairingFile, address: address)
            log("Tunnel up")
            if try isDDIMounted() {
                log("Developer disk image already mounted")
            } else {
                log("Mounting developer disk image…")
                try mountDDI(folder: ddiFolder, useCryptex: useCryptex)
                log("Developer disk image mounted")
            }
            try openLocationChannel()
            log("Location channel open")
        } catch {
            close()
            throw error
        }
    }

    func close() {
        // The location client borrows the remote server, so free it first.
        if let locationSim { location_simulation_free(locationSim) }
        if let remoteServer { remote_server_free(remoteServer) }
        if let handshake { rsd_handshake_free(handshake) }
        if let adapter { adapter_free(adapter) }
        locationSim = nil
        remoteServer = nil
        handshake = nil
        adapter = nil
    }

    // MARK: Location

    func set(latitude: Double, longitude: Double) throws {
        guard let locationSim else { throw LinkError(message: "Not connected") }
        try check(location_simulation_set(locationSim, latitude, longitude), "Set location")
    }

    func clear() throws {
        guard let locationSim else { throw LinkError(message: "Not connected") }
        try check(location_simulation_clear(locationSim), "Clear location")
    }

    // MARK: Steps

    private func openTunnel(pairingFile: URL, address: String) throws {
        var pairing: OpaquePointer?
        try check(rp_pairing_file_read(pairingFile.path, &pairing), "Read pairing file")
        guard let pairing else { throw LinkError(message: "Pairing file could not be read") }
        defer { rp_pairing_file_free(pairing) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(49152).bigEndian
        guard inet_pton(AF_INET, address, &addr.sin_addr) == 1 else {
            throw LinkError(message: "\(address) isn't a valid IPv4 address")
        }

        var newAdapter: OpaquePointer?
        var newHandshake: OpaquePointer?
        let err = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                tunnel_create_rppairing($0, socklen_t(MemoryLayout<sockaddr_in>.size), "Mirage",
                                        pairing, nil, nil, &newAdapter, &newHandshake)
            }
        }
        try check(err, "Connect through LocalDevVPN")
        guard newAdapter != nil, newHandshake != nil else {
            if let newHandshake { rsd_handshake_free(newHandshake) }
            if let newAdapter { adapter_free(newAdapter) }
            throw LinkError(message: "Tunnel came up without handles")
        }
        adapter = newAdapter
        handshake = newHandshake
    }

    private func openLocationChannel() throws {
        var server: OpaquePointer?
        try check(remote_server_connect_rsd(adapter, handshake, &server), "Open instruments service")
        var sim: OpaquePointer?
        if let err = location_simulation_new(server, &sim) {
            remote_server_free(server)
            try check(err, "Open location simulation")
        }
        remoteServer = server
        locationSim = sim
    }

    private func isDDIMounted() throws -> Bool {
        // iOS 26.4+ installs the image as a cryptex.
        var installed: UnsafeMutablePointer<InstalledCryptexC>?
        let cryptexErr = cryptexd_installed_ddi(adapter, handshake, &installed)
        defer { cryptexd_free_installed_cryptex(installed) }
        if installed != nil { return true }
        if let cryptexErr { idevice_error_free(cryptexErr) }

        var mounter: OpaquePointer?
        try check(image_mounter_connect_rsd(adapter, handshake, &mounter), "Open image mounter")
        defer { image_mounter_free(mounter) }
        var devices: UnsafeMutablePointer<plist_t?>?
        var count = 0
        try check(image_mounter_copy_devices(mounter, &devices, &count), "List mounted images")
        if let devices {
            for i in 0..<count { plist_free(devices[i]) }
            idevice_data_free(UnsafeMutableRawPointer(devices).assumingMemoryBound(to: UInt8.self),
                              UInt(count * MemoryLayout<plist_t?>.stride))
        }
        return count > 0
    }

    private func mountDDI(folder: URL, useCryptex: Bool) throws {
        if useCryptex {
            var assets: OpaquePointer?
            try check(cryptex1_assets_load(folder.path, &assets), "Load disk image")
            defer { cryptex1_assets_free(assets) }
            var installed: UnsafeMutablePointer<InstalledCryptexC>?
            try check(cryptexd_install_ddi(adapter, handshake, assets, &installed), "Install disk image")
            cryptexd_free_installed_cryptex(installed)
            return
        }

        let image = try Data(contentsOf: folder.appendingPathComponent("Image.dmg"), options: .mappedIfSafe)
        let trustcache = try Data(contentsOf: folder.appendingPathComponent("Image.dmg.trustcache"))
        let manifest = try Data(contentsOf: folder.appendingPathComponent("BuildManifest.plist"))

        // Personalized images are signed by Apple for this exact chip.
        var lockdown: OpaquePointer?
        try check(lockdownd_connect_rsd(adapter, handshake, &lockdown), "Open lockdown")
        defer { lockdownd_client_free(lockdown) }
        var chipPlist: plist_t?
        try check(lockdownd_get_value(lockdown, "UniqueChipID", nil, &chipPlist), "Read chip ID")
        defer { plist_free(chipPlist) }
        var chipID: UInt64 = 0
        plist_get_uint_val(chipPlist, &chipID)
        guard chipID != 0 else { throw LinkError(message: "Couldn't read the phone's chip ID") }

        var mounter: OpaquePointer?
        try check(image_mounter_connect_rsd(adapter, handshake, &mounter), "Open image mounter")
        defer { image_mounter_free(mounter) }
        let err = image.withUnsafeBytes { img in
            trustcache.withUnsafeBytes { tc in
                manifest.withUnsafeBytes { bm in
                    image_mounter_mount_personalized_rsd(
                        mounter, adapter, handshake,
                        img.bindMemory(to: UInt8.self).baseAddress, image.count,
                        tc.bindMemory(to: UInt8.self).baseAddress, trustcache.count,
                        bm.bindMemory(to: UInt8.self).baseAddress, manifest.count,
                        nil, chipID)
                }
            }
        }
        try check(err, "Mount disk image")
    }

    private func check(_ err: UnsafeMutablePointer<IdeviceFfiError>?, _ step: String) throws {
        guard let err else { return }
        let detail = err.pointee.message.map { String(cString: $0) } ?? "error \(err.pointee.code)"
        idevice_error_free(err)
        throw LinkError(message: "\(step): \(detail)")
    }
}
