import Foundation
import CoreGraphics

/// MacScreen's presets on an iPhone 16 Pro, an iPad Air 4 and an iPad Pro 11" (M4), the migration of Macs made before
/// presets, the pixel snapping and the refresh choices.
@main
struct MacScreenTests {
    static var failures = 0

    static func check(_ condition: Bool, _ message: String) {
        if !condition { failures += 1; print("FAIL: \(message)") }
    }

    static func px(_ w: Int, _ h: Int) -> PixelSize { PixelSize(width: w, height: h) }

    static func main() {
        // iPhone 16 Pro: 2622 × 1206 at 3x, 460 ppi, 8 GB; landscape safe area 750 × 402 points (62-point side insets).
        let phone = ScreenFacts(panel: px(2622, 1206), scale: 3, sideInset: 62, ppi: DeviceProfile.ppi(isPad: false, scale: 3, mini: false),
                                kind: DeviceProfile(physicalMB: 7_680, performanceCores: 2, memoryLimitMB: 6_144, extendedAddressing: false, isPad: false).screenClass)
        check(phone.kind == .phone && phone.ppi == 460, "iPhone 16 Pro: a phone at 460 ppi")
        let (aw, ah) = phone.area
        let rec = MacScreen.size(.recommended, phone)
        check(rec.pixels == px(MacScreen.floor8(864 * aw / ah), 864) && rec.mm == nil && !rec.crisp,
              "phone: 864 tall in the safe area's shape at 1x, soft (\(rec.pixels))")
        check(Double(rec.pixels.width) * rec.factor <= aw, "phone: clear of the Dynamic Island")
        let retina = MacScreen.size(.retina, phone)
        check(retina.pixels == px(MacScreen.floor8(aw), MacScreen.floor8(ah)) && retina.factor == 1 && retina.crisp,
              "phone Retina: the safe area at 1:1 (\(retina.pixels))")
        check(retina.looksLike == px(retina.pixels.width / 2, retina.pixels.height / 2), "phone Retina looks like half")
        check(retina.mm == px(124, 66), "phone Retina: millimetres from 460 ppi (\(String(describing: retina.mm)))")
        check(MacScreen.line(retina, against: rec).hasSuffix("heavier for the Mac"), "phone Retina is heavier")
        check(MacScreen.line(MacScreen.size(.larger, phone), against: rec).hasSuffix("lighter for the Mac"), "Larger Text is lighter")
        let phoneList = MacScreen.offered(phone).map(\.preset)
        check(phoneList == [.recommended, .moreSpace, .larger, .retina], "phone offers all four")
        // An inset only narrows the desktop; the height stays.
        var wide = phone; wide.sideInset = 49
        check(MacScreen.size(.recommended, wide).pixels.height == 864 && MacScreen.size(.recommended, wide).pixels.width > rec.pixels.width,
              "phone: 864 tall whatever the inset")

        // iPad Air 4: 2360 × 1640 at 2x, 264 ppi, 4 GB (a 2 GB Mac).
        let air = ScreenFacts(panel: px(2360, 1640), scale: 2, sideInset: 0, ppi: DeviceProfile.ppi(isPad: true, scale: 2, mini: false),
                              kind: DeviceProfile(physicalMB: 3_800, performanceCores: 2, memoryLimitMB: 3_000, extendedAddressing: false, isPad: true).screenClass)
        check(air.kind == .leanPad && air.ppi == 264, "Air 4: a lean iPad at 264 ppi")
        let airRec = MacScreen.size(.recommended, air)
        check(airRec.pixels == px(1176, 816) && airRec.factor == 2 && airRec.crisp, "Air 4: half the panel at exactly 2x (\(airRec.pixels) \(airRec.factor))")
        check(airRec.pixels.width * airRec.pixels.height < 1280 * 888 * 85 / 100, "Air 4: at least 15% fewer pixels than 1280 × 888")
        check(!MacScreen.offered(air).contains { $0.preset == .retina }, "Air 4: no Retina with a 2 GB Mac")
        check(MacScreen.resolve(.retina, air) == airRec, "a preset not offered falls back to Recommended")
        check(MacScreen.size(.larger, air).pixels.height >= MacScreen.minHeight, "Larger Text never under 640 tall")

        // iPad Pro 11" (M4): 2420 × 1668 at 2x, 264 ppi, 16 GB.
        let pro = ScreenFacts(panel: px(2420, 1668), scale: 2, sideInset: 0, ppi: 264,
                              kind: DeviceProfile(physicalMB: 15_800, performanceCores: 4, memoryLimitMB: 12_000, extendedAddressing: true, isPad: true).screenClass)
        let proRec = MacScreen.size(.recommended, pro)
        check(proRec.pixels == px(2416, 1664) && proRec.factor == 1 && proRec.mm == px(232, 160), "Pro: the native panel at Retina density (\(proRec))")
        check(MacScreen.offered(pro).map(\.preset) == [.recommended, .moreSpace, .larger], "Pro: Retina is Recommended, not listed twice")
        check(MacScreen.size(.larger, pro).crisp, "Pro: Larger Text at a whole factor")

        // Every class and preset: multiples of 8, inside the area, at least 1x.
        for kind in [DeviceProfile.ScreenClass.phone, .leanPhone, .pad, .leanPad, .bigPad] {
            for facts in [phone, air, pro] {
                var f = facts; f.kind = kind
                for preset in ScreenPreset.allCases {
                    let s = MacScreen.size(preset, f)
                    check(s.pixels.width % 8 == 0 && s.pixels.height % 8 == 0, "\(kind) \(preset): multiples of 8")
                    check(s.factor >= 1 && Double(s.pixels.width) <= f.area.width && Double(s.pixels.height) <= f.area.height, "\(kind) \(preset): fits")
                }
            }
        }

        // Macs made before presets.
        let phoneLegacy = MacScreen.legacyDefault(pointsLong: 874, pointsShort: 402, isPad: false, lean: false, ramGB: 3)
        check(phoneLegacy.width == 1920 && phoneLegacy.height == 1080 && phoneLegacy.uiScale == 0.8, "the old phone default")
        check(MacScreen.migrate(width: 1920, height: 1080, retina: nil, uiScale: 0.8, legacy: phoneLegacy, facts: phone) == .recommended, "old default → Recommended")
        check(MacScreen.migrate(width: 1920, height: 1080, retina: nil, uiScale: nil, legacy: phoneLegacy, facts: phone) == .moreSpace, "old 1920 × 1080 → More Space")
        check(MacScreen.migrate(width: 1920, height: 1080, retina: nil, uiScale: 2.0 / 3, legacy: phoneLegacy, facts: phone) == .larger, "old Larger → Larger Text")
        let airLegacy = MacScreen.legacyDefault(pointsLong: 1180, pointsShort: 820, isPad: true, lean: true, ramGB: 2)
        check(airLegacy.width == 1920 && airLegacy.height == 1336 && airLegacy.uiScale == 2.0 / 3, "the old Air 4 default (1280 × 888 after 2/3)")
        check(MacScreen.migrate(width: 1920, height: 1336, retina: false, uiScale: 2.0 / 3, legacy: airLegacy, facts: air) == .recommended, "Air 4 old default → Recommended")
        check(MacScreen.migrate(width: 1920, height: 1336, retina: true, uiScale: nil, legacy: airLegacy, facts: air) == .moreSpace, "Air 4 old Retina → More Space")
        check(MacScreen.migrate(width: nil, height: nil, retina: true, uiScale: nil, legacy: airLegacy, facts: pro) == .recommended, "Pro old Retina → its Retina Recommended")

        // Pixel snapping.
        let snapped = PixelFit.fit(CGSize(width: 1176, height: 816), in: CGRect(x: 0, y: 0, width: 1180, height: 820), scale: 2)
        check(snapped == CGRect(x: 2, y: 2, width: 1176, height: 816), "a 2x fit is exact and centred (\(snapped))")
        let soft = PixelFit.fit(CGSize(width: rec.pixels.width, height: rec.pixels.height), in: CGRect(x: 62, y: 0, width: 750, height: 402), scale: 3)
        for v in [soft.minX, soft.minY, soft.width, soft.height] { check((v * 3).rounded() == v * 3, "edges on device pixels (\(soft))") }
        check(soft.height == 402 && abs(soft.midX - (62 + 375)) <= 1.0 / 3, "a soft fit fills the height, centred in the safe area (\(soft))")

        // iPhone 13 mini: 375 × 812 points at scale 3, 1125 × 2436 render pixels (the panel itself is 1080 × 2340, at
        // 2.88). Sized in render pixels, a Mac's screen is laid out at the factor MacScreen gives it: a whole one stays whole.
        let mini = ScreenFacts.landscape(points: CGSize(width: 375, height: 812), scale: 3, sideInset: 50,
                                         ppi: DeviceProfile.ppi(isPad: false, scale: 3, mini: true), kind: .leanPhone)
        check(mini.panel == px(2436, 1125) && mini.scale == 3, "mini: render pixels, not the panel's (\(mini.panel))")
        for choice in MacScreen.offered(mini) {
            let s = choice.screen
            let shown = PixelFit.fit(CGSize(width: s.pixels.width, height: s.pixels.height),
                                     in: CGRect(x: 50, y: 0, width: 812 - 2 * 50, height: 375), scale: 3)
            let factor = Double(shown.width) * 3 / Double(s.pixels.width)
            check(abs(factor - s.factor) * Double(s.pixels.width) < 1, "mini \(choice.preset): laid out at MacScreen's factor (\(factor), \(s.factor))")
            if s.crisp { check(abs(factor - s.factor) < 1e-9, "mini \(choice.preset): a whole factor is whole on screen (\(factor))") }
        }

        // Refresh rates the panel can show.
        check(DeviceProfile.refreshChoices(panelMax: 60) == [30, 60], "a 60 Hz panel: no 120")
        check(DeviceProfile.refreshChoices(panelMax: 120) == [30, 60, 120], "ProMotion: up to 120")

        if failures > 0 { print("\(failures) failed"); exit(1) }
        print("mac screen: all passed")
    }
}
