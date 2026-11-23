import SwiftUI
import UIKit

/// Types into the Mac. Two invisible views take turns holding the keyboard: one that asks for the
/// on-screen keyboard, with a row of the Mac's own keys above it, and one that doesn't, so that a
/// hardware keyboard works whether or not that is open.
struct KeyboardCatcher: UIViewRepresentable {
    @Binding var active: Bool

    func makeUIView(context: Context) -> Holder { Holder() }

    func updateUIView(_ view: Holder, context: Context) {
        view.typer.onHide = { active = false }
        view.typing = active
        DispatchQueue.main.async { view.takeKeyboard() }
    }

    final class Holder: UIView {
        let listener = KeyListener()
        let typer = CatcherView()
        var typing = false
        private var hiding: NSObjectProtocol?

        override init(frame: CGRect) {
            super.init(frame: frame)
            addSubview(listener)
            addSubview(typer)
            hiding = NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillHideNotification,
                                                            object: nil, queue: .main) { [weak self] _ in
                self?.keyboardHid()
            }
        }

        required init?(coder: NSCoder) { fatalError("made in code") }

        deinit {
            if let hiding { NotificationCenter.default.removeObserver(hiding) }
        }

        /// iPadOS's own hide-keyboard key closes the keyboard without asking the app, which then went on
        /// keeping the Mac small, with room for a keyboard that was gone. Stop typing as the row's button does.
        /// A sheet taking the keyboard isn't that: it is handed back when the sheet closes.
        private func keyboardHid() {
            guard typing, let window, window.rootViewController?.presentedViewController == nil else { return }
            typer.onHide()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            takeKeyboard()
        }

        /// Called often, which also takes the keyboard back after a sheet has had it.
        func takeKeyboard() {
            guard let window, window.rootViewController?.presentedViewController == nil else { return }
            let holder: UIView = typing ? typer : listener
            if !holder.isFirstResponder { holder.becomeFirstResponder() }
        }
    }

    /// Whichever view holds the keyboard hears a hardware keyboard's keys here.
    class KeyListener: UIView {
        override var canBecomeFirstResponder: Bool { true }
        /// Fingers belong to the session (they drive the Mac's trackpad), not to iPadOS's undo/copy/paste bar.
        override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }

        private static let commands = HardwareKeys.keyCommands(action: #selector(KeyListener.sendCommand(_:)))
        override var keyCommands: [UIKeyCommand]? { Self.commands }
        @objc func sendCommand(_ command: UIKeyCommand) { HardwareKeys.perform(command) }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            let rest = HardwareKeys.send(presses, down: true)
            if !rest.isEmpty { super.pressesBegan(rest, with: event) }
        }

        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            let rest = HardwareKeys.send(presses, down: false)
            if !rest.isEmpty { super.pressesEnded(rest, with: event) }
        }

        override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            let rest = HardwareKeys.send(presses, down: false)
            if !rest.isEmpty { super.pressesCancelled(rest, with: event) }
        }
    }

    final class CatcherView: KeyListener, UIKeyInput {
        var onHide: () -> Void = {}
        private lazy var row: UIHostingController<ModifierRow> = {
            let host = UIHostingController(rootView: ModifierRow(hide: { [weak self] in self?.onHide() }))
            host.sizingOptions = []
            host.view.backgroundColor = .clear
            host.view.frame = CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 56)
            host.view.autoresizingMask = .flexibleWidth
            return host
        }()

        override var inputAccessoryView: UIView? { row.view }
        var hasText: Bool { true }
        var autocorrectionType: UITextAutocorrectionType = .no
        var autocapitalizationType: UITextAutocapitalizationType = .none
        var spellCheckingType: UITextSpellCheckingType = .no
        var smartQuotesType: UITextSmartQuotesType = .no
        var smartDashesType: UITextSmartDashesType = .no

        func insertText(_ text: String) {
            guard !HardwareKeys.keyJustPressed else { return }
            Keys.typeOrPaste(text)
            StickyKeys.shared.used()
        }

        func deleteBackward() {
            guard !HardwareKeys.keyJustPressed else { return }
            Keys.press(Keys.backspace)
            StickyKeys.shared.used()
        }
    }
}

