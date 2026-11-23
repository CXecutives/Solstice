import Foundation

/// The sample world the screenshots show (Screens.swift): two Macs, the one used last with a long name with umlauts,
/// and a pairing file. Written into the app's own storage before the app reads it, so the real code loads it.
enum Sample {
    static let release = MacOSRelease.current

    static let hero = VirtualMac(id: UUID(uuidString: "5A3F0C1E-7B2D-4C11-9E55-000000000001")!, name: "Büro-Mac für Präsentationen",
                                 ecid: 0x5A3F_0C1E_7B2D, seed: 1, ramMB: 6144, diskBytes: 64 << 30, osName: release.name,
                                 lastUsed: Date().addingTimeInterval(-2 * 3600), screenPreset: .recommended, cpuCount: 4)
    static let other = VirtualMac(id: UUID(uuidString: "5A3F0C1E-7B2D-4C11-9E55-000000000002")!, name: "Test Mac",
                                  ecid: 0x5A3F_0C1E_7B2E, seed: 2, ramMB: 4096, diskBytes: 64 << 30, osName: release.name,
                                  lastUsed: Date().addingTimeInterval(-26 * 3600), screenPreset: .moreSpace)

    /// The two Macs, each with a small disk and a picture of its screen (the engine stub's placeholder).
    static func writeMacs() {
        let fm = FileManager.default
        for mac in [hero, other] {
            try? fm.createDirectory(at: mac.directory, withIntermediateDirectories: true)
            fm.createFile(atPath: mac.disk.path, contents: Data(count: 8 << 20))
            MacPreview.saveNow(for: mac)
        }
        if let data = try? JSONEncoder().encode([hero, other]) {
            try? data.write(to: Machines.root.appendingPathComponent("machines.json"), options: .atomic)
        }
    }

    /// A pairing file as a computer makes one (keys of the right size; nothing real).
    static func writePairing() {
        let plist: [String: Any] = ["public_key": Data(repeating: 1, count: 32), "private_key": Data(repeating: 2, count: 32),
                                    "identifier": "00000000-0000-4000-8000-00000000CAFE"]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else { return }
        try? JITPairingFileStore.store(data, source: .imported)
    }

    /// An install part-way through the download, and its other moments.
    static let downloaded: Int64 = 7_350 << 20
    static let failure = "The restore stopped: the Mac did not answer in DFU mode. Try again; the download is kept."
    static let installed = "\(hero.name) is ready. Start it from Macs."
    static let bootError = "The disk image could not be opened (it may have been moved or deleted)."
    /// Storage almost full: what is left.
    static let storageFree: Int64 = 1_150 << 20
}
