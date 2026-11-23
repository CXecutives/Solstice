import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// What a running Mac shares with this device: the Shared folder in Files, and the clipboard. The Mac mounts
/// the folder and follows the clipboard through a small helper (host/share.c, tools/henge-agent.m).
enum Sharing {
    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Shared", isDirectory: true)
    }

    static let setUpCommand = "curl -s http://10.0.2.4\(Brand.urlPrefix)install | sh"
    /// Less background work and drawing in macOS (host/share.c, lighten_script), and back.
    static let lightenCommand = "curl -s http://10.0.2.4\(Brand.urlPrefix)lighten | sh"
    static let unlightenCommand = "curl -s http://10.0.2.4\(Brand.urlPrefix)unlighten | sh"

    /// Before a Mac starts.
    static func prepare() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A Unix socket's path can't be long, so the short temporary folder.
        let socket = (NSTemporaryDirectory() as NSString).appendingPathComponent("s.sock")
        henge_vm_share(folder.path, socket, Bundle.main.path(forResource: "solstice-agent", ofType: "gz"))
    }

    /// The helper asks the server for news at most 25 s apart.
    static var helperRunning: Bool {
        let seen = henge_share_agent_seen()
        return seen >= 0 && seen < 40
    }

    /// Settings: what is copied on this device goes to the Mac's clipboard too, while Solstice is in front.

    /// What is copied on the Mac is copied here too. The other way needs the system's paste button, or, if the
    /// person turned it on, `SettingKey.syncClipboard`: iOS asks for permission whenever an app reads the clipboard on its own.
    @MainActor static func followMacClipboard() async {
        var seen = -1 // the device's clipboard as last sent (or set from the Mac): what changes it is news
        while !Task.isCancelled {
            let board = UIPasteboard.general
            if let text = henge_share_take_clipboard() {
                board.string = String(cString: text)
                free(text)
                seen = board.changeCount
            }
            if UserDefaults.standard.bool(forKey: SettingKey.syncClipboard.rawValue), board.changeCount != seen,
               UIApplication.shared.applicationState == .active {
                seen = board.changeCount
                if board.hasStrings, let text = board.string { henge_share_set_clipboard(text) }
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    /// Text from this device, pasted at the Mac's cursor. Without the helper it is typed, as far as the keyboard can.
    /// In turn with the keys (Keys.output): what is typed after it waits until it is pasted. The text replaces the
    /// Mac's clipboard.
    static func paste(_ text: String) {
        guard helperRunning else {
            Keys.queueSlowTyping(text)
            return
        }
        Keys.output.wait { _ in
            henge_share_set_clipboard(text)
            // The helper's next request for news says it has put the text on the Mac's clipboard; it comes
            // within a few milliseconds. An older helper may not say: then a second at most.
            let until = Date().addingTimeInterval(1)
            while henge_share_clipboard_taken() == 0 && Date() < until {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        Keys.chord(Keys.command, "v")
    }

    /// Files dropped onto the session: copied into the Shared folder, which the Mac has as ~/Henge.
    static func receive(_ providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadFileRepresentation(forTypeIdentifier: UTType.item.identifier) { url, error in
                guard let url else {
                    HengeLog.log("share", "a dropped item could not be read: \(error?.localizedDescription ?? "?")")
                    return
                }
                // The file is gone once this returns: copy it now.
                var name = url.lastPathComponent
                if let suggested = provider.suggestedName?.replacingOccurrences(of: "/", with: "-"), !suggested.isEmpty {
                    let bare = (suggested as NSString).pathExtension.isEmpty && !url.pathExtension.isEmpty
                    name = bare ? suggested + "." + url.pathExtension : suggested
                }
                let target = freeName(for: name)
                do {
                    try FileManager.default.copyItem(at: url, to: target)
                    HengeLog.log("share", "dropped \(target.lastPathComponent) into the Shared folder")
                } catch {
                    HengeLog.log("share", "copying a dropped file failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// A name in the Shared folder nothing has yet: "name", else "name 2", "name 3"...
    private static func freeName(for name: String) -> URL {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }

    /// Types the set up command at the Mac's cursor, and stops there: the person using the Mac presses Return.
    /// Henge can't see what has the keyboard, so it must not submit anything by itself. Opening Terminal for them
    /// through Spotlight was tried: when Spotlight was slow the text went to a web search, and it could as easily
    /// have gone to a chat.
    static func typeSetUpCommand() async {
        await Keys.typeSlowly(setUpCommand)
    }
}