/// Linux input key codes, which the Mac's keyboard device takes.
enum Keys {
    static let escape: UInt16 = 1
    static let backspace: UInt16 = 14
    static let tab: UInt16 = 15
    static let control: UInt16 = 29
    static let shift: UInt16 = 42
    static let option: UInt16 = 56
    static let space: UInt16 = 57
    static let home: UInt16 = 102
    static let up: UInt16 = 103
    static let pageUp: UInt16 = 104
    static let left: UInt16 = 105
    static let right: UInt16 = 106
    static let end: UInt16 = 107
    static let down: UInt16 = 108
    static let pageDown: UInt16 = 109
    static let forwardDelete: UInt16 = 111
    static let command: UInt16 = 125
    /// F1...F12.
    static let functionKeys: [UInt16] = [59, 60, 61, 62, 63, 64, 65, 66, 67, 68, 87, 88]

    static func press(_ code: UInt16, shifted: Bool = false) {
        press(KeyStroke(code: code, shift: shifted))
    }

    /// One key with the modifiers it needs; a modifier the sticky row already holds stays held.
    static func press(_ stroke: KeyStroke) {
        let held = StickyKeys.shared.down
        let modifiers = [(stroke.option, option), (stroke.shift, shift)].filter { $0.0 && !held.contains($0.1) }.map { $0.1 }
        for m in modifiers { henge_vm_key(m, 1) }
        henge_vm_key(stroke.code, 1)
        henge_vm_key(stroke.code, 0)
        for m in modifiers.reversed() { henge_vm_key(m, 0) }
    }

    /// A character with a modifier held, by the Mac's layout (⌘Z is where Z is on it).
    static func chord(_ modifier: UInt16, _ c: Character) {
        let held = StickyKeys.shared.down.contains(modifier)
        if !held { henge_vm_key(modifier, 1) }
        type(c)
        if !held { henge_vm_key(modifier, 0) }
    }

