// SPDX-License-Identifier: GPL-2.0-or-later
import UIKit

/// LocalDevVPN, which Built-in StikJIT reaches the device through:
/// open it to connect when it is installed, otherwise its App Store page.
enum LocalDevVPN {
    static let appStore = URL(string: "https://apps.apple.com/us/app/localdevvpn/id6755608044")!
    /// `enable` connects the VPN; `scheme` has LocalDevVPN return to Henge afterwards.
    static let connect = URL(string: "localdevvpn://enable?scheme=solstice")!

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
