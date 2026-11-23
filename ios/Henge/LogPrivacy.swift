import Foundation

/// What the log stream (LogStream) may say about this device when it leaves it: the app's container path and host
/// names are taken out of each line, and a target that is not on the local network is flagged (the stream is plain
/// TCP). Plain functions of their input.
enum LogPrivacy {
    /// Host names: dotted names ending in a common top-level domain, and .local (mDNS names often carry the owner's name).
    private static let hostPattern = try! NSRegularExpression(
        pattern: #"\b(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+(?:local|lan|home|arpa|com|net|org|io|dev|cloud|me|co|de|uk|eu|us|info|edu|gov)\b"#,
        options: [.caseInsensitive])

    /// The line with `home` (the app's container) as "~" and host names as "<host>".
    static func redact(_ line: String, home: String) -> String {
        var out = home.count > 1 ? line.replacingOccurrences(of: home, with: "~") : line
        if home.hasPrefix("/private/") { out = out.replacingOccurrences(of: String(home.dropFirst("/private".count)), with: "~") }
        let range = NSRange(out.startIndex..., in: out)
        return hostPattern.stringByReplacingMatches(in: out, options: [], range: range, withTemplate: "<host>")
    }

    /// Whether `host` is on the local network: a private (RFC 1918), link-local or loopback address, IPv4 or IPv6, or
    /// an mDNS .local name. Anything else may be reached across the internet.
    static func isLocal(_ host: String) -> Bool {
        let h = host.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).lowercased()
        if h == "localhost" || h.hasSuffix(".local") { return true }
        let parts = h.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4 {
            let n = parts.compactMap { UInt8($0) }
            guard n.count == 4 else { return false }
            return n[0] == 10 || n[0] == 127 || (n[0] == 172 && (16...31).contains(n[1])) || (n[0] == 192 && n[1] == 168)
                || (n[0] == 169 && n[1] == 254)
        }
        guard h.contains(":") else { return false }
        if h == "::1" { return true }
        let first = h.split(separator: ":", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard let word = UInt16(first.isEmpty ? "0" : first, radix: 16) else { return false }
        return word & 0xffc0 == 0xfe80 || word & 0xfe00 == 0xfc00 // link-local fe80::/10, unique local fc00::/7
    }
}
