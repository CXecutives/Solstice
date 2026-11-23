import Foundation
import UIKit

/// A macOS restore image Apple publishes for virtual Macs (VirtualMac2,1).
struct MacOSRelease {
    let id: String        // build
    let name: String
    let url: URL
    let bytes: Int64
    let note: String
    /// The image's SHA-256, checked as it downloads (each download logs the hash it computed). nil: not checked.
    var sha256: String? = nil
    /// Room the new Mac takes once installed and set up, with a margin for its first updates and caches
    /// (installed and set up on the Mac in phone mode: Sonoma 21 GB, Ventura 19 GB).
    var macBytes: Int64 = 24 << 30

    /// The build Solstice installs: Sequoia 15.6.1, the one the engine and its display fixes are proven on (the refresh
    /// time at display +0x68, #161, is what macOS 15 reads there; macOS 27 uses that offset for something else).
    /// Apple's catalog (mesu.apple.com) only lists the newest; this is the same image from Apple's CDN, and Apple
    /// still signs it for virtual Macs.
    static let current = MacOSRelease(
        id: "24G90", name: "macOS Sequoia 15.6.1",
        url: URL(string: "https://updates.cdn-apple.com/2025SummerFCS/fullrestores/093-10809/CFD6DD38-DAF0-40DA-854F-31AAD1294C6F/UniversalMac_15.6.1_24G90_Restore.ipsw")!,
        bytes: 16_035 << 20, note: "The version Solstice is built and tuned for.",
        // Hashed from Apple's CDN (16,814,137,790 bytes) and the same in the public IPSW catalogue.
        sha256: "3d87686b691ac765eb6a6b3082b2334e2af9710096a00432dd519af89ff2ea78")
}

/// Downloads a restore image and installs it on a new virtual Mac, on the
/// iPhone: the machine boots its ROM in DFU mode and the restore runs over its
/// USB port, as Virtualization.framework's installer does on a Mac.
@MainActor
final class Installer: NSObject, ObservableObject {
    static let shared = Installer()

