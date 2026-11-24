// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Security

/// The RPPairing file Built-in StikJIT authenticates with, kept in the Keychain: it holds an Ed25519 private key, so
/// it is never in Documents (Files, a trusted computer and backups see those). Readable after the first unlock, on
/// this device only, so JIT still turns on with the screen locked; it is only ever sent to Solstice's own helper
/// process. A file from an older version is moved in once; a file imported from Files is moved in too.
enum JITPairingFileStore {
    private static let service = "io.github.cxecutives.solstice.jit-pairing"
    private static let account = "pairingFile"

    /// Where older versions kept it (Documents/StikJIT), moved into the Keychain on first use.
    private static var legacyURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StikJIT", isDirectory: true).appendingPathComponent("pairingFile.plist")
    }
    /// Only if the Keychain refuses this install (a signing without its keychain group): out of Documents, out of
    /// backups, and locked until the first unlock.
    private static var fallbackURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JIT", isDirectory: true).appendingPathComponent("pairingFile.plist")
    }

    static var exists: Bool { (try? data()) != nil }

    static var source: JITPairingSource? {
        guard exists else { return nil }
        return UserDefaults.standard.string(forKey: SettingKey.jitPairingSource.rawValue).flatMap(JITPairingSource.init(rawValue:)) ?? .imported
    }

    static func data() throws -> Data {
        migrateOnce()
        if let data = keychainData() { return data }
        return try Data(contentsOf: fallbackURL)
    }

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
            throw NSError(domain: "SolsticeJIT", code: 10,
                          userInfo: [NSLocalizedDescriptionKey:
                            "That is not a remote pairing file. Make one with the StikDebug pairing-file guide and try again."])
        }
        try save(data)
        UserDefaults.standard.set(source.rawValue, forKey: SettingKey.jitPairingSource.rawValue)
    }

    // MARK: Keychain

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private static func keychainData() -> Data? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    /// Into the Keychain (replacing what was there); into the fallback file only if the Keychain refuses.
    private static func save(_ data: Data) throws {
        SecItemDelete(query as CFDictionary)
        var q = query
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        if status == errSecSuccess, keychainData() == data {
            try? FileManager.default.removeItem(at: fallbackURL)
            return
        }
        SolsticeLog.log("jit", "the Keychain refused the pairing file (\(status)); keeping it in the app's private storage")
        let dir = fallbackURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: fallbackURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var url = dir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    private static var migrated = false

    /// A pairing file an older version left in Documents goes into the Keychain, then is deleted (with its folder if
    /// that is empty); it stays where it is if it cannot be moved, so nothing is lost.
    private static func migrateOnce() {
        guard !migrated else { return }
        migrated = true
        let old = legacyURL
        guard let data = try? Data(contentsOf: old) else { return }
        do {
            try save(data)
            try FileManager.default.removeItem(at: old)
            let dir = old.deletingLastPathComponent()
            if (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty == true {
                try? FileManager.default.removeItem(at: dir)
            }
            SolsticeLog.log("jit", "moved the pairing file out of Documents into the Keychain")
        } catch {
            SolsticeLog.log("jit", "the pairing file could not be moved out of Documents: \(error.localizedDescription)")
        }
    }
}
