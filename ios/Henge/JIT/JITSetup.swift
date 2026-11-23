// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Network
import SwiftUI
import UIKit

/// Where Built-in StikJIT's pairing file came from.
enum JITPairingSource: String {
    /// Made by Henge on this device (iOS 27, OnDevicePairing).
    case onDevice
    /// Imported from a file made on a computer.
    case imported
}

/// The RPPairing file Built-in StikJIT authenticates with. Lives in Documents,
/// so it is visible through Finder file sharing -- it is device-sensitive and
/// is only ever sent to Henge's own helper process.
enum JITPairingFileStore {
    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StikJIT", isDirectory: true)
    }
    static var url: URL { directory.appendingPathComponent("pairingFile.plist") }
    static var exists: Bool { FileManager.default.fileExists(atPath: url.path) }
    private static let sourceKey = "henge.jitPairingSource"

    static var source: JITPairingSource? {
        guard exists else { return nil }
        return UserDefaults.standard.string(forKey: sourceKey).flatMap(JITPairingSource.init(rawValue:)) ?? .imported
    }

    static func data() throws -> Data { try Data(contentsOf: url) }

    static func importFile(from source: URL) throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        try store(try Data(contentsOf: source), source: .imported)
    }

    /// Validates an RPPairing plist and makes it the pairing file.
    static func store(_ data: Data, source: JITPairingSource) throws {
        guard !data.isEmpty,
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any],
              let publicKey = dictionary["public_key"] as? Data, publicKey.count == 32,
              let privateKey = dictionary["private_key"] as? Data, privateKey.count == 32,
              let identifier = dictionary["identifier"] as? String, !identifier.isEmpty else {
            throw NSError(domain: "HengeJIT", code: 10,
                          userInfo: [NSLocalizedDescriptionKey:
                            "That is not a remote pairing file. Make one with the StikDebug pairing-file guide and try again."])
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        UserDefaults.standard.set(source.rawValue, forKey: sourceKey)
    }
}

@MainActor
final class JITCoordinator: ObservableObject {
    static let shared = JITCoordinator()

    @Published var showSetup = false
    @Published private(set) var connectionProblem: JITConnectionProblem?
    /// What to tell the user, and which buttons to offer, for the last connection problem.
    @Published private(set) var advice: JITAdvice?
    @Published private(set) var busy = false
    @Published private(set) var status: String?
    @Published private(set) var error: String?
    @Published private(set) var txmPresent: Bool?
    /// The setup check passed for the current pairing file.
    @Published private(set) var prepared = false
    @Published private(set) var pairingSource = JITPairingFileStore.source
    /// Bumped each time the built-in helper attaches. Henge stays in the
    /// foreground for that, so nothing else tells ContentView to claim the region.
    @Published private(set) var attachGeneration = 0

    var hasPairing: Bool { pairingSource != nil }

    /// The network path right now. The helper reaches this device through LocalDevVPN, but iOS may send that
    /// connection over cellular instead; knowing which network is in use decides the advice and the retries.
    private let pathMonitor = NWPathMonitor()

    var networkSituation: NetworkSituation {
        let path = pathMonitor.currentPath
        return NetworkSituation(NetworkPathSnapshot(
            isSatisfied: path.status == .satisfied,
            usesWiFi: path.usesInterfaceType(.wifi),
            usesCellular: path.usesInterfaceType(.cellular),
            usesWired: path.usesInterfaceType(.wiredEthernet)))
    }

    private init() {
        pathMonitor.start(queue: DispatchQueue(label: "com.henge.app.jit-path", qos: .utility))
    }

    /// What turning JIT on will do, for screens that show it.
    var methodDescription: String {
        hasPairing ? "Henge will use its paired built-in helper." : "Pair this device to use Henge's built-in helper."
    }

    func refreshPairingStatus() {
        pairingSource = JITPairingFileStore.source
    }

    private func log(_ line: String) { HengeLog.log("jit", line) }

