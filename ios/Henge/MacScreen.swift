import Foundation
import CoreGraphics

/// A Mac's screen size, chosen as a preset, and where its pixels go on the device. Pure: the device's facts are passed
/// in (Device.screenFacts passes this device's), so tests/test_mac_screen.swift compiles it with DeviceProfile.swift.

/// One per-Mac choice (stored as its raw value), never pixels: the sizes follow the device the Mac runs on.
enum ScreenPreset: String, Codable, CaseIterable {
    case recommended, moreSpace, larger, retina

    var title: String {
        switch self {
        case .recommended: return "Recommended"
        case .moreSpace: return "More Space"
        case .larger: return "Larger Text"
        case .retina: return "Retina"
        }
    }
}

/// A size in whole pixels (or millimetres).
struct PixelSize: Equatable {
    var width: Int
    var height: Int
}

/// A preset as offered on a device, with the size it gives there.
struct ScreenChoice: Equatable, Identifiable {
    let preset: ScreenPreset
    let screen: MacScreen
    var id: ScreenPreset { preset }
}

/// What the device is, for sizing a Mac's screen. Every length is the device on its side (landscape).
struct ScreenFacts: Equatable {
    var panel: PixelSize       // the panel's pixels, on its side
    var scale: Double          // device pixels per point (UIScreen.scale)
    var sideInset: Double      // points kept clear at each side in landscape (the larger of left and right: a 180° turn moves nothing)
    var ppi: Double            // the panel's real density (DeviceProfile.ppi)
    var kind: DeviceProfile.ScreenClass

    /// The facts of a screen of these points at this scale, in its render pixels (points × scale): the pixels the
    /// layout (PixelFit) and the presenter work in. The panel's own pixels differ where the system scales the render
    /// (iPhone 12 and 13 mini: scale 3, 2.88 native; Display Zoom), and a whole factor counted in them is not whole there.
    static func landscape(points: CGSize, scale: Double, sideInset: Double, ppi: Double, kind: DeviceProfile.ScreenClass) -> ScreenFacts {
        let long = Double(max(points.width, points.height)), short = Double(min(points.width, points.height))
        return ScreenFacts(panel: PixelSize(width: Int((long * scale).rounded()), height: Int((short * scale).rounded())),
                           scale: scale, sideInset: sideInset, ppi: ppi, kind: kind)
    }

    /// Where the Mac may show, in device pixels: the panel less the side insets, full height.
    var area: (width: Double, height: Double) {
        (max(Double(panel.width) - 2 * sideInset * scale, 1), Double(panel.height))
    }
}

/// The screen macOS is given, and how the device shows it.
struct MacScreen: Equatable {
    /// The one display mode macOS gets (multiples of 8).
    var pixels: PixelSize
    /// The panel's real size for a Retina-dense screen (macOS then draws at 2x); nil: the old 400 mm, 1x.
    var mm: PixelSize?
    /// Device pixels per Mac pixel on the device's own screen; a whole number shows every pixel exactly (crisp).
    var factor: Double

    var crisp: Bool { factor == factor.rounded() }
    /// What macOS lays out: half the pixels at 2x.
    var looksLike: PixelSize { mm == nil ? pixels : PixelSize(width: pixels.width / 2, height: pixels.height / 2) }

    /// The least a 1x desktop is tall: lower and menus and dialogs stop fitting.
    static let minHeight = 640
    /// A factor this close to an integer target counts as that integer (the picture is then exact).
    static let integerReach = 0.06
    /// A factor this little above a whole number is shown at that whole number (a few pixels of border, nothing scaled).
    static let snapReach = 0.02

    static func floor8(_ v: Double) -> Int { max(Int(v) / 8 * 8, 8) }

    /// The size a preset gives on a device.
    static func size(_ preset: ScreenPreset, _ facts: ScreenFacts) -> MacScreen {
        let row = DeviceProfile.screenRow(facts.kind)
        let target: DeviceProfile.ScreenTarget
        switch preset {
        case .recommended: target = row.recommended
        case .moreSpace: target = row.moreSpace
        case .larger: target = row.larger
        case .retina: target = .native
        }
        return size(target, facts)
    }

    static func size(_ target: DeviceProfile.ScreenTarget, _ facts: ScreenFacts) -> MacScreen {
        let (aw, ah) = facts.area
        var w: Int, h: Int
        var mm: PixelSize?
        switch target {
        case .native:
            w = floor8(aw); h = floor8(ah)
            mm = PixelSize(width: Int((Double(w) / facts.ppi * 25.4).rounded()), height: Int((Double(h) / facts.ppi * 25.4).rounded()))
        case .height(let tall):
            // A whole on-screen factor where one is near: then the pixels map exactly.
            let f = ah / Double(tall), k = f.rounded()
            if k >= 2, abs(f - k) <= integerReach * f {
                w = floor8(aw / k); h = floor8(ah / k)
            } else {
                h = floor8(Double(tall)); w = floor8(Double(h) * aw / ah)
            }
        case .factor(let f):
            w = floor8(aw / f); h = floor8(ah / f)
        }
        if mm == nil, h < minHeight {
            h = min(minHeight, floor8(ah)); w = floor8(Double(h) * aw / ah)
        }
        if Double(w) > aw || Double(h) > ah { w = min(w, floor8(aw)); h = min(h, floor8(ah)) }
        return MacScreen(pixels: PixelSize(width: w, height: h), mm: mm, factor: wholeFactor(min(aw / Double(w), ah / Double(h))))
    }

