import UIKit

/// The picture of a Mac as it was last seen, kept beside its disk.
enum MacPreview {
    static func file(for mac: VirtualMac) -> URL { mac.directory.appendingPathComponent("preview.jpg") }

    static func capture(width: Int, height: Int) -> CGImage? {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard solstice_vm_snapshot(&pixels, Int32(width), Int32(height)) == 0 else { return nil }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info, provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Off the main thread.
    static func save(for mac: VirtualMac) {
        let url = file(for: mac), height = Int(640 / mac.aspect)
        Task.detached(priority: .utility) { write(to: url, height: height) }
    }

    /// Before the machine stops, while there is still a screen to read.
    static func saveNow(for mac: VirtualMac) { write(to: file(for: mac), height: Int(640 / mac.aspect)) }

    private static func write(to url: URL, height: Int) {
        guard let image = capture(width: 640, height: height), let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.8) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
