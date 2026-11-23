import UIKit
import GameController

/// A Magic Keyboard's trackpad or a mouse, while a Mac is running. GameController gives the raw motion,
/// which macOS then accelerates as it would for its own mouse.
///
/// GameController calls on `queue`, a queue of its own at user-interactive priority, so the pointer doesn't
/// wait for the main thread's drawing and layout. Everything here but `start`, `stop` and `releaseButtons`
/// (main thread, which hand over to the queue) runs on it.
final class HardwareMouse {
    static let shared = HardwareMouse()
    static let speedKey = "henge.mouse.speed"
    static let reverseKey = "henge.mouse.reverse"
    static let scrollSpeedKey = "henge.mouse.scrollSpeed"
    static let defaultScrollSpeed = 0.3

    /// The Scroll speed setting as a factor, 1 at the default: how much faster than the Mac's own scrolling.
    static func scrollFactor(_ speed: Double) -> CGFloat {
        CGFloat((speed.isFinite ? min(max(speed, 0.1), 1.5) : defaultScrollSpeed) / defaultScrollSpeed)
    }

    private let queue = DispatchQueue(label: "henge.mouse", qos: .userInteractive)
    private var scrollScale: Float = 1 // scrollFactor of the setting, read when it changes rather than per event
    private var observers: [NSObjectProtocol] = []
    private var mice: [GCMouse] = []
    private var buttons = PhysicalMouseButtons(swapsRightAndMiddle: false)
    private var buttonsLogged = 0
    private var restX: Float = 0, restY: Float = 0
    private var speed: Float = 1
    private var reverse = false
    private var scrollsLogged = 0 // the first few, to see what a device's raw values look like
    private var lastScrollFirst: Float = 0, lastScrollSecond: Float = 0
    /// Click steadying. Pressing a trackpad rolls the finger a little, and iPadOS reports that as motion just
    /// before, during and after the press; a Mac's own trackpad drops it. The steps sent lately, to take back at a
    /// press, and the motion held back while a button is down, until it is clearly a drag.
    private var recentSteps: [(t: CFTimeInterval, x: Int32, y: Int32)] = []
    private var heldSteps: [(x: Int32, y: Int32)] = []
    private var heldX: Int32 = 0, heldY: Int32 = 0
    private var buttonsDown = 0
    private var dragging = false
    private static let undoWindow: CFTimeInterval = 0.06
    private static let undoLimit: Int32 = 6   // pixels: more than this before a press was meant
    private static let dragStart: Int32 = 8   // pixels with a button down before it counts as a drag
    private lazy var scrollFingers = ScrollFingers(queue: queue)