    enum Phase: Equatable {
        case idle
        case checking
        case downloading
        case preparing
        case waitingForJIT // downloaded and prepared; the restore needs JIT
        case installing
        case done(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var received: Int64 = 0
    @Published private(set) var expected: Int64 = 0
    @Published private(set) var step: Int = 0
    @Published private(set) var stepProgress: Double = 0
    @Published private(set) var machineName = ""
    /// The Mac an install just made, for the app to start at once (#183 lets it start in the same launch).
    @Published var justInstalled: VirtualMac?

    /* Background time, so a moment out of the foreground (a notification, iPhone Mirroring reconnecting)
       does not suspend the restore at once; iOS gives about 30 s. */
    private var grace = UIBackgroundTaskIdentifier.invalid

    var busy: Bool {
        switch phase {
        case .checking, .downloading, .preparing, .waitingForJIT, .installing: return true
        default: return false
        }
    }

    nonisolated static var imageDirectory: URL { Machines.root.appendingPathComponent("Restore images", isDirectory: true) }
    nonisolated static func imagePath(_ r: MacOSRelease) -> URL { imageDirectory.appendingPathComponent("\(r.id).ipsw") }

    /// The size of the image on this iPhone, if a whole one is there (the listed sizes are rounded).
    static func imageSize(_ r: MacOSRelease) -> Int64? {
        let values = try? imagePath(r).resourceValues(forKeys: [.fileSizeKey])
        guard let size = values?.fileSize, Int64(size) > r.bytes / 2 else { return nil }
        return Int64(size)
    }

    static func haveImage(_ r: MacOSRelease) -> Bool { imageSize(r) != nil }

    static func deleteImage(_ r: MacOSRelease) {
        try? FileManager.default.removeItem(at: imagePath(r))
        try? FileManager.default.removeItem(at: partPath(r))
    }
    /// Where a download in progress (or stopped partway) is kept.
    nonisolated static func partPath(_ r: MacOSRelease) -> URL { imageDirectory.appendingPathComponent("\(r.id).ipsw.part") }
    /// Bytes of a download that stopped partway, or nil.
    static func partSize(_ r: MacOSRelease) -> Int64? {
        let n = RangedDownload.size(of: partPath(r))
        return n > 0 ? n : nil
    }

    /// Free space an install takes: the new Mac's disk, and the download if it is not here yet.
    static func spaceNeeded(_ r: MacOSRelease) -> Int64 { (haveImage(r) ? 0 : max(r.bytes - (partSize(r) ?? 0), 0)) + r.macBytes }

    func reset() { if !busy { phase = .idle } }

    private func endGrace() {
        guard grace != .invalid else { return }
        UIApplication.shared.endBackgroundTask(grace)
        grace = .invalid
    }

    func start(_ release: MacOSRelease, name: String, ramMB: Int, keepImage: Bool) {
        guard !busy else { return }
        phase = .checking
        machineName = name
        UIApplication.shared.isIdleTimerDisabled = true // the screen locking would suspend the download and the restore
        grace = UIApplication.shared.beginBackgroundTask(withName: "Solstice install") {
            MainActor.assumeIsolated { Installer.shared.endGrace() }
        }
        Task {
            defer { UIApplication.shared.isIdleTimerDisabled = false; endGrace() }
            var made: VirtualMac?
            do {
                try checkSpace(release)
                let rom = try await BootROM.file() // before the long download, so a problem shows up at once
                HengeLog.log("install", "boot ROM ready")
                let ipsw = try await download(release)
                phase = .preparing
                var mac = try prepare(name: name, ramMB: ramMB, rom: rom, diskBytes: Self.diskBytes(freeing: keepImage ? 0 : release.bytes))
                mac.osName = release.name
                made = mac
                // The download needs no JIT; the restore does. Wait for it here instead of refusing at the start.
                if !JITBootstrap.ready {
                    phase = .waitingForJIT
                    HengeLog.log("install", "downloaded; waiting for JIT before the restore")
                    while !JITBootstrap.ready { try await Task.sleep(nanoseconds: 1_000_000_000) }
                }
                phase = .installing
                try await install(mac, ipsw: ipsw)
                if !keepImage { Self.deleteAfterInstall(ipsw) }
                HengeLog.log("install", "\(name): installed \(release.name)")
                phase = .done("\(release.name) is installed on \(name). Starting it now.")
                justInstalled = Machines.shared.all.first { $0.id == mac.id } ?? mac
            } catch {
                HengeLog.log("install", "failed: \(error.localizedDescription)")
                // The restore machine goes first (#183 releases it), so a retry can start in this launch.
                if henge_vm_state() == HENGE_VM_RUNNING { await Task.detached { henge_vm_stop() }.value }
                // A half-installed Mac is no use, and its disk can be many gigabytes. The download stays.
                if let made { try? FileManager.default.removeItem(at: made.directory) }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// The restore image once the Mac is installed, and what that gave back (said in the log either way).
    private static func deleteAfterInstall(_ ipsw: URL) {
        let size = RangedDownload.size(of: ipsw)
        do {
            try FileManager.default.removeItem(at: ipsw)
            HengeLog.log("install", "deleted the restore image: \(ByteText.string(UInt64(max(size, 0)))) freed")
        } catch {
            HengeLog.log("install", "the restore image (\(ByteText.string(UInt64(max(size, 0))))) was not deleted: \(error.localizedDescription)")
        }
    }

    private func checkSpace(_ r: MacOSRelease) throws {
        let free = (try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        let needed = Self.spaceNeeded(r)
        if free > 0 && free < needed {
            throw message("This install needs about \(ByteText.string(UInt64(needed))) free; this \(Device.name) has \(ByteText.string(UInt64(free))).")
        }
    }

    // MARK: Download

    private func download(_ r: MacOSRelease) async throws -> URL {
        let dest = Self.imagePath(r)
        try FileManager.default.createDirectory(at: Self.imageDirectory, withIntermediateDirectories: true)
        Machines.excludeFromBackup(Self.imageDirectory)
        if Self.haveImage(r) {
            HengeLog.log("install", "using the downloaded \(r.name)")
            return dest
        }
        phase = .downloading
        // Into a .part file next to where it ends up: an interrupted download (no network, Henge closed or killed)
        // goes on from where it stopped next time, and Install's trash button deletes a partial one too (#58).
        let part = Self.partPath(r)
        received = RangedDownload.size(of: part)
        expected = r.bytes
        if received > 0 { HengeLog.log("install", "going on with \(r.name)'s download from \(ByteText.string(UInt64(received)))") }
        HengeLog.log("install", "downloading \(r.url.absoluteString)")
        let hash = DownloadHash()
        for attempt in 1...20 {
            let d = RangedDownload(url: r.url, part: part, hash: hash) { have, total in
                Task { @MainActor in
                    let installer = Installer.shared
                    installer.received = have
                    if total > 0 && installer.expected != total { installer.expected = total }
                }
            }
            do {
                try await d.run()
            } catch {
                if RangedDownload.storageFull(error) {
                    HengeLog.log("install", "download stopped: storage is full (\(error.localizedDescription)) at \(ByteText.string(UInt64(RangedDownload.size(of: part))))")
                    throw message("Storage is full. Make room in Settings, General, Storage, then install again: the download goes on where it stopped.")
                }
                if Task.isCancelled || attempt == 20 || !RangedDownload.retryable(error) { throw error }
                HengeLog.log("install", "download interrupted (\(error.localizedDescription)) at \(ByteText.string(UInt64(RangedDownload.size(of: part)))); going on")
                try await Task.sleep(nanoseconds: 3_000_000_000)
                continue
            }
            let digest = hash.hex
            if let want = r.sha256 {
                guard digest == want.lowercased() else {
                    HengeLog.log("install", "the download's SHA-256 is \(digest), not \(want): deleting it")
                    try? FileManager.default.removeItem(at: part)
                    throw message("The download was damaged. Try again to download it afresh.")
                }
                HengeLog.log("install", "the download's SHA-256 matches (\(digest))")
            } else {
                HengeLog.log("install", "the download's SHA-256 is \(digest) (none pinned for \(r.id) yet)")
            }
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: part, to: dest)
            return dest
        }
        throw message("The download kept failing.")
    }


    // MARK: The new machine

    /// The Mac's disk. Its file is sparse and only grows (macOS's deletions do not shrink it), so it must never be able
    /// to fill the device: what is free once the install is done (the download deleted if it goes), less 8 GB for
    /// iOS, at most 64 GB and at least 40 GB (Sequoia takes about 26 GB set up).
    static func diskBytes(freeing: Int64) -> Int64 {
        let free = (try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        let gb: Int64 = 1 << 30
        let fits = (free + freeing - 8 * gb) / gb * gb
        return min(64 * gb, max(40 * gb, fits))
    }

    private func prepare(name: String, ramMB: Int, rom: URL, diskBytes: Int64) throws -> VirtualMac {
        // A new machine identity, as VZMacMachineIdentifier makes one: a random ECID.
        let ecid = UInt64.random(in: 1 << 40 ..< 1 << 62)
        var mac = VirtualMac(name: name, ecid: ecid, seed: 0, ramMB: ramMB, diskBytes: diskBytes)
        mac.screenPreset = .recommended
        let fm = FileManager.default
        try fm.createDirectory(at: mac.directory, withIntermediateDirectories: true)
        Machines.excludeFromBackup(Machines.root)
        try? fm.removeItem(at: mac.rom)
        try fm.copyItem(at: rom, to: mac.rom)
        guard fm.createFile(atPath: mac.disk.path, contents: nil) else { throw message("Cannot create the disk.") }
        let h = try FileHandle(forWritingTo: mac.disk)
        try h.truncate(atOffset: UInt64(diskBytes)) // sparse: blocks are only used as macOS writes them
        try h.close()
        guard henge_make_aux(mac.aux.path) == 0 else { throw message("Cannot create the auxiliary storage.") }
        let info: [String: Any] = ["name": name, "ecid": ecid, "seed": 0, "ramMB": ramMB]
        try JSONSerialization.data(withJSONObject: info).write(to: mac.directory.appendingPathComponent("machine.json"))
        HengeLog.log("install", "new machine \(name): ECID \(ecid), \(diskBytes >> 30) GB disk")
        return mac
    }

    // MARK: The restore

    private func install(_ mac: VirtualMac, ipsw: URL) async throws {
        let cpus = mac.cpus
        guard JITBootstrap.ready else { throw message("Turn on JIT first: the installer runs the Mac's own restore system, which needs it.") }
        // The restore needs 2 GB, whatever the Mac is set to use afterwards, and gets at most 4 GB: the restore system
        // caches the ~15 GB it writes, so it fills all the memory it is given, and 10 GB of a 12 GB iPhone's RAM in use
        // (it is outside Henge's footprint, so iOS does not stop it) stalls the whole phone two thirds of the way through.
        var restoring = mac
        restoring.ramMB = min(max(mac.ramMB, 2048), 4096)
        let ram = GuestMemory.prepare(restoring, cpus: cpus)
        guard ram >= 2048 else { throw message("Installing needs a few more GB of free storage for the Mac's memory.") }
        setenv("HV_WRITE_CACHE", "0", 1) // the ~15 GB the restore writes goes straight to storage (host/disk.c)
        defer { unsetenv("HV_WRITE_CACHE") } // the new Mac starts in this launch (#183): its first boot writes cached again
        let work = mac.directory.appendingPathComponent("restore", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        var buffer = [CChar](repeating: 0, count: 256)
        let rc = henge_vm_install(mac.rom.path, mac.disk.path, mac.aux.path, mac.ecid, ipsw.path, work.path, ram, Int32(cpus),
                                  &buffer, buffer.count)
        if rc != 0 { throw message(String(cString: buffer)) }
        while true {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            step = Int(henge_install_step())
            stepProgress = henge_install_progress()
            if step == 100 { break }
            if step == 101 { throw message("The restore failed. The log (Settings, or Documents/solstice.log) says why.") }
            if henge_vm_state() == HENGE_VM_STOPPED && step < 100 {
                // The restore ends with the machine restarting, and idevicerestore finishes a
                // little after; a stop with no result after that is a failure.
                for _ in 0..<90 where henge_install_step() < 100 { try await Task.sleep(nanoseconds: 1_000_000_000) }
                if henge_install_step() == 100 { break }
                throw message("The machine stopped during the restore (\(String(cString: henge_vm_exit_reason()))).")
            }
        }
        // In the list before anything else: stopping the restore system can take a while, and if Henge is
        // stopped meanwhile (the phone locked) a finished Mac must not be left on the disk unlisted.
        try? (mac.osName ?? "").write(to: mac.directory.appendingPathComponent(Machines.installedMarker), atomically: true, encoding: .utf8)
        Machines.shared.add(mac)
        HengeLog.log("install", "\(mac.name): restore finished, added to the Macs")
        // Off the main thread: a stop that takes long there is a hang to iOS, which closes apps that hang.
        if henge_vm_state() == HENGE_VM_RUNNING { await Task.detached { henge_vm_stop() }.value }
        try? FileManager.default.removeItem(at: work)
    }

    static func stepName(_ step: Int) -> String {
        switch step {
        case 0: return "Finding the Mac"
        case 1: return "Starting the installer"
        case 2: return "Writing macOS"
        case 3: return "Checking macOS"
        case 4: return "Installing firmware"
        case 6, 7: return "Installing system files"
        default: return "Installing"
        }
    }

    private func message(_ text: String) -> NSError {
        NSError(domain: "Solstice", code: 2, userInfo: [NSLocalizedDescriptionKey: text])
    }
}

#if SOLSTICE_SCREENS
extension Installer {
    /// The simulator app for screenshots (ios/Screens): an install at this point.
    func screens(_ phase: Phase, received: Int64 = 0, expected: Int64 = 0, step: Int = 0, stepProgress: Double = 0,
                 machineName: String) {
        self.phase = phase
        self.received = received
        self.expected = expected
        self.step = step
        self.stepProgress = stepProgress
        self.machineName = machineName
    }
}
#endif

