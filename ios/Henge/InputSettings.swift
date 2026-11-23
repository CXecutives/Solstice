import SwiftUI
import UIKit

/// How a finger over the Mac's screen drives it.
enum PointerMode: String, CaseIterable, Identifiable {
    case trackpad // the screen is the Mac's trackpad: the pointer moves with the finger, from where it was
    case direct   // the finger is the pointer: it goes where you touch, and a tap clicks there

    static let key = "henge.touch.mode"
    var id: String { rawValue }
    var title: String { self == .trackpad ? "Trackpad" : "Direct touch" }
}

/// The touch surface's timing, as the person set it.
enum TouchTiming {
    static let holdKey = "henge.touch.hold"
    static let tapDragKey = "henge.touch.tapDrag"
    static let defaultHold = 0.4
    static let defaultTapDrag = 0.25

    static func timing(hold: Double, tapDrag: Double) -> TouchGestures.Timing {
        var t = TouchGestures.Timing()
        t.hold = hold.isFinite ? min(max(hold, 0.2), 1) : defaultHold
        t.tapDrag = tapDrag.isFinite ? min(max(tapDrag, 0), 0.5) : defaultTapDrag
        return t
    }
}

extension KeyLayout {
    /// The layout set in Settings; until one is, the one the on-screen keyboard's language suggests.
    static var current: KeyLayout {
        if let raw = UserDefaults.standard.string(forKey: key), let layout = KeyLayout(rawValue: raw) { return layout }
        return suggested
    }

    /// From the language of the keyboard in use, or else the first one set up, or else the device's language.
    static var suggested: KeyLayout {
        let modes = UITextInputMode.activeInputModes
        let language = modes.compactMap(\.primaryLanguage).first { $0 != "emoji" && $0 != "dictation" }
        return forLanguage(language ?? Locale.preferredLanguages.first)
    }
}

/// Settings: the Mac's keyboard layout.
struct KeyboardSettings: View {
    @AppStorage(KeyLayout.key) private var layout = KeyLayout.suggested

    var body: some View {
        Section("Keyboard") {
            Picker("Mac keyboard layout", selection: $layout) {
                ForEach(KeyLayout.allCases) { Text($0.title).tag($0) }
            }
            Text("Choose the layout set in the Mac's System Settings, Keyboard, so typed text comes out right. Characters it has no key for are pasted once Solstice's helper is set up on the Mac. The Mac sees a keyboard of the matching kind the next time it starts.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .listRowBackground(Desk.card)
    }
}

/// Settings: how touches drive the Mac.
struct TouchSettings: View {
    @AppStorage(PointerMode.key) private var mode = PointerMode.trackpad
    @AppStorage(TouchTiming.holdKey) private var hold = TouchTiming.defaultHold
    @AppStorage(TouchTiming.tapDragKey) private var tapDrag = TouchTiming.defaultTapDrag

    var body: some View {
        Section("Touch") {
            Picker("Touch", selection: $mode) {
                ForEach(PointerMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Hold to drag", value: String(format: "%.2f s", hold))
                Slider(value: $hold, in: 0.2...1, step: 0.05)
            }
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Tap, then drag", value: tapDrag < 0.01 ? "Off" : String(format: "%.2f s", tapDrag))
                Slider(value: $tapDrag, in: 0...0.5, step: 0.05)
            }
            Text(mode == .trackpad
                 ? "The screen is the Mac's trackpad. Tap to click, tap with two fingers to right-click; hold, or tap and touch again, then move to drag. A tap's click finishes when the tap-then-drag time is over; set it to Off for clicks without that wait."
                 : "Touch the Mac's screen where you want the pointer, and tap to click there; hold, then move to drag. Two or more fingers are still the Mac's trackpad: scroll, pinch, swipe, and tap with two fingers to right-click.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .listRowBackground(Desk.card)
    }
}

/// Settings: the device's clipboard to the Mac's, without the paste button.
struct ClipboardSettings: View {
    @AppStorage(Sharing.syncClipboardKey) private var sync = false

    var body: some View {
        Section("Clipboard") {
            Toggle("Send copied text to the Mac", isOn: $sync)
            Text("While Solstice is in front, text you copy on this \(Device.name) goes to the Mac's clipboard, so ⌘V pastes it there. Needs Solstice's helper on the Mac. iOS asks each time unless Paste from Other Apps is set to Allow in Settings, Apps, Solstice. What you copy on the Mac always comes here.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .listRowBackground(Desk.card)
    }
}