    /// One character at a time, for what the Mac has to keep up with.
    @MainActor static func typeSlowly(_ text: String) async {
        let layout = KeyLayout.current
        for c in text {
            type(c, layout: layout)
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    /// Types c with the keys the Mac's layout has for it; false if it has none.
    @discardableResult static func type(_ c: Character, layout: KeyLayout = .current) -> Bool {
        guard let strokes = layout.strokes(for: c) else { return false }
        for stroke in strokes { press(stroke) }
        return true
    }

    /// Text from the on-screen keyboard. What the Mac's layout has no key for (é, emoji, other scripts) is
    /// pasted, all of it so it stays in order, once the helper is there to take the clipboard; without it,
    /// what has keys is typed.
    static func typeOrPaste(_ text: String) {
        let layout = KeyLayout.current
        if StickyKeys.shared.down.isEmpty, Sharing.helperRunning, text.contains(where: { layout.strokes(for: $0) == nil }) {
            Sharing.paste(text)
            return
        }
        for c in text { type(c, layout: layout) }
    }
}

/// ⇧, ⌃, ⌥ and ⌘ stay down from a tap until the next key or click, so a shortcut takes one finger. Tapped
/// twice quickly, one stays down until it is tapped again: ⌘ then tab, tab, tab steps through apps.
final class StickyKeys: ObservableObject {
    static let shared = StickyKeys()
    static let doubleTap: CFTimeInterval = 0.35
    @Published private(set) var down: Set<UInt16> = []
    @Published private(set) var latched: Set<UInt16> = []
    private var lastTap: (code: UInt16, at: CFTimeInterval)?

    func toggle(_ code: UInt16) {
        let now = CACurrentMediaTime()
        let quick = lastTap.map { $0.code == code && now - $0.at < Self.doubleTap } ?? false
        lastTap = (code, now)
        if latched.contains(code) {
            release(code)
        } else if down.contains(code) {
            if quick { latched.insert(code) } else { release(code) }
        } else {
            henge_vm_key(code, 1)
            down.insert(code)
        }
    }

    /// A key was typed or a click made: the modifiers down for one use let go; latched ones stay.
    func used() {
        for code in down.subtracting(latched) { release(code) }
    }

    /// Everything up: the session is leaving, or something else takes the keyboard.
    func releaseAll() {
        guard !down.isEmpty else { return }
        for code in down { henge_vm_key(code, 0) }
        down.removeAll()
        latched.removeAll()
    }

    private func release(_ code: UInt16) {
        henge_vm_key(code, 0)
        down.remove(code)
        latched.remove(code)
    }
}

/// The keys an on-screen keyboard doesn't have, in the slot above it: modifiers, arrows and editing keys,
/// F1–F12 and a few of the Mac's shortcuts, in a row that scrolls sideways.
struct ModifierRow: View {
    let hide: () -> Void
    @ObservedObject private var sticky = StickyKeys.shared

    var body: some View {
        HStack(spacing: 5) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    HeldKey(label: "esc", code: Keys.escape)
                    HeldKey(label: "tab", code: Keys.tab)
                    modifier("⇧", Keys.shift, "Shift")
                    modifier("⌃", Keys.control, "Control")
                    modifier("⌥", Keys.option, "Option")
                    modifier("⌘", Keys.command, "Command")
                    HeldKey(label: "←", code: Keys.left, name: "Left")
                    HeldKey(label: "↑", code: Keys.up, name: "Up")
                    HeldKey(label: "↓", code: Keys.down, name: "Down")
                    HeldKey(label: "→", code: Keys.right, name: "Right")
                    HeldKey(label: "⌦", code: Keys.forwardDelete, name: "Forward Delete")
                    HeldKey(label: "↖", code: Keys.home, name: "Home")
                    HeldKey(label: "↘", code: Keys.end, name: "End")
                    HeldKey(label: "⇞", code: Keys.pageUp, name: "Page Up")
                    HeldKey(label: "⇟", code: Keys.pageDown, name: "Page Down")
                    ForEach(Array(Keys.functionKeys.enumerated()), id: \.offset) { i, code in
                        HeldKey(label: "F\(i + 1)", code: code)
                    }
                    ShortcutKey(label: "⌘ space", name: "Spotlight", modifiers: [Keys.command], key: .code(Keys.space))
                    ShortcutKey(label: "⌘ tab", name: "Switch apps", modifiers: [Keys.command], key: .code(Keys.tab))
                    ShortcutKey(label: "⌘Q", name: "Quit", modifiers: [Keys.command], key: .character("q"))
                    ShortcutKey(label: "⌘W", name: "Close window", modifiers: [Keys.command], key: .character("w"))
                    ShortcutKey(label: "⌘⇧4", name: "Screenshot of an area", modifiers: [Keys.command, Keys.shift], key: .code(5))
                    ShortcutKey(label: "⌃↑", name: "Mission Control", modifiers: [Keys.control], key: .code(Keys.up))
                }
                .padding(.leading, 6)
            }
            Button(action: hide) {
                Image(systemName: "keyboard.chevron.compact.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Desk.text)
                    .frame(width: 44)
                    .frame(maxHeight: .infinity)
                    .background(Desk.raised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .accessibilityLabel("Hide keyboard")
            .padding(.trailing, 6)
        }
        .padding(.vertical, 6)
        .frame(height: 56)
    }

    private func modifier(_ symbol: String, _ code: UInt16, _ name: String) -> some View {
        let on = sticky.down.contains(code)
        let latched = sticky.latched.contains(code)
        return Button {
            sticky.toggle(code)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            Text(symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(on ? Color.white : Desk.text)
                .frame(minWidth: 40, maxHeight: .infinity)
                .background(on ? Desk.accent : Desk.raised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(alignment: .bottom) {
                    if latched { Capsule().fill(Color.white).frame(width: 14, height: 2).padding(.bottom, 6) }
                }
        }
        .accessibilityLabel(name)
        .accessibilityValue(latched ? "Locked" : on ? "On" : "Off")
    }
}

/// A key that goes down when touched and up when let go, so holding it repeats as on a Mac.
private struct HeldKey: View {
    let label: String
    let code: UInt16
    var name: String?
    @State private var down = false

    var body: some View {
        Text(label)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Desk.text)
            .padding(.horizontal, 8)
            .frame(minWidth: 40, maxHeight: .infinity)
            .background(down ? Desk.accent : Desk.raised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !down else { return }
                        down = true
                        henge_vm_key(code, 1)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                    .onEnded { _ in
                        down = false
                        henge_vm_key(code, 0)
                        StickyKeys.shared.used()
                    }
            )
            .accessibilityLabel(name ?? label)
    }
}

/// One of the Mac's shortcuts in a tap: its modifiers, its key, and up again.
private struct ShortcutKey: View {
    enum Key {
        case code(UInt16)       // the same key on every layout
        case character(Character) // where the Mac's layout has it
    }

    let label: String
    let name: String
    let modifiers: [UInt16]
    let key: Key

    var body: some View {
        Button {
            let held = StickyKeys.shared.down
            let own = modifiers.filter { !held.contains($0) }
            for m in own { henge_vm_key(m, 1) }
            switch key {
            case .code(let code):
                henge_vm_key(code, 1)
                henge_vm_key(code, 0)
            case .character(let c):
                Keys.type(c)
            }
            for m in own.reversed() { henge_vm_key(m, 0) }
            StickyKeys.shared.used()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Desk.text)
                .padding(.horizontal, 8)
                .frame(minWidth: 40, maxHeight: .infinity)
                .background(Desk.raised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .accessibilityLabel(name)
    }
}
