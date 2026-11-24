import SwiftUI
import UIKit

/// How a finger over the Mac's screen drives it.
enum PointerMode: String, CaseIterable, Identifiable {
    case trackpad // the screen is the Mac's trackpad: the pointer moves with the finger, from where it was
    case direct   // the finger is the pointer: it goes where you touch, and a tap clicks there

    var id: String { rawValue }
    var title: String { self == .trackpad ? "Trackpad" : "Direct Touch" }
}

/// The touch surface's timing, as the person set it.
enum TouchTiming {

    static func timing(hold: Double, tapDrag: Double) -> TouchGestures.Timing {
        var t = TouchGestures.Timing()
        t.hold = hold.isFinite ? min(max(hold, 0.2), 1) : SettingDefault.touchHold
        t.tapDrag = tapDrag.isFinite ? min(max(tapDrag, 0), 0.5) : SettingDefault.touchTapDrag
        return t
    }
}

extension KeyLayout {
    /// The layout set in Settings; until one is, the one the on-screen keyboard's language suggests.
    static var current: KeyLayout {
        if let raw = UserDefaults.standard.string(forKey: SettingKey.keyLayout.rawValue), let layout = KeyLayout(rawValue: raw) { return layout }
        return suggested
    }

    /// From the language of the keyboard in use, or else the first one set up, or else the device's language.
    static var suggested: KeyLayout {
        let modes = UITextInputMode.activeInputModes
        let language = modes.compactMap(\.primaryLanguage).first { $0 != "emoji" && $0 != "dictation" }
        return forLanguage(language ?? Locale.preferredLanguages.first)
    }
}

/// Settings › Pointer & Trackpad: how touches, and on an iPad a trackpad or mouse, drive the Mac.
struct PointerSettings: View {
    @AppStorage(SettingKey.touchMode.rawValue) private var mode = PointerMode.trackpad
    @AppStorage(SettingKey.touchHold.rawValue) private var hold = SettingDefault.touchHold
    @AppStorage(SettingKey.touchTapDrag.rawValue) private var tapDrag = SettingDefault.touchTapDrag
    @AppStorage(SettingKey.mouseSpeed.rawValue) private var mouseSpeed = SettingDefault.mouseSpeed
    @AppStorage(SettingKey.reverseScrolling.rawValue) private var reverseScrolling = false
    @AppStorage(SettingKey.swapMouseButtons.rawValue) private var swapButtons = false

    var body: some View {
        Section {
            Picker("Touch", selection: $mode) {
                ForEach(PointerMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Hold to Drag", value: String(format: "%.2f s", hold))
                Slider(value: $hold, in: 0.2...1, step: 0.05)
            }
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Double-Tap to Drag", value: tapDrag < 0.01 ? "Off" : String(format: "%.2f s", tapDrag))
                Slider(value: $tapDrag, in: 0...0.5, step: 0.05)
            }
            ScrollSpeedRow()
            if Device.isPad {
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Pointer Speed", value: String(format: "%.1f×", mouseSpeed))
                    Slider(value: $mouseSpeed, in: HardwareMouse.speeds)
                }
                Toggle("Reverse Scrolling", isOn: $reverseScrolling)
                Toggle("Swap Right and Middle Buttons", isOn: $swapButtons)
            }
        } header: {
            Text("Trackpad & Mouse")
        } footer: {
            Text((mode == .trackpad
                  ? "Tap to click. Tap with two fingers to right-click. To drag, hold, or double-tap and keep your finger down. With Double-Tap to Drag off, a click is sent at once."
                  : "The pointer goes where you touch. Tap to click, hold to drag. Two fingers still scroll, pinch, swipe and right-click.")
                 + (Device.isPad ? " Pointer speed and swapped buttons apply the next time a Mac starts." : ""))
        }
    }
}

/// Scroll speed, for Settings and the running Mac's panel: it applies at once, to two fingers on the screen as well as
/// to a trackpad or mouse.
struct ScrollSpeedRow: View {
    @AppStorage(SettingKey.scrollSpeed.rawValue) private var speed = SettingDefault.scrollSpeed

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Scroll Speed", value: String(format: "%.1f×", speed / SettingDefault.scrollSpeed))
            Slider(value: $speed, in: HardwareMouse.scrollSpeeds)
        }
    }
}

/// Settings › Mac's Keyboard: its layout, and copied text going to the Mac.
struct KeyboardSettings: View {
    @AppStorage(SettingKey.keyLayout.rawValue) private var layout = KeyLayout.suggested
    @AppStorage(SettingKey.syncClipboard.rawValue) private var sync = false

    var body: some View {
        Section {
            Picker("Mac Keyboard Layout", selection: $layout) {
                ForEach(KeyLayout.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Send Copied Text to the Mac", isOn: $sync)
        } header: {
            Text("Keyboard")
        } footer: {
            Text("Choose the layout that is set on the Mac under System Settings > Keyboard. Copied text reaches the Mac while Solstice is in front. iOS asks each time unless you set Paste from Other Apps to Allow under Settings > Apps > Solstice. Both need Solstice's helper on the Mac.")
        }
    }
}
