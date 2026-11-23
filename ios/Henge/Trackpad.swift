import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A surface that works like a Mac's trackpad — it is one: the engine presents it on
/// the Mac's USB bus as a Magic Trackpad 2, so the Mac's own multitouch engine sees
/// the fingers: two scroll, three swipe between Spaces and to Mission Control, four
/// show the session's hidden controls.
///
/// The surface itself clicks (TouchGestures): a tap is a left click, a quick two-finger tap
/// a right click, touching then holding presses the button so moving drags, and so does
/// tapping then touching again and moving. These go out as mouse buttons alongside the pad's fingers.
///
/// Over the Mac's screen it can instead be the screen itself (Direct touch): one finger puts the
/// pointer where it touches and clicks there; two or more are still fingers on the Mac's trackpad.
/// Only fingers count: a real trackpad or mouse goes through HardwareMouse.
struct Trackpad: UIViewRepresentable {
    /// Four fingers tapped together: the session shows its hidden controls.
    static let revealTap = Notification.Name("henge.trackpad.revealTap")

    /// This surface lies over the Mac's screen, so Direct touch can apply to it.
    let overScreen: Bool
    @AppStorage(SettingKey.touchMode.rawValue) private var mode = PointerMode.trackpad
    @AppStorage(SettingKey.touchHold.rawValue) private var hold = SettingDefault.touchHold
    @AppStorage(SettingKey.touchTapDrag.rawValue) private var tapDrag = SettingDefault.touchTapDrag
    @AppStorage(SettingKey.scrollSpeed.rawValue) private var scrollSpeed = SettingDefault.scrollSpeed

    init(overScreen: Bool = false) { self.overScreen = overScreen }

    func makeUIView(context: Context) -> Surface { Surface() }

    func updateUIView(_ view: Surface, context: Context) {
        view.direct = overScreen && mode == .direct
        view.timing = TouchTiming.timing(hold: hold, tapDrag: tapDrag)
        view.scrollFactor = HardwareMouse.scrollFactor(scrollSpeed)
    }

    static func dismantleUIView(_ view: Surface, coordinator: Void) { view.cancel() }

    final class Surface: UIView, UIPointerInteractionDelegate, UIDropInteractionDelegate {
        /// The emulated pad's sensor, in the Magic Trackpad 2's own units.
        private static let sensorW: Int32 = 8134
        private static let sensorH: Int32 = 5206

        var direct = false
        var timing = TouchGestures.Timing() {
            didSet {
                gestures.timing = timing
                if directGesture { gestures.timing.tapDrag = 0 }
            }
        }
        /// Two-finger scrolling's speed, 1 as the Mac has it: the fingers' shared motion is scaled, the
        /// distance between them is not, so pinching and rotating stay as they are.
        var scrollFactor: CGFloat = 1

        private struct Finger {
            var touch: UITouch
            var id: Int32
            var last: CGPoint  // where it was at its last sample, in the view
            var onPad: Bool    // the Mac's trackpad has it (always, but for one finger in Direct touch)
        }

        private var fingers: [Finger] = []
        private var freeIds = Set<Int32>(1...5) /* a touch screen reports five fingers at most */
        private var gestures = TouchGestures()
        private var timer: Timer?
        private var scrollOffset = CGPoint.zero
        private var directGesture = false // this gesture's single finger is the pointer itself
        private var leftDirect = false    // the left button went down on the absolute pointer
        private var touchesLogged = 0
        private let buzz = UIImpactFeedbackGenerator(style: .medium)

        override init(frame: CGRect) {
            super.init(frame: frame)
            isMultipleTouchEnabled = true
            backgroundColor = .clear
            addInteraction(UIPointerInteraction(delegate: self))
            addInteraction(UIDropInteraction(delegate: self))
        }

        /* Files dropped on the Mac go into the Shared folder (the Mac's ~/Henge). */
        func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
            session.hasItemsConforming(toTypeIdentifiers: [UTType.item.identifier])
        }

