import Foundation

@main
struct TouchGesturesTests {
    typealias A = TouchGestures.Action

    static func expect(_ got: [A], _ want: [A], _ what: String) {
        precondition(got == want, "\(what): \(got), expected \(want)")
    }

    static func main() {
        let timing = TouchGestures.Timing()

        // A tap: the button goes down at the lift and up once the tap-and-drag time is over.
        var g = TouchGestures()
        expect(g.touched(count: 1, at: 0), [], "tap: touch")
        expect(g.lifted(remaining: 0, at: 0.1), [.press(0), .haptic], "tap: lift presses")
        precondition(g.deadline == 0.1 + timing.tapDrag, "tap: release due")
        expect(g.tick(at: 0.2), [], "tap: not yet")
        expect(g.tick(at: 0.1 + timing.tapDrag), [.release(0), .modifiersUsed], "tap: released")
        precondition(g.deadline == nil, "tap: nothing due")

        // Without tap-and-drag a tap clicks at once.
        g = TouchGestures(timing: .init(tapDrag: 0))
        _ = g.touched(count: 1, at: 0)
        expect(g.lifted(remaining: 0, at: 0.1), [.click(0), .haptic, .modifiersUsed], "instant tap")

        // A double tap: two clicks, the second right after the first.
        g = TouchGestures()
        _ = g.touched(count: 1, at: 0)
        _ = g.lifted(remaining: 0, at: 0.1)
        expect(g.touched(count: 1, at: 0.2), [], "double tap: second touch keeps the button")
        expect(g.lifted(remaining: 0, at: 0.28), [.release(0), .press(0), .haptic], "double tap: second click")
        expect(g.tick(at: 0.28 + timing.tapDrag), [.release(0), .modifiersUsed], "double tap: released")

        // Hold, then drag.
        g = TouchGestures()
        _ = g.touched(count: 1, at: 0)
        expect(g.tick(at: timing.hold), [.press(0), .haptic], "hold: presses")
        expect(g.moved(by: 50, at: 0.5), [], "hold: drags")
        expect(g.lifted(remaining: 0, at: 1.0), [.release(0), .modifiersUsed], "hold: lets go")
        precondition(g.deadline == nil, "hold: nothing due")

        // Tap, touch again in time and move: a drag with the tap's press.
        g = TouchGestures()
        _ = g.touched(count: 1, at: 0)
        _ = g.lifted(remaining: 0, at: 0.1)
        expect(g.touched(count: 1, at: 0.2), [], "tap-drag: touch again")
        precondition(g.deadline == 0.2 + timing.hold, "tap-drag: no release while touching")
        expect(g.moved(by: 30, at: 0.3), [], "tap-drag: move")
        expect(g.tick(at: 0.2 + timing.hold), [], "tap-drag: no hold press on top")
        expect(g.lifted(remaining: 0, at: 0.8), [.release(0), .modifiersUsed], "tap-drag: lets go")

        // Touching again too late: the tap's click ended, this is a new touch.
        g = TouchGestures()
        _ = g.touched(count: 1, at: 0)
        _ = g.lifted(remaining: 0, at: 0.1)
        expect(g.touched(count: 1, at: 0.1 + timing.tapDrag + 0.05), [.release(0), .modifiersUsed], "late touch: release first")
        expect(g.moved(by: 30, at: 0.6), [], "late touch: pointing")
        expect(g.lifted(remaining: 0, at: 0.7), [], "late touch: no click")

        // A two-finger tap is a right click.
        g = TouchGestures()
        _ = g.touched(count: 1, at: 0)
        _ = g.touched(count: 2, at: 0.01)
        expect(g.lifted(remaining: 1, at: 0.1), [], "two fingers: one lifts")
        expect(g.lifted(remaining: 0, at: 0.11), [.click(1), .haptic, .modifiersUsed], "two fingers: right click")
        precondition(g.deadline == nil, "two fingers: no hold")

        // A four-finger tap shows the controls.
        g = TouchGestures()
        _ = g.touched(count: 4, at: 0)
        expect(g.lifted(remaining: 0, at: 0.1), [.reveal], "four fingers")

        // Moving the pointer clicks nothing, and leaves sticky modifiers alone.
        g = TouchGestures()
        _ = g.touched(count: 1, at: 0)
        _ = g.moved(by: 40, at: 0.1)
        expect(g.tick(at: timing.hold), [], "pointing: no hold")
        expect(g.lifted(remaining: 0, at: 0.5), [], "pointing: no click")

        // A still touch longer than a tap but shorter than a hold: nothing.
        g = TouchGestures()
        _ = g.touched(count: 1, at: 0)
        expect(g.lifted(remaining: 0, at: 0.35), [], "slow touch")

        // A drag that a second finger joins becomes a gesture: the button comes up.
        g = TouchGestures()
        _ = g.touched(count: 1, at: 0)
        _ = g.tick(at: timing.hold)
        expect(g.touched(count: 2, at: 0.5), [.release(0), .modifiersUsed], "drag to gesture")
        expect(g.lifted(remaining: 0, at: 0.9), [], "drag to gesture: lift")

        // Going away lets go of a tap's press.
        g = TouchGestures()
        _ = g.touched(count: 1, at: 0)
        _ = g.lifted(remaining: 0, at: 0.1)
        expect(g.cancel(), [.release(0), .modifiersUsed], "cancel")

        // A short touch iOS takes away (an alert, a call, an edge swipe; Trackpad's touchesCancelled): no click.
        g = TouchGestures()
        _ = g.touched(count: 1, at: 0)
        expect(g.cancel(), [], "cancelled touch: no click")
        precondition(g.deadline == nil, "cancelled touch: nothing due")
        expect(g.tick(at: timing.hold), [], "cancelled touch: no hold press later")
        // Cancelled in a tap-and-drag's second touch: the tap's press comes up, no second click.
        g = TouchGestures()
        _ = g.touched(count: 1, at: 0)
        _ = g.lifted(remaining: 0, at: 0.1)
        _ = g.touched(count: 1, at: 0.2)
        expect(g.cancel(), [.release(0), .modifiersUsed], "cancelled second touch: only the release")
        // Cancelled two-finger touch: no right click.
        g = TouchGestures()
        _ = g.touched(count: 2, at: 0)
        expect(g.cancel(), [], "cancelled two fingers: no right click")
        // After a cancel the next tap is a tap again.
        _ = g.touched(count: 1, at: 1)
        expect(g.lifted(remaining: 0, at: 1.1), [.press(0), .haptic], "tap after a cancel")
        print("touch gestures ok")
    }
}
