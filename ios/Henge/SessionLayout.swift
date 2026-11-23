import SwiftUI

/// Where a session's screen, trackpad and controls go, and the zoomed view that follows the pointer.
extension SessionView {
    // MARK: Layout

    /// Where everything goes, in points from the device's top left corner.
    struct Layout {
        let screen: CGRect
        let touch: CGRect     // what is a trackpad besides the pad itself
        let fillsPhone: Bool
        let toolsY: CGFloat
        let pad: CGRect
        let insets: EdgeInsets
        var barY: CGFloat?    // where the controls go in the space beside the screen, if it has room for them
        let pixels: CGSize    // the Mac's screen, in its own pixels

        var shown: CGSize {
            CGSize(width: min(touch.width / max(screen.width, 1), 1), height: min(touch.height / max(screen.height, 1), 1))
        }

        /// The Mac's pixel under a point of the session view (for direct touch): the screen's rectangle maps to
        /// 0...width-1 and 0...height-1; a point outside it gives the nearest edge pixel.
        func macPixel(at point: CGPoint) -> CGPoint {
            let x = (point.x - screen.minX) / max(screen.width, 1) * pixels.width
            let y = (point.y - screen.minY) / max(screen.height, 1) * pixels.height
            return CGPoint(x: min(max(x.rounded(.down), 0), max(pixels.width - 1, 0)),
                           y: min(max(y.rounded(.down), 0), max(pixels.height - 1, 0)))
        }

        /// pixels: the Mac's screen; scale: device pixels per point. Unzoomed, the screen sits on whole device pixels,
        /// at an exact whole factor where the fit is just above one (PixelFit), so nearest scaling maps every pixel alike.
        init(full: CGSize, insets: EdgeInsets, landscape: Bool, zoomed: Bool, typing: Bool, centre: CGPoint, pixels: CGSize, scale: CGFloat) {
            self.insets = insets
            self.pixels = pixels
            let aspect = pixels.width / max(pixels.height, 1)
            let big = full.height >= 600 // an iPad on its side, or a window on one
            if zoomed {
                // Upright, as tall as the device. On its side, bigger than it fits: a big screen needs less.
                let height = landscape ? full.height * (big ? 1.5 : 2) : max(full.height - insets.bottom, full.width / aspect)
                let width = height * aspect
                let x = min(0, max(full.width - width, full.width / 2 - centre.x * width))
                let y = min(0, max(full.height - height, full.height / 2 - centre.y * height))
                screen = CGRect(x: x, y: y, width: width, height: height)
                touch = CGRect(origin: .zero, size: full)
                fillsPhone = true
                toolsY = 0
                pad = .zero
            } else if landscape, big {
                // Room to keep the controls off the Mac's menu bar, and the Mac above the on-screen keyboard.
                let bar: CGFloat = 62
                let room = typing ? full.height - insets.bottom - insets.top - bar - 8 : full.height
                // An iPad keeps clear of its side insets; a big iPhone (iPhone Duo) fills edge to edge.
                let side = Device.isPad ? max(insets.leading, insets.trailing) : 0
                let area = CGRect(x: side, y: typing ? insets.top + bar : 0, width: full.width - 2 * side, height: max(room, 200))
                var fit = PixelFit.fit(pixels, in: area, scale: scale)
                if typing { fit.origin.y = area.minY }
                screen = fit
                touch = CGRect(origin: .zero, size: full)
                fillsPhone = true
                toolsY = 0
                pad = .zero
                if fit.minY - insets.top >= 54 { barY = insets.top + (fit.minY - insets.top) / 2 }
            } else if landscape {
                // The full height, centred in the safe area: clear of the Dynamic Island or notch by the same inset at
                // both sides, so a turn by 180 degrees moves nothing (the Mac's screen is sized for that area, MacScreen).
                let side = max(insets.leading, insets.trailing)
                screen = PixelFit.fit(pixels, in: CGRect(x: side, y: 0, width: full.width - 2 * side, height: full.height), scale: scale)
                touch = CGRect(origin: .zero, size: full)
                fillsPhone = true
                toolsY = 0
                pad = .zero
            } else {
                let width = full.width - 16
                screen = PixelFit.fit(pixels, in: CGRect(x: 8, y: insets.top + 6, width: width, height: width / aspect), scale: scale)
                touch = screen
                fillsPhone = false
                toolsY = screen.maxY + 10
                let top = typing ? screen.maxY + 8 : toolsY + 54 + 10
                let bottom = full.height - insets.bottom - (typing ? 8 : 0)
                pad = CGRect(x: 8, y: top, width: width, height: max(bottom - top, 60))
            }
        }
    }

    // MARK: Zoom

    /// The whole screen, small, with where the zoomed view is on it.
    func zoomMap(_ layout: Layout) -> some View {
        let width: CGFloat = 112, height = width / mac.aspect
        let viewW = min(layout.touch.width / layout.screen.width, 1) * width
        let viewH = min(layout.touch.height / layout.screen.height, 1) * height
        let left = (-layout.screen.minX / layout.screen.width) * width
        let top = (-layout.screen.minY / layout.screen.height) * height
        return ZStack(alignment: .topLeading) {
            Color.black
            if let map { Image(uiImage: map).resizable() }
            RoundedRectangle(cornerRadius: 3).stroke(Color.white, lineWidth: 1.5)
                .frame(width: viewW, height: viewH)
                .offset(x: left, y: top)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .padding(3)
        .deskGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .position(x: layout.touch.width - width / 2 - 15, y: layout.insets.top + height / 2 + 20)
        .allowsHitTesting(false)
    }

    /// Keeps the pointer in view: the view moves when the pointer nears its edge.
    func followPointer() async {
        var tick = 0
        while !Task.isCancelled {
            var x: Int32 = 0, y: Int32 = 0
            if henge_vm_pointer(&x, &y) == 0 {
                moveZoom(toward: CGPoint(x: CGFloat(x) / CGFloat(mac.screen.width), y: CGFloat(y) / CGFloat(mac.screen.height)))
            }
            if tick % 60 == 0, let image = MacPreview.capture(width: 224, height: Int(224 / mac.aspect)) { map = UIImage(cgImage: image) }
            tick += 1
            try? await Task.sleep(nanoseconds: 33_000_000)
        }
    }

    func moveZoom(toward p: CGPoint) {
        // How much of the screen the view shows, and a margin inside that.
        let shownX = shown.width, shownY = shown.height
        let reachX = shownX * 0.3, reachY = shownY * 0.3
        var c = zoomCentre
        if p.x < c.x - reachX { c.x = p.x + reachX } else if p.x > c.x + reachX { c.x = p.x - reachX }
        if p.y < c.y - reachY { c.y = p.y + reachY } else if p.y > c.y + reachY { c.y = p.y - reachY }
        c.x = min(max(c.x, shownX / 2), 1 - shownX / 2)
        c.y = min(max(c.y, shownY / 2), 1 - shownY / 2)
        guard c != zoomCentre else { return }
        withAnimation(.linear(duration: 0.08)) { zoomCentre = c }
    }
}