    /// "Turn on JIT at launch": when Henge opens without JIT, ask the built-in StikJIT for it straight away, once per launch.
    /// Only when StikJIT can do it unattended -- it is available here and already paired -- so opening Henge never lands in
    /// the setup walkthrough by surprise.
    static let autoEnableKey = "henge.jit.autoEnable"
    private var autoTried = false

    /// JIT at launch opened LocalDevVPN to connect it; the next return to the foreground goes on with the built-in helper.
    private var awaitingVPN = false
    /// Paired a moment ago: the next return to the foreground connects LocalDevVPN, checks the setup and turns JIT on.
    private var continueAfterPairing = false
    /// JIT at launch is on unless turned off in Settings (a pairing turns it on, too).
    static var autoEnable: Bool { UserDefaults.standard.object(forKey: autoEnableKey) as? Bool ?? true }

    func enableAtLaunchIfAsked() {
        if awaitingVPN {
            awaitingVPN = false
            guard !JITBootstrap.ready else { return }
            log("back from LocalDevVPN (\(LocalDevVPN.isConnected ? "connected" : "not connected")): turning JIT on with built-in StikJIT")
            if continueAfterPairing {
                continueAfterPairing = false
                prepareBuiltIn(thenEnable: true)
            } else {
                enable(backFromVPN: true) // not into LocalDevVPN again: that bounced for ever when the tunnel did not show
            }
            return
        }
        if continueAfterPairing {
            autoTried = true
            guard !JITBootstrap.ready, HengeBuiltInJIT.isAvailable, hasPairing else { continueAfterPairing = false; return }
            if LocalDevVPN.isInstalled, !LocalDevVPN.isConnected {
                log("paired: opening LocalDevVPN to connect, then JIT")
                awaitingVPN = true
                LocalDevVPN.open()
                return
            }
            continueAfterPairing = false
            log("paired: checking the setup, then turning JIT on")
            prepareBuiltIn(thenEnable: true)
            return
        }
        guard !autoTried, Self.autoEnable else { return }
        autoTried = true
        guard !JITBootstrap.ready else { return }
        guard HengeBuiltInJIT.isAvailable, hasPairing else {
            log("JIT at launch is on, but built-in StikJIT is not available or not paired; skipped")
            return
        }
        // The helper reaches this device through LocalDevVPN. When it is not connected, connect it first: LocalDevVPN
        // connects and comes back (henge://), and the return to the foreground goes on above.
        if LocalDevVPN.isInstalled, !LocalDevVPN.isConnected {
            log("JIT at launch: LocalDevVPN is not connected; opening it to connect")
            awaitingVPN = true
            LocalDevVPN.open()
            return
        }
        log("turning JIT on at launch with built-in StikJIT")
        enable()
    }

    /// backFromVPN: LocalDevVPN was just opened for this, so go on with whatever connection there is.
    func enable(backFromVPN: Bool = false) {
        guard !JITBootstrap.ready else { return }
        // Turn On JIT while JIT is already being turned on (at launch, by itself) started a second helper, which attached
        // once the first let go and then stayed: with a debugger on, every trap stops Henge until it answers, and the
        // phone ran process spawns 2x and a shell loop 1.5x slower (2026-11-09).
        guard !busy else {
            log("Turn On JIT: JIT is being turned on already; nothing more to do")
            return
        }
        error = nil
        connectionProblem = nil
        advice = nil
        guard HengeBuiltInJIT.isAvailable, hasPairing else {
            log("built-in JIT is not set up; opening the walkthrough")
            showSetup = true
            return
        }
        // The helper reaches the device through LocalDevVPN: connect it first (it comes back by itself).
        if LocalDevVPN.isInstalled, !LocalDevVPN.isConnected, !awaitingVPN, !backFromVPN {
            log("Turn On JIT: LocalDevVPN is not connected; opening it to connect")
            awaitingVPN = true
            LocalDevVPN.open()
            return
        }
        enableBuiltIn()
    }

