// Files the engine needs on the phone: the pairing file and Apple's Developer Disk Image.

import Foundation
import UniformTypeIdentifiers

enum PairingStore {
    static let fileName = "pairingFile.plist"

    /// pair_phone.py drops the file into Documents (Files app → On My iPhone → Mirage also works);
    /// we keep a private copy in Application Support.
    static var url: URL {
        let dir = URL.applicationSupportDirectory.appendingPathComponent("Pairing", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    static var exists: Bool {
        adoptFromDocuments()
        return FileManager.default.fileExists(atPath: url.path)
    }

    static let contentTypes: [UTType] = [
        .propertyList,
        UTType(filenameExtension: "mobiledevicepairing", conformingTo: .data) ?? .data,
    ]

    static func importFile(from source: URL) throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        try replace(url, with: Data(contentsOf: source))
    }

    /// Pick up a newer file that was pushed into Documents.
    static func adoptFromDocuments() {
        let dropped = URL.documentsDirectory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: dropped), data != (try? Data(contentsOf: url)) else { return }
        try? replace(url, with: data)
    }

    private static func replace(_ destination: URL, with data: Data) throws {
        try data.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

enum DDIStore {
    static let folder = URL.applicationSupportDirectory.appendingPathComponent("DDI", isDirectory: true)

    /// Same rule StikDebug uses: iOS 26.4+ needs the cryptex form of the image.
    static var useCryptex: Bool {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.majorVersion > 26 || (v.majorVersion == 26 && v.minorVersion >= 4)
    }

    private static var variant: String { useCryptex ? "Xcode_iOS_DDI_Cryptex" : "Xcode_iOS_DDI_Personalized" }

    private static var fileNames: [String] {
        ["BuildManifest.plist", "Image.dmg", "Image.dmg.trustcache"]
            + (useCryptex ? ["Image.dmg.cryptex_info", "Image.dmg.root_hash"] : [])
    }

    private static var markerURL: URL { folder.appendingPathComponent("variant") }

    static var isReady: Bool {
        (try? String(contentsOf: markerURL, encoding: .utf8)) == variant
            && fileNames.allSatisfy { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }

    /// Downloads Apple's image from doronz88/DeveloperDiskImage (the source StikDebug and Vanish use). ~20 MB, once.
    static func download(progress: @escaping (String) -> Void) async throws {
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = "https://github.com/doronz88/DeveloperDiskImage/raw/refs/heads/main/PersonalizedImages/\(variant)/"
        for (i, name) in fileNames.enumerated() {
            progress("Downloading \(name) (\(i + 1)/\(fileNames.count))")
            let (tmp, response) = try await URLSession.shared.download(from: URL(string: base + name)!)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw LinkError(message: "Download of \(name) failed")
            }
            try FileManager.default.moveItem(at: tmp, to: folder.appendingPathComponent(name))
        }
        try variant.write(to: markerURL, atomically: true, encoding: .utf8)
        progress("Disk image ready")
    }
}
