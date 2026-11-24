// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import StikJIT

/// The debugger half of Built-in StikJIT (docs/06-built-in-jit.md).
///
/// A process cannot synchronously debug itself, so Solstice starts this extension,
/// sends it its PID, the pairing file and solstice-jit.js, and StikJIT attaches over
/// LocalDevVPN and services the script's trap requests until Solstice detaches.
private enum SolsticeJITWork {
    /// One request at a time: enabling JIT holds this queue while the debugger is attached.
    static let queue = DispatchQueue(label: "io.github.cxecutives.solstice.jit-helper")

    static func handle(_ request: SolsticeJITRequest) -> SolsticeJITRequest.Response {
        let manager = FileManager.default
        let root = manager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StikJIT", isDirectory: true)
        let paths = DDIPaths.default(in: root)
        var configuration = StikJIT.Configuration.default
        /// Appended to the reply so Solstice's log shows how the port was chosen.
        var portNote = ""
        var needsScan = false
        if let rsdPort = request.rsdPort {
            configuration.rsdPort = rsdPort
        } else if request.operation != .resetDDI {
            // Solstice found no advertised port. StikJIT's 49152 is closed when the device picked another at boot.
            let lookup = RSDPortResolver.resolve()
            NSLog("[SolsticeJIT] RemotePairing port: %@", lookup.detail)
            // Every Apple device on the network advertises the service: take only a port open on this device.
            let open = lookup.candidates.map(\.port).filter {
                !RSDPortScanner.openPorts(host: configuration.deviceAddress, range: $0...$0, waitMs: 800).isEmpty
            }
            if let port = open.first { configuration.rsdPort = port } else { needsScan = true }
            portNote = " [helper port lookup: \(lookup.detail); open here: \(open.map(String.init).joined(separator: ",")); "
                + (needsScan ? "scanning]" : "using \(configuration.rsdPort)]")
        }

        do {
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
            if request.operation == .resetDDI {
                try StikJIT.resetCachedDDI(at: paths)
                return .init(success: true, message: "Developer Disk Image cache reset.",
                             txmPresent: StikJIT.isTXMPresent)
            }

            guard let pairingData = request.pairingData, !pairingData.isEmpty else {
                throw NSError(domain: "SolsticeJITHelper", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "The pairing file was not provided."])
            }
            let pairingURL = root.appendingPathComponent("pairingFile-\(UUID().uuidString).plist")
            try pairingData.write(to: pairingURL, options: .atomic)
            defer { try? manager.removeItem(at: pairingURL) }
            if needsScan {
                if let port = findRSDPort(pairingFile: pairingURL, base: configuration) {
                    configuration.rsdPort = port
                    portNote += " [port scan: using \(port)]"
                } else {
                    portNote += " [port scan: no RemotePairing port found]"
                }
            }

            switch request.operation {
            case .prepare:
                let readiness = StikJIT.prepareDevice(
                    pairingFile: pairingURL, paths: paths, configuration: configuration,
                    progress: { NSLog("[SolsticeJIT] prepare: %@", String(describing: $0)) })
                switch readiness {
                case .ready(let security):
                    return .init(success: true,
                                 message: "LocalDevVPN is reachable and the Developer Disk Image is ready." + portNote,
                                 txmPresent: security.isTXMPresent)
                case .unreachable(let reason), .preparationFailed(let reason):
                    return .init(success: false, message: reason + portNote, txmPresent: StikJIT.isTXMPresent)
                @unknown default:
                    return .init(success: false, message: "StikJIT returned an unknown preparation state.",
                                 txmPresent: StikJIT.isTXMPresent)
                }
            case .enable:
                guard let targetPID = request.targetPID,
                      let scriptBase64 = request.scriptBase64, !scriptBase64.isEmpty else {
                    throw NSError(domain: "SolsticeJITHelper", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey:
                                    "The target process or Solstice's JIT script was not provided."])
                }
                try StikJIT.enableJIT(
                    targetPID: targetPID,
                    pairingFile: pairingURL,
                    ddiPaths: paths,
                    configuration: configuration,
                    script: .customBase64(scriptBase64),
                    forceScript: true,
                    preparationProgress: { NSLog("[SolsticeJIT] prepare: %@", String(describing: $0)) },
                    progress: { NSLog("[SolsticeJIT] %@", $0) })
                return .init(success: true, message: "Solstice detached cleanly from its built-in JIT helper." + portNote,
                             txmPresent: StikJIT.isTXMPresent)
            case .resetDDI:
                preconditionFailure("Handled above")
            }
        } catch {
            return .init(success: false, message: error.localizedDescription + portNote,
                         txmPresent: StikJIT.isTXMPresent)
        }
    }

    private static let lastPortKey = "solstice.lastRSDPort"

    /// The last port that worked, then every open port in iOS's range, each probed with a real StikJIT call.
    /// The port changes at each reboot of the device, so a stale remembered one just falls through to the scan.
    private static func findRSDPort(pairingFile: URL, base: StikJIT.Configuration) -> UInt16? {
        func works(_ port: UInt16) -> Bool {
            var probe = base
            probe.rsdPort = port
            probe.connectionTimeout = 2
            return (try? StikJIT.isDDIMounted(pairingFile: pairingFile, configuration: probe)) != nil
        }
        let last = UInt16(exactly: UserDefaults.standard.integer(forKey: lastPortKey)) ?? 0
        if last != 0, works(last) { return last }
        let open = RSDPortScanner.openPorts(host: base.deviceAddress)
        NSLog("[SolsticeJIT] open ports: %@", open.map(String.init).joined(separator: ","))
        guard let port = open.first(where: works) else { return nil }
        UserDefaults.standard.set(Int(port), forKey: lastPortKey)
        return port
    }
}

/// NSExtensionPrincipalClass (Info.plist). The request arrives as JSON in the
/// first input item; the response goes back as JSON in the item the request
/// completes with. Enable completes only once Solstice's script has detached, so
/// the request, and this process, last as long as the debugger does.
@objc(SolsticeJITHelperHandler)
final class SolsticeJITHelperHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let info = (context.inputItems.first as? NSExtensionItem)?.userInfo
        let data = info?[SolsticeJITRequest.itemKey] as? Data
        SolsticeJITWork.queue.async {
            let response: SolsticeJITRequest.Response
            if let data, let request = try? JSONDecoder().decode(SolsticeJITRequest.self, from: data) {
                response = SolsticeJITWork.handle(request)
            } else {
                response = .init(success: false, message: "Solstice's JIT helper received no request.",
                                 txmPresent: nil)
            }
            let item = NSExtensionItem()
            item.userInfo = [SolsticeJITRequest.Response.itemKey: (try? JSONEncoder().encode(response)) ?? Data()]
            context.completeRequest(returningItems: [item], completionHandler: nil)
        }
    }
}