    func importPairingFile(_ source: URL) {
        do {
            try JITPairingFileStore.importFile(from: source)
            OnDevicePairing.shared.cancel()
            refreshPairingStatus()
            prepared = false
            status = "Pairing file imported."
            error = nil
            log("pairing file imported")
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// OnDevicePairing finished: its file becomes the pairing file.
    func storeOnDevicePairing(_ data: Data) throws {
        try JITPairingFileStore.store(data, source: .onDevice)
        refreshPairingStatus()
        prepared = false
        status = "Paired on this device."
        error = nil
        // Pairing ends in Settings, with Solstice in the background, where neither LocalDevVPN nor the helper can be
        // started: the next return to the foreground goes on (enableAtLaunchIfAsked), and JIT at launch is on from now.
        UserDefaults.standard.set(true, forKey: Self.autoEnableKey)
        continueAfterPairing = true
    }

    /// Check LocalDevVPN and the Developer Disk Image, mounting it when needed. `attempt` counts tries; see JITRetryPolicy.
    /// `thenEnable`: on success go straight on to enableBuiltIn (after pairing). Kept as two steps, not one: the first
    /// Developer Disk Image download takes about a minute, which would eat the enable step's 90-second attach timer.
    func prepareBuiltIn(attempt: Int = 1, thenEnable: Bool = false) {
        guard let pairing = builtInPairing() else { return }
        busy = true
        error = nil
        connectionProblem = nil
        advice = nil
        if attempt == 1 { status = "Checking LocalDevVPN and the Developer Disk Image…" }
        RemotePairingPortDiscovery.resolve { port in
            HengeBuiltInJIT.send(.prepare(pairingData: pairing, rsdPort: port)) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let response):
                    log("setup check \(response.success ? "passed" : "failed"): \(response.message)")
                    if !response.success,
                       retryIfAdvised(helperMessage: response.message, attempt: attempt, retry: { [weak self] in self?.prepareBuiltIn(attempt: $0, thenEnable: thenEnable) }) {
                        return
                    }
                    busy = false
                    txmPresent = response.txmPresent
                    prepared = response.success
                    status = response.success ? response.message : nil
                    error = response.success ? nil : helperFailure(response.message)
                    if response.success && thenEnable && !JITBootstrap.ready { enableBuiltIn() }
                case .failure(let failure):
                    busy = false
                    prepared = false
                    status = nil
                    error = failure.localizedDescription
                }
            }
        }
    }

    func enableBuiltIn(attempt: Int = 1) {
        guard let pairing = builtInPairing() else { return }
        guard let script = JITBootstrap.scriptBase64 else {
            error = "Henge's JIT script is missing from this installation. Reinstall Henge."
            return
        }

        busy = true
        JITBootstrap.helperMayBeAttached = true
        error = nil
        connectionProblem = nil
        advice = nil
        if attempt == 1 { status = "Starting Henge's JIT helper…" }
        log("enabling JIT with the built-in helper" + (attempt > 1 ? " (attempt \(attempt))" : ""))
        var readiness: Timer?
        var finished = false
        let finish: (String?) -> Void = { [weak self] failure in
            guard let self, !finished else { return }
            finished = true
            readiness?.invalidate()
            busy = false
            if let failure {
                status = nil
                error = failure
                log("built-in JIT failed: \(failure)")
                showSetup = true
            } else {
                status = "JIT is on."
                error = nil
                attachGeneration += 1
                log("built-in helper attached")
            }
        }

        RemotePairingPortDiscovery.resolve { port in
            HengeBuiltInJIT.send(
                .enable(targetPID: getpid(), pairingData: pairing, scriptBase64: script, rsdPort: port),
                started: { [weak self] in
                    if attempt == 1 { self?.status = "Waiting for the helper to attach…" }
                    readiness = Self.waitForDebugger { attached in
                        finish(attached ? nil : "The helper did not attach within 90 seconds. "
                                              + "Check that LocalDevVPN is connected, then try again.")
                    }
                },
                completion: { [weak self] result in
                    // The helper replies once Henge detaches, or when attaching failed.
                    switch result {
                    case .success(let response):
                        self?.txmPresent = response.txmPresent
                        HengeLog.log("jit", "helper: \(response.message)")
                        if !response.success {
                            guard let self else { return }
                            // Not finish(): a retry keeps the screen busy and the next attempt starts its own watch.
                            if !finished,
                               retryIfAdvised(helperMessage: response.message, attempt: attempt,
                                              retry: { [weak self] in self?.enableBuiltIn(attempt: $0) }) {
                                finished = true
                                readiness?.invalidate()
                                return
                            }
                            finish(helperFailure(response.message))
                        }
                    case .failure(let failure):
                        finish(failure.localizedDescription)
                    }
                })
        }
    }

    func resetDDI() {
        busy = true
        error = nil
        status = "Resetting the Developer Disk Image cache…"
        HengeBuiltInJIT.send(.resetDDI) { [weak self] result in
            guard let self else { return }
            busy = false
            prepared = false
            switch result {
            case .success(let response):
                status = response.success ? response.message : nil
                error = response.success ? nil : response.message
            case .failure(let failure):
                status = nil
                error = failure.localizedDescription
            }
        }
    }

    private func builtInPairing() -> Data? {
        if let reason = HengeBuiltInJIT.unavailableReason {
            error = reason
            return nil
        }
        guard let pairing = try? JITPairingFileStore.data() else {
            error = "Pair this device or import its pairing file first."
            return nil
        }
        return pairing
    }

    /// The helper's failure as shown: a connection problem gets its plain
    /// explanation for the network in use (the helper's own message is already in the log).
    private func helperFailure(_ message: String) -> String {
        connectionProblem = JITConnectionProblem(helperMessage: message)
        advice = JITNetworkAdvice.advice(forHelperMessage: message, situation: networkSituation)
        return advice?.message ?? message
    }

    /// When the policy says the failure is worth another try, say so, wait, and call `retry` with the next attempt number.
    /// Returns false when it gives up, and the caller shows the advice instead.
    private func retryIfAdvised(helperMessage: String, attempt: Int, retry: @escaping (Int) -> Void) -> Bool {
        guard let problem = JITConnectionProblem(helperMessage: helperMessage),
              case .retry(let wait) = JITRetryPolicy.decision(situation: networkSituation, problem: problem, attempt: attempt)
        else { return false }
        status = JITRetryPolicy.statusText(nextAttempt: attempt + 1)
        log("helper could not connect (attempt \(attempt)); retrying in \(Int(wait))s")
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard self != nil else { return }
            retry(attempt + 1)
        }
        return true
    }

    /// Polls CS_DEBUGGED until it is set or `timeout` passes.
    private static func waitForDebugger(timeout: TimeInterval = 90,
                                        completion: @escaping (Bool) -> Void) -> Timer {
        let deadline = Date().addingTimeInterval(timeout)
        let timer = Timer(timeInterval: 0.5, repeats: true) { timer in
            if JITBootstrap.debuggedFlag {
                timer.invalidate()
                completion(true)
            } else if Date() >= deadline {
                timer.invalidate()
                completion(false)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}

/// LocalDevVPN, which Built-in StikJIT reaches the device through:
/// open it to connect when it is installed, otherwise its App Store page.
enum LocalDevVPN {
    static let appStore = URL(string: "https://apps.apple.com/us/app/localdevvpn/id6755608044")!
    /// `enable` connects the VPN; `scheme` has LocalDevVPN return to Henge afterwards.
    static let connect = URL(string: "localdevvpn://enable?scheme=henge")!

    static var isInstalled: Bool { UIApplication.shared.canOpenURL(URL(string: "localdevvpn://")!) }

    /// Whether its tunnel is up: a tunnel interface that is up with an address in 10.7.0.0/16 (LocalDevVPN's own is
    /// 10.7.1.1), the network it routes to reach this device at 10.7.0.1, StikJIT's default device address.
    static var isConnected: Bool {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return false }
        defer { freeifaddrs(list) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard (ifa.ifa_flags & UInt32(IFF_UP)) != 0, let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let ip = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            if ip >> 16 == 0x0a07, String(cString: ifa.ifa_name).hasPrefix("utun") {
                HengeLog.log("jit", "LocalDevVPN tunnel on \(String(cString: ifa.ifa_name))")
                return true
            }
        }
        return false
    }
    static var actionTitle: String { isInstalled ? "Connect LocalDevVPN" : "Get LocalDevVPN" }

    @MainActor static func open() {
        let installed = isInstalled
        HengeLog.log("jit", "LocalDevVPN \(installed ? "connect" : "app-store")")
        UIApplication.shared.open(installed ? connect : appStore)
    }
}

/// The device advertises RemotePairing on a port it picks at boot, while
/// StikJIT defaults to the old fixed 49152. Find the advertised port so
/// Built-in StikJIT keeps working after the device restarts.
enum RemotePairingPortDiscovery {
    private static let serviceType = "_remotepairing._tcp"
    private static let queue = DispatchQueue(label: "com.henge.app.remotepairing-discovery", qos: .utility)
    private static let lock = NSLock()
    private static var cachedPort: UInt16?
    private static var lastFailure: Date?

    /// Calls back on the main thread. nil means the helper should use StikJIT's
    /// default.
    static func resolve(timeout: TimeInterval = 3, completion: @escaping (UInt16?) -> Void) {
        lock.lock()
        if let cachedPort {
            lock.unlock()
            DispatchQueue.main.async { completion(cachedPort) }
            return
        }
        if let lastFailure, Date().timeIntervalSince(lastFailure) < 30 {
            lock.unlock()
            DispatchQueue.main.async { completion(nil) }
            return
        }
        lock.unlock()

        queue.async {
            let port = discover(timeout: timeout)
            lock.lock()
            if let port {
                cachedPort = port
                lastFailure = nil
            } else {
                lastFailure = Date()
            }
            lock.unlock()
            HengeLog.log("jit", "RemotePairing port "
                        + (port.map { String($0) } ?? "not found; using StikJIT's default"))
            DispatchQueue.main.async { completion(port) }
        }
    }

    private static func discover(timeout: TimeInterval) -> UInt16? {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: parameters)

        let semaphore = DispatchSemaphore(value: 0)
        let resultLock = NSLock()
        var finished = false
        var resolvedPort: UInt16?
        var pendingConnection: NWConnection?

        func finish(_ port: UInt16?) {
            resultLock.lock()
            if !finished {
                finished = true
                resolvedPort = port
                semaphore.signal()
            }
            resultLock.unlock()
        }

        func hasFinished() -> Bool {
            resultLock.lock()
            defer { resultLock.unlock() }
            return finished
        }

        browser.browseResultsChangedHandler = { results, _ in
            guard !hasFinished() else { return }

            // Only this device's own service (on loopback): other Apple devices on the network advertise
            // theirs too, and their port is closed here. Without one the helper finds and checks the port.
            let preferred = results.first { result in
                result.interfaces.contains { $0.name == "lo0" }
            }
            guard let result = preferred, case .service = result.endpoint else { return }

            resultLock.lock()
            let alreadyConnecting = pendingConnection != nil
            if !alreadyConnecting {
                pendingConnection = NWConnection(to: result.endpoint, using: parameters)
            }
            let connection = pendingConnection
            resultLock.unlock()

            guard !alreadyConnecting, let connection else { return }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let remoteEndpoint = connection.currentPath?.remoteEndpoint,
                       case .hostPort(_, let port) = remoteEndpoint {
                        finish(port.rawValue)
                    } else {
                        finish(nil)
                    }
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }

        browser.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled:
                finish(nil)
            default:
                break
            }
        }

        browser.start(queue: queue)
        _ = semaphore.wait(timeout: .now() + timeout)
        browser.cancel()

        resultLock.lock()
        let connectionToCancel = pendingConnection
        resultLock.unlock()
        connectionToCancel?.cancel()

        resultLock.lock()
        defer { resultLock.unlock() }
        return resolvedPort
    }
}

