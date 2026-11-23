import SwiftUI
import QuartzCore
import CoreGraphics

/// The Mac's screen, refreshed a few times a second: what its GPU draws once
/// macOS is up. Before that, the boot framebuffer, which only ever holds the
/// progress bar (a virtual Mac's firmware draws no logo into it), so the logo
/// over it is the app's own.
struct BootDisplay: View {
    let display: DisplayRouter
    let role: DisplayTargetSelection.Role
    /// The id this view's layer connects to the router under.
    var surface = UUID()
    /// Rounded corners, on the Metal layer itself (cornerRadius) rather than a mask over it.
    var cornerRadius: CGFloat = 0

    @State private var image: CGImage?
    @State private var gpuLive = false
    @State private var stopped = false
    @AppStorage("henge.matchScreenColors") private var matchScreenColors = true
    @AppStorage("henge.display.brightness") private var screenBrightness = 1.0

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(Color.black)
            if !stopped {
                if !gpuLive {
                    if let image {
                        Image(decorative: image, scale: 1).resizable().interpolation(.medium).aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                        if image.height > image.width {
                            Image(systemName: "apple.logo")
                                .font(.system(size: 44))
                                .foregroundStyle(.white)
                        }
                    } else {
                        Image(systemName: "apple.logo")
                            .font(.system(size: 44))
                            .foregroundStyle(.white)
                    }
                }
                GPUScreen(display: display, role: role, surface: surface, cornerRadius: cornerRadius,
                          matchScreenColors: matchScreenColors, brightness: screenBrightness)
                    .allowsHitTesting(false)
            }
        }
        .task {
            var generation = henge_vm_generation()
            // Keep watching the lifecycle after the GPU takes over. Removing
            // GPUScreen clears its last frame on both device and external screens.
            while !Task.isCancelled {
                let next = henge_vm_generation(), state = henge_vm_state()
                if next != generation {
                    generation = next
                    gpuLive = false
                    image = nil
                }
                if state == HENGE_VM_STOPPED || state == HENGE_VM_STARTING_OR_STOPPING {
                    stopped = true
                    image = nil
                    gpuLive = false
                } else {
                    stopped = false
                    if !gpuLive && henge_vm_gpu_frames() > 0 {
                        gpuLive = true
                        image = nil
                    }
                    if !gpuLive { image = Self.snapshot() ?? image }
                }
                // The boot screen is a progress bar: 4 a second is plenty. Once the GPU draws (or the Mac is off) only
                // the lifecycle is watched, once a second.
                try? await Task.sleep(nanoseconds: gpuLive || stopped ? 1_000_000_000 : 250_000_000)
            }
        }
    }

    /// The boot framebuffer's size last time: the engine copies it once, straight into the buffer the image keeps.
    private static var frameBytes = 0

    static func snapshot() -> CGImage? {
        var w: Int32 = 0, h: Int32 = 0, stride: Int32 = 0
        for _ in 0..<2 { // the second time with the size the first one said it needs
            let cap = max(frameBytes, 1)
            guard let buffer = malloc(cap) else { return nil }
            guard henge_vm_boot_display_copy(buffer.assumingMemoryBound(to: UInt8.self), cap, &w, &h, &stride) == 0 else {
                free(buffer)
                let need = Int(stride) * Int(h)
                guard need > cap else { return nil } // nothing to show yet
                frameBytes = need
                continue
            }
            let data = Data(bytesNoCopy: buffer, count: Int(stride) * Int(h), deallocator: .free) // the image's own: the guest keeps drawing
            return image(data, width: Int(w), height: Int(h), stride: Int(stride))
        }
        return nil
    }

    private static func image(_ data: Data, width w: Int, height h: Int, stride: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info, provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// A layer the engine draws the Mac's frames into, with the GPU, without the main thread.
private struct GPUScreen: UIViewRepresentable {
    let display: DisplayRouter
    let role: DisplayTargetSelection.Role
    let surface: UUID
    let cornerRadius: CGFloat
    let matchScreenColors: Bool
    let brightness: Double
    private static let srgb = CGColorSpace(name: CGColorSpace.sRGB)

    final class Screen: UIView {
        override class var layerClass: AnyClass { CAMetalLayer.self }

        private let id: UUID
        private let display: DisplayRouter
        private let role: DisplayTargetSelection.Role
        private var attached = false
        private var lastSize: CGSize = .zero
        /// The brightness the engine last drew with: it dims the frame itself (the layer stays opaque).
        var shownBrightness: Double?

        init(display: DisplayRouter, role: DisplayTargetSelection.Role, surface: UUID) {
            self.id = surface
            self.display = display
            self.role = role
            super.init(frame: .zero)
            // Clear until the engine's first frame is on it (the boot screen shows through); the engine makes the
            // layer opaque then, so the system compositor does not blend it, and puts the pointer on a sublayer.
            backgroundColor = .clear
            isOpaque = false
            layer.contentsGravity = .resizeAspect
            layer.isOpaque = false
        }

        required init?(coder: NSCoder) { fatalError("made in code") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { detach() } else { attachIfReady() }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            attachIfReady()
        }

        private func attachIfReady() {
            guard window != nil, bounds.width > 0, bounds.height > 0,
                  let metal = layer as? CAMetalLayer else { return }
            if !attached {
                attached = true
                lastSize = bounds.size
                display.connect(id, layer: metal, role: role)
            } else if lastSize != bounds.size {
                lastSize = bounds.size
                display.refresh(id)
            }
        }

        func detach() {
            guard attached else { return }
            attached = false
            display.disconnect(id)
        }
    }

    @MainActor private func setCorners(_ view: Screen) {
        view.layer.cornerRadius = cornerRadius
        view.layer.cornerCurve = .continuous
        view.layer.masksToBounds = cornerRadius > 0
    }

    @MainActor private func setColorSpace(_ view: Screen) {
        let metalLayer = view.layer as! CAMetalLayer
        // The guest's display profile is sRGB, and the presenter writes sRGB
        // values. A nil colorspace skips matching on wide-gamut iPad screens.
        metalLayer.colorspace = matchScreenColors ? Self.srgb : nil
        // Brightness: the engine reads henge.display.brightness and dims the frame as it draws it (an opaque
        // layer needs no blending by the system compositor, where a dimmed view did). A change draws it again.
        if view.shownBrightness == nil {
            view.shownBrightness = brightness
        } else if view.shownBrightness != brightness {
            view.shownBrightness = brightness
            display.refresh()
        }
    }

    func makeUIView(context: Context) -> Screen {
        if ProcessInfo.processInfo.environment["HV_COLOR_PROBE"] != nil {
            // What the screen itself is, for the colour probe (the engine logs the layer and the frames).
            let s = UIScreen.main
            let gamut = s.traitCollection.displayGamut == .P3 ? "P3" : s.traitCollection.displayGamut == .SRGB ? "sRGB" : "unspecified"
            HengeLog.log("colorprobe", "colorprobe: v=1 src=swift event=screen gamut=\(gamut) scale=\(s.scale) nativeScale=\(s.nativeScale) "
                       + "bounds=\(Int(s.bounds.width))x\(Int(s.bounds.height)) maxEDR=\(s.potentialEDRHeadroom) currentEDR=\(s.currentEDRHeadroom) "
                       + "brightness=\(String(format: "%.2f", s.brightness)) refreshHz=\(s.maximumFramesPerSecond)")
        }
        let view = Screen(display: display, role: role, surface: surface)
        setColorSpace(view)
        setCorners(view)
        return view
    }
    func updateUIView(_ view: Screen, context: Context) {
        setColorSpace(view)
        setCorners(view)
    }
    static func dismantleUIView(_ view: Screen, coordinator: ()) { view.detach() }
}