    func start() {
        let defaults = UserDefaults.standard
        let speed: Float = defaults.object(forKey: Self.speedKey) == nil ? 1 : Float(defaults.double(forKey: Self.speedKey))
        let reverse = defaults.bool(forKey: Self.reverseKey)
        releaseButtons()
        let swapButtons = defaults.bool(forKey: PhysicalMouseButtons.swapKey)
        HengeLog.log("input", "physical mouse: swap right/middle \(swapButtons ? "on" : "off")")
        queue.async {
            self.speed = speed
            self.reverse = reverse
            self.buttons = PhysicalMouseButtons(swapsRightAndMiddle: swapButtons)
            self.buttonsLogged = 0
            self.lastScrollFirst = 0
            self.lastScrollSecond = 0
        }
        readScrollSpeed()
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.readScrollSpeed()
        })
        AbsolutePointer.refresh()
        GCMouse.mice().forEach(attach)
        observers.append(NotificationCenter.default.addObserver(forName: .GCMouseDidConnect, object: nil, queue: .main) { [weak self] note in
            if let mouse = note.object as? GCMouse { self?.attach(mouse) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .GCMouseDidDisconnect, object: nil, queue: .main) { [weak self] note in
            guard let self, let mouse = note.object as? GCMouse else { return }
            self.releaseButtons()
            self.mice.removeAll { $0 === mouse }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIPointerLockState.didChangeNotification, object: nil, queue: .main) { note in
            // The scene comes in the user info: the notification's object isn't it.
            let scene = note.userInfo?[UIPointerLockState.sceneUserInfoKey] as? UIScene
            let locked = scene?.pointerLockState?.isLocked ?? false
            HengeLog.log("input", "pointer lock: \(locked ? "on" : "off")")
            AbsolutePointer.refresh()
        })
        PointerLock.set(true)
    }

    /// Main thread: the setting, for the queue.
    private func readScrollSpeed() {
        let defaults = UserDefaults.standard
        let speed = defaults.object(forKey: Self.scrollSpeedKey) == nil ? Self.defaultScrollSpeed : defaults.double(forKey: Self.scrollSpeedKey)
        let scale = Float(Self.scrollFactor(speed))
        queue.async { self.scrollScale = scale }
    }

    func stop() {
        PointerLock.set(false)
        releaseButtons()
        queue.async { self.scrollFingers.end() }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        for mouse in mice {
            guard let input = mouse.mouseInput else { continue }
            input.mouseMovedHandler = nil
            input.leftButton.pressedChangedHandler = nil
            input.rightButton?.pressedChangedHandler = nil
            input.middleButton?.pressedChangedHandler = nil
            input.scroll.valueChangedHandler = nil
        }
        mice.removeAll()
    }

    func releaseButtons() {
        queue.async {
            for button in self.buttons.releaseAll() { henge_vm_mouse_button(button, 0) }
            self.buttonsDown = 0
            self.dragging = false
            self.heldSteps.removeAll()
            self.heldX = 0
            self.heldY = 0
        }
    }

    private func attach(_ mouse: GCMouse) {
        guard let input = mouse.mouseInput, !mice.contains(where: { $0 === mouse }) else { return }
        mice.append(mouse)
        mouse.handlerQueue = queue
        HengeLog.log("input", "mouse: \(mouse.vendorName ?? "?"), right button \(input.rightButton != nil), middle \(input.middleButton != nil)")
        input.mouseMovedHandler = { [weak self] _, dx, dy in self?.moved(dx, dy) }
        input.leftButton.pressedChangedHandler = { [weak self] _, _, pressed in self?.button(0, pressed) }
        input.rightButton?.pressedChangedHandler = { [weak self] _, _, pressed in self?.button(1, pressed) }
        input.middleButton?.pressedChangedHandler = { [weak self] _, _, pressed in self?.button(2, pressed) }
        input.scroll.valueChangedHandler = { [weak self] _, first, second in self?.scrolled(first, second) }
    }

    /// GameController's Y runs upward. What doesn't make a whole step yet waits for the next move.
    /// While iPadOS won't lock the pointer, the Mac's pointer follows the iPad's (AbsolutePointer) instead.
    private func moved(_ dx: Float, _ dy: Float) {
        guard !AbsolutePointer.inUseLately else { return }
        restX += dx * speed
        restY -= dy * speed
        let x = restX.rounded(), y = restY.rounded()
        guard x != 0 || y != 0 else { return }
        restX -= x
        restY -= y
        step(Int32(x), Int32(y))
    }

    private func step(_ x: Int32, _ y: Int32) {
        if buttonsDown > 0 && !dragging {
            heldSteps.append((x, y))
            heldX += x
            heldY += y
            guard max(abs(heldX), abs(heldY)) > Self.dragStart else { return }
            // A drag after all: the held motion goes now, in the steps it came in.
            dragging = true
            for held in heldSteps { henge_vm_mouse_move(held.x, held.y) }
            heldSteps.removeAll()
            return
        }
        let now = CACurrentMediaTime()
        recentSteps.append((now, x, y))
        recentSteps.removeAll { now - $0.t > Self.undoWindow }
        henge_vm_mouse_move(x, y)
    }

    /// At a press: take back the last few steps if they add up to only a nudge, the finger rolling as it pressed.
    /// Sent back step by step, newest first, so macOS's pointer acceleration treats them the same as on the way.
    private func steadyForPress() {
        let now = CACurrentMediaTime()
        let nudge = recentSteps.filter { now - $0.t <= Self.undoWindow }
        recentSteps.removeAll()
        let sumX = nudge.reduce(Int32(0)) { $0 + $1.x }, sumY = nudge.reduce(Int32(0)) { $0 + $1.y }
        guard !nudge.isEmpty, max(abs(sumX), abs(sumY)) <= Self.undoLimit else { return }
        for back in nudge.reversed() { henge_vm_mouse_move(-back.x, -back.y) }
    }

    private func button(_ physicalButton: Int32, _ pressed: Bool) {
        guard let guestButton = buttons.event(physicalButton, pressed: pressed) else { return }
        if buttonsLogged < 32 {
            buttonsLogged += 1
            HengeLog.log("input", "physical mouse button: raw=\(physicalButton) guest=\(guestButton) \(pressed ? "down" : "up")")
        }
        if pressed {
            if buttonsDown == 0 {
                steadyForPress()
                dragging = false
                heldSteps.removeAll()
                heldX = 0
                heldY = 0
            }
            buttonsDown += 1
        } else {
            buttonsDown = max(0, buttonsDown - 1)
            // Released before it became a drag: what was held back was the finger wobbling, not meant.
            if buttonsDown == 0 { heldSteps.removeAll(); heldX = 0; heldY = 0; dragging = false }
        }
        henge_vm_mouse_button(guestButton, pressed ? 1 : 0)
        if !pressed { DispatchQueue.main.async { StickyKeys.shared.used() } }
    }

    /// GameController puts vertical motion on the first axis and horizontal on the second, as the fingers' travel
    /// since the last sample (about every 8 ms on a Magic Keyboard), and ends a gesture with both at 0.
    ///
    /// The Mac doesn't get these as wheel clicks: a wheel steps in lines that macOS accelerates, so a small swipe ran
    /// to the end of a page in jumps. They become two fingers moving on the Magic Trackpad 2 the Mac already has
    /// (the touchscreen's, Trackpad.swift), so macOS scrolls them as a trackpad: smoothly, with its own momentum
    /// when the fingers lift.
    private func scrolled(_ first: Float, _ second: Float) {
        // GameController reports both axis states when either one changes. On a
        // Magic Keyboard it calls us twice per movement, with one stale axis in
        // each call; taking both values each time would double the motion.
        let verticalChanged = first != lastScrollFirst
        let horizontalChanged = second != lastScrollSecond
        lastScrollFirst = first
        lastScrollSecond = second
        if scrollsLogged < 24 {
            scrollsLogged += 1
            HengeLog.log("input", "scroll raw: \(first), \(second)")
        }
        guard first.isFinite, second.isFinite else { return }
        if first == 0 && second == 0 {
            scrollFingers.end()
            return
        }
        // GameController's values are the content's way; fingers on the Mac's pad move the other way.
        let way: Float = reverse ? 1 : -1
        // Sensor units per GameController unit: about 40 at the default speed (0.3).
        let gain = way * ScrollFingers.unitsPerPoint * scrollScale
        scrollFingers.move(dx: horizontalChanged ? second * gain : 0, dy: verticalChanged ? first * gain : 0)
    }
}