        func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
            UIDropProposal(operation: .copy)
        }

        func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
            Sharing.receive(session.items.map(\.itemProvider))
            buzz.impactOccurred()
        }

        /// Over the Mac there is only the Mac's pointer, if iPadOS hasn't locked its own away.
        func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? { .hidden() }

        required init?(coder: NSCoder) { fatalError("made in code") }

        /// Where a point is on the pad's sensor, in its units.
        private func sensor(_ p: CGPoint) -> (Int32, Int32) {
            // One scale for both axes. The view and the pad's sensor are different
            // shapes, so stretching the view to fill the sensor would make a finger
            // move the pointer further on one axis than the other. Map the view to a
            // centred part of the sensor at a single scale instead.
            let w = max(Double(bounds.width), 1), h = max(Double(bounds.height), 1)
            let scale = min(Double(Self.sensorW) / w, Double(Self.sensorH) / h)
            let x = (Double(p.x) - w / 2) * scale + Double(Self.sensorW) / 2
            let y = (Double(p.y) - h / 2) * scale + Double(Self.sensorH) / 2
            return (Int32(min(max(x, 0), Double(Self.sensorW))),
                    Int32(min(max(y, 0), Double(Self.sensorH))))
        }

        private func padPoint(_ p: CGPoint) -> (Int32, Int32) {
            sensor(CGPoint(x: p.x + scrollOffset.x, y: p.y + scrollOffset.y))
        }

        /* A touch sample's own clock, in ms. The guest derives finger speed from the
           timestamp deltas, so reports must carry the sample time, not the moment we
           process the event -- otherwise a burst of samples reads as one enormous flick
           and scroll inertia goes wild on release. */
        private static func ms(_ t: TimeInterval) -> UInt32 { UInt32(truncatingIfNeeded: Int(t * 1000)) }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            let touches = touches.filter { $0.type != .indirectPointer }
            guard !touches.isEmpty else { return }
            let now = touches.map(\.timestamp).max() ?? ProcessInfo.processInfo.systemUptime
            if fingers.isEmpty {
                scrollOffset = .zero
                directGesture = direct && DirectTouch.available
                // Touching elsewhere on the screen soon after a tap must not drag there: in Direct touch a
                // tap clicks at once, and a drag starts with a hold.
                gestures.timing.tapDrag = directGesture ? 0 : timing.tapDrag
                buzz.prepare()
            }
            for t in touches {
                guard let id = freeIds.min() else { break }
                freeIds.remove(id)
                fingers.append(Finger(touch: t, id: id, last: t.location(in: self), onPad: false))
            }
            if directGesture && fingers.count == 1 {
                DirectTouch.point(at: fingers[0].touch.location(in: nil))
            } else {
                // Every finger is on the Mac's trackpad, the one Direct touch held back too.
                for i in fingers.indices where !fingers[i].onPad {
                    fingers[i].onPad = true
                    let (x, y) = padPoint(fingers[i].last)
                    henge_vm_touch(fingers[i].id, 0, x, y, Self.ms(fingers[i].touch.timestamp))
                    if touchesLogged < 12 {
                        touchesLogged += 1
                        HengeLog.log("input", "trackpad: finger \(fingers[i].id) down at \(x),\(y)")
                    }
                }
            }
            perform(gestures.touched(count: fingers.count, at: now))
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            /* A drag with the iPad's own pointer, while it isn't locked: the Mac's pointer follows it. */
            if let t = touches.first(where: { $0.type == .indirectPointer }) { AbsolutePointer.move(to: t.location(in: nil)) }
            /* Every sample since the last event (120 Hz on a ProMotion screen), each with its own time,
               grouped by time so a gesture's fingers move together in one frame. */
            var samples: [(time: TimeInterval, finger: Int, at: CGPoint)] = []
            for t in touches where t.type != .indirectPointer {
                guard let i = fingers.firstIndex(where: { $0.touch == t }) else { continue }
                for s in event?.coalescedTouches(for: t) ?? [t] { samples.append((s.timestamp, i, s.location(in: self))) }
            }
            guard !samples.isEmpty else { return }
            samples.sort { $0.time < $1.time }
            let scrolling = fingers.count == 2 && fingers.allSatisfy(\.onPad) && scrollFactor != 1
            var travelled: CGFloat = 0
            var at = 0
            while at < samples.count {
                let ms = Self.ms(samples[at].time)
                var sentToPad = false
                while at < samples.count, Self.ms(samples[at].time) == ms {
                    let (i, p) = (samples[at].finger, samples[at].at)
                    let d = CGPoint(x: p.x - fingers[i].last.x, y: p.y - fingers[i].last.y)
                    fingers[i].last = p
                    travelled += abs(d.x) + abs(d.y)
                    if scrolling {
                        scrollOffset.x += d.x * (scrollFactor - 1) / 2
                        scrollOffset.y += d.y * (scrollFactor - 1) / 2
                    }
                    if fingers[i].onPad {
                        let (x, y) = padPoint(p)
                        henge_vm_touch(fingers[i].id, 1, x, y, ms)
                        sentToPad = true
                    } else {
                        DirectTouch.point(at: convert(p, to: nil))
                    }
                    at += 1
                }
                if sentToPad { henge_vm_touch_frame(ms) }
            }
            perform(gestures.moved(by: Double(travelled), at: samples[samples.count - 1].time))
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { lift(touches) }
        /// iOS took the touches (an alert, a call, a system edge swipe): never a tap; what is down comes up.
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { cancel() }

        private func lift(_ touches: Set<UITouch>) {
            var lifted: [Int32] = []
            fingers.removeAll { finger in
                guard touches.contains(finger.touch), finger.touch.type != .indirectPointer else { return false }
                freeIds.insert(finger.id)
                if finger.onPad { lifted.append(finger.id) }
                return true
            }
            let ts = touches.map(\.timestamp).max() ?? ProcessInfo.processInfo.systemUptime
            for id in lifted { henge_vm_touch(id, 2, 0, 0, Self.ms(ts)) }
            perform(gestures.lifted(remaining: fingers.count, at: ts))
        }

        /// The view is going away: nothing stays down.
        func cancel() {
            for finger in fingers where finger.onPad { henge_vm_touch(finger.id, 2, 0, 0, Self.ms(ProcessInfo.processInfo.systemUptime)) }
            fingers.removeAll()
            freeIds = Set(1...5)
            perform(gestures.cancel())
            timer?.invalidate()
            timer = nil
        }

        private func perform(_ actions: [TouchGestures.Action]) {
            for action in actions {
                switch action {
                case .press(let b): mouseButton(b, down: true)
                case .release(let b): mouseButton(b, down: false)
                case .click(let b):
                    mouseButton(b, down: true)
                    mouseButton(b, down: false)
                case .reveal: NotificationCenter.default.post(name: Trackpad.revealTap, object: nil)
                case .haptic: buzz.impactOccurred()
                case .modifiersUsed: StickyKeys.shared.used()
                }
            }
            schedule()
        }

        /// The left button goes where the pointer is: in Direct touch with the pointer's own report, so a
        /// click lands exactly where the finger touched; the right click is always the trackpad's own.
        private func mouseButton(_ button: Int32, down: Bool) {
            if button == 0 && down { leftDirect = directGesture } // it comes up the way it went down
            if button == 0 && leftDirect { DirectTouch.button(down) }
            else { henge_vm_mouse_button(button, down ? 1 : 0) }
        }

        /// A timer for the gestures' next deadline (a tap's release, a hold).
        private func schedule() {
            timer?.invalidate()
            timer = nil
            guard let deadline = gestures.deadline else { return }
            let wait = max(0, deadline - ProcessInfo.processInfo.systemUptime)
            let timer = Timer(timeInterval: wait, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.perform(self.gestures.tick(at: max(deadline, ProcessInfo.processInfo.systemUptime)))
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }
}

/// One mouse button you can hold: down when touched, up when let go.
struct MouseButton: View {
    let title: String
    let button: Int32
    @State private var down = false

    var body: some View {
        Text(title)
            .font(.system(size: 15))
            .foregroundStyle(down ? Desk.text : Desk.dim)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(down ? Desk.raised : Color.clear)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !down else { return }
                        down = true
                        henge_vm_mouse_button(button, 1)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                    .onEnded { _ in
                        down = false
                        henge_vm_mouse_button(button, 0)
                        StickyKeys.shared.used()
                    }
            )
            .accessibilityLabel(title)
    }
}
