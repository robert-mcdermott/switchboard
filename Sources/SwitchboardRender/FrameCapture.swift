import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

/// Asks the renderer to save the next frame it draws as a PNG.
///
/// This is how a rendered frame gets checked without a person looking at the screen,
/// and the seed of the `--snapshot` golden-image tests planned for M2.
public final class FrameCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: URL?

    public init() {}

    public func request(savingTo url: URL) {
        lock.lock()
        pending = url
        lock.unlock()
    }

    func take() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        let url = pending
        pending = nil
        return url
    }

    /// Writes a BGRA8 texture with shared storage to a PNG file.
    static func writePNG(from texture: MTLTexture, to url: URL) {
        let width = texture.width, height = texture.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        pixels.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            texture.getBytes(
                base, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo), provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