    /// A factor just above a whole number becomes it.
    static func wholeFactor(_ f: Double) -> Double {
        let k = f.rounded(.down)
        return k >= 1 && f - k < snapReach * f ? k : f
    }

    /// The presets this device offers, in order, each with its size: Retina only where the device's row allows it, and
    /// none that only repeats an earlier one (on an iPad Pro the recommended size is Retina).
    static func offered(_ facts: ScreenFacts) -> [ScreenChoice] {
        var list: [ScreenChoice] = []
        for preset in ScreenPreset.allCases where preset != .retina || DeviceProfile.screenRow(facts.kind).retina {
            let s = size(preset, facts)
            if !list.contains(where: { $0.screen == s }) { list.append(ScreenChoice(preset: preset, screen: s)) }
        }
        return list
    }

    /// The size a stored choice gives: one this device does not offer falls back to Recommended.
    static func resolve(_ preset: ScreenPreset, _ facts: ScreenFacts) -> MacScreen {
        offered(facts).first { $0.preset == preset }?.screen ?? size(.recommended, facts)
    }

    /// The line the picker shows under a preset: "looks like 1608 × 864 · crisp · lighter for the Mac".
    static func line(_ s: MacScreen, against recommended: MacScreen) -> String {
        var parts = ["looks like \(s.looksLike.width) × \(s.looksLike.height)", s.crisp ? "crisp" : "soft"]
        let mine = s.pixels.width * s.pixels.height, base = recommended.pixels.width * recommended.pixels.height
        if mine < base { parts.append("lighter for the Mac") } else if mine > base { parts.append("heavier for the Mac") }
        return parts.joined(separator: " · ")
    }

    // MARK: Macs made before presets

    /// What a new Mac got before presets: 1920 wide in the device's shape (height 1080...1440), 1600 wide and 5/6 as tall
    /// on iPads with more than a 2 GB Mac, then the profile's Size of Things (2/3 on 4 GB devices, 0.8 on phones).
    static func legacyDefault(pointsLong: Double, pointsShort: Double, isPad: Bool, lean: Bool, ramGB: Int)
        -> (width: Int, height: Int, uiScale: Double?) {
        let shape = pointsLong / max(pointsShort, 1)
        let fit = (1920, min(max(Int((1920 / shape / 8).rounded()) * 8, 1080), 1440))
        let performance = (1600, Int((Double(fit.1) * 5 / 6 / 8).rounded()) * 8)
        let base = (lean || isPad) && ramGB > 2 ? performance : fit
        return (base.0, base.1, lean ? 2.0 / 3 : isPad ? nil : 0.8)
    }

    /// The preset for a Mac made before presets: still the old default for this device → Recommended; Retina → Retina
    /// (or More Space where Retina is not offered); any other choice → the 1x preset nearest its old height.
    static func migrate(width: Int?, height: Int?, retina: Bool?, uiScale: Double?,
                        legacy: (width: Int, height: Int, uiScale: Double?), facts: ScreenFacts) -> ScreenPreset {
        let list = offered(facts)
        if retina == true {
            return list.first { $0.screen.mm != nil }?.preset ?? .moreSpace
        }
        let w = width ?? 1920, h = height ?? 1080, k = min(max(uiScale ?? 1, 0.5), 1)
        if w == legacy.width, h == legacy.height, abs(k - min(max(legacy.uiScale ?? 1, 0.5), 1)) < 0.001 { return .recommended }
        let old = Int((Double(h) * k / 8).rounded()) * 8
        let flat = list.filter { $0.screen.mm == nil }
        return flat.min { abs($0.screen.pixels.height - old) < abs($1.screen.pixels.height - old) }?.preset ?? .recommended
    }
}

/// Puts content on whole device pixels: aspect-fit into an area, centred, every edge on a pixel boundary, and at an
/// exact whole factor where the fit is just above one (so nearest-neighbour scaling maps every pixel the same way).
enum PixelFit {
    /// content: the content's size in its own pixels (or any units with whole: false); area and result: points.
    static func fit(_ content: CGSize, in area: CGRect, scale: CGFloat, whole: Bool = true) -> CGRect {
        guard content.width > 0, content.height > 0, area.width > 0, area.height > 0, scale > 0 else { return area }
        var f = min(area.width * scale / content.width, area.height * scale / content.height)
        if whole { f = CGFloat(MacScreen.wholeFactor(Double(f))) }
        // (A hair over: 864 × (1206 / 864) can come out a hair under 1206.)
        let w = (content.width * f + 1e-6).rounded(.down), h = (content.height * f + 1e-6).rounded(.down)
        let x = (area.minX * scale + (area.width * scale - w) / 2).rounded(), y = (area.minY * scale + (area.height * scale - h) / 2).rounded()
        return CGRect(x: x / scale, y: y / scale, width: w / scale, height: h / scale)
    }
}
