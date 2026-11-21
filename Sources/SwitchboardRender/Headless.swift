import CoreGraphics
import Foundation
import ImageIO
import Metal

/// Renders one frame to a PNG with no window, for golden-image tests.
@MainActor
public enum HeadlessRenderer {
    public enum HeadlessError: Error, CustomStringConvertible {
        case noDevice
        case unreadable(String)

        public var description: String {
            switch self {
            case .noDevice: "no Metal device"
            case .unreadable(let path): "could not read image at \(path)"
            }
        }
    }

    /// Draws `controller`'s current graph at `time` and writes it to `url`. With a `zoom`
    /// over 1, the view is that much closer, centred on this Mac, as a person zooming in sees it.
    public static func render(
        _ controller: GraphController, time: Float, width: Int, height: Int, profile: RenderProfile, zoom: Float = 1,
        to url: URL
    ) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw HeadlessError.noDevice
        }
        let renderer = try GraphRenderer(device: device, targetFormat: .bgra8Unorm)
        // Grain is a function of pixel position and time, so a fixed time gives a fixed image.
        renderer.profile = profile

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: descriptor), let commandBuffer = queue.makeCommandBuffer() else {
            throw HeadlessError.noDevice
        }

        controller.settle()
        let frame = controller.frame(labelBudget: profile.labelBudget)
        let viewport = SIMD2(Float(width), Float(height))
        let fit = Camera.fitting(halfSize: frame.halfSize, viewport: viewport)
        let center = zoom == 1 || frame.nodes.isEmpty ? SIMD2<Float>.zero : frame.nodes[0].center
        let camera = Camera(center: center, scale: fit * zoom, markScale: fit * Camera.markZoom(zoom))
        renderer.render(frame, camera: camera, time: time, backing: 2, to: target, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        FrameCapture.writePNG(from: target, to: url)
    }

    public struct Difference: Sendable {
        /// Mean absolute difference per channel, on a 0–255 scale.
        public var mean: Double
        /// Largest single-channel difference.
        public var maximum: Int
        /// Share of pixels that differ by more than 8 in any channel.
        public var changedFraction: Double
    }

    /// Compares two images of the same size.
    public static func difference(_ first: URL, _ second: URL) throws -> Difference {
        let a = try pixels(first), b = try pixels(second)
        guard a.width == b.width, a.height == b.height else {
            return Difference(mean: 255, maximum: 255, changedFraction: 1)
        }
        var total = 0, maximum = 0, changed = 0
        for pixel in stride(from: 0, to: a.bytes.count, by: 4) {
            var worst = 0
            for channel in 0..<3 {
                let delta = abs(Int(a.bytes[pixel + channel]) - Int(b.bytes[pixel + channel]))
                total += delta
                worst = max(worst, delta)
            }
            maximum = max(maximum, worst)
            if worst > 8 { changed += 1 }
        }
        let count = a.width * a.height
        return Difference(mean: Double(total) / Double(count * 3), maximum: maximum, changedFraction: Double(changed) / Double(count))
    }

    private static func pixels(_ url: URL) throws -> (width: Int, height: Int, bytes: [UInt8]) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw HeadlessError.unreadable(url.path) }
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drawn else { throw HeadlessError.unreadable(url.path) }
        return (image.width, image.height, bytes)
    }
}
