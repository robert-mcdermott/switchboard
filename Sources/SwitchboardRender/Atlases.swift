import AppKit
import CoreText
import Metal

/// Text for graph labels, rasterised once with CoreText and kept in a single texture.
///
/// Drawing labels in Metal rather than as views is what lets thousands of nodes keep
/// their frame rate (docs/SPEC.md §2).
@MainActor
final class LabelAtlas {
    struct Entry {
        /// Left, top, right, bottom in texture coordinates.
        var uv: SIMD4<Float>
        /// Size in atlas pixels. The atlas is drawn at two pixels per point.
        var size: SIMD2<Float>
    }

    let texture: MTLTexture
    /// Pixels per point the glyphs were rasterised at.
    static let rasterScale: CGFloat = 2

    private let width = 2048
    private let height = 2048
    private var entries: [String: Entry] = [:]
    private var cursorX = 0
    private var cursorY = 0
    private var rowHeight = 0
    private let fonts: [CTFont]

    init?(device: MTLDevice) {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        self.texture = texture
        // Host, process, endpoint: three sizes of the same face.
        fonts = [(12.0, NSFont.Weight.semibold), (11.0, .medium), (10.0, .regular)].map { size, weight in
            NSFont.monospacedSystemFont(ofSize: size * Self.rasterScale, weight: weight) as CTFont
        }
        clear()
    }

    private func clear() {
        entries.removeAll(keepingCapacity: true)
        cursorX = 0
        cursorY = 0
        rowHeight = 0
        let zeros = [UInt8](repeating: 0, count: width * height)
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: zeros, bytesPerRow: width)
    }

    /// The atlas entry for `text` in the style for a node kind (0 host, 1 process, 2 endpoint).
    func entry(for text: String, kind: Int) -> Entry? {
        let key = "\(kind)|\(text)"
        if let known = entries[key] { return known }

        let attributed = NSAttributedString(
            string: text,
            attributes: [.font: fonts[min(max(kind, 0), fonts.count - 1)], .foregroundColor: NSColor.white])
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let advance = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        let w = min(Int(advance.rounded(.up)) + 4, width)
        let h = Int((ascent + descent).rounded(.up)) + 4
        guard w > 4, h > 4 else { return nil }

        if cursorX + w > width {
            cursorX = 0
            cursorY += rowHeight
            rowHeight = 0
        }
        if cursorY + h > height {
            // Full: start again. Labels in use are simply rasterised a second time.
            clear()
        }

        var pixels = [UInt8](repeating: 0, count: w * h)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.setShouldAntialias(true)
            context.setShouldSmoothFonts(false)
            context.textPosition = CGPoint(x: 2, y: descent + 2)
            CTLineDraw(line, context)
            return true
        }
        guard drawn else { return nil }
        texture.replace(
            region: MTLRegionMake2D(cursorX, cursorY, w, h), mipmapLevel: 0, withBytes: pixels, bytesPerRow: w)

        let entry = Entry(
            uv: SIMD4(
                Float(cursorX) / Float(width), Float(cursorY) / Float(height),
                Float(cursorX + w) / Float(width), Float(cursorY + h) / Float(height)),
            size: SIMD2(Float(w), Float(h)))
        entries[key] = entry
        cursorX += w
        rowHeight = max(rowHeight, h)
        return entry
    }
}

/// App icons for process nodes, in fixed slots of one texture.
@MainActor
final class IconAtlas {
    let texture: MTLTexture
    static let slot = 64
    static let perRow = 32

    private var slots: [String: Float] = [:]
    private var next = 0

    init?(device: MTLDevice) {
        let side = Self.slot * Self.perRow
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: side, height: side, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        self.texture = texture
    }

    /// The enclosing application of an executable, if it lives in one. Helpers nested
    /// inside an app resolve to the outermost bundle, which carries the icon people know.
    static func applicationBundle(for executable: String) -> String? {
        guard let range = executable.range(of: ".app/") else { return nil }
        return String(executable[..<range.lowerBound]) + ".app"
    }

    /// The slot holding the icon for the app that owns `executable`, or a negative number
    /// if it is not part of an app or the atlas is full.
    func slot(forExecutable executable: String) -> Float {
        guard let bundle = Self.applicationBundle(for: executable) else { return -1 }
        if let known = slots[bundle] { return known }
        guard next < Self.perRow * Self.perRow else { return -1 }

        let side = Self.slot
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
            else { return false }
            let previous = NSGraphicsContext.current
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            NSWorkspace.shared.icon(forFile: bundle).draw(in: CGRect(x: 0, y: 0, width: side, height: side))
            NSGraphicsContext.current = previous
            return true
        }
        guard drawn else {
            slots[bundle] = -1
            return -1
        }
        let column = next % Self.perRow, row = next / Self.perRow
        texture.replace(
            region: MTLRegionMake2D(column * side, row * side, side, side), mipmapLevel: 0,
            withBytes: pixels, bytesPerRow: side * 4)
        let index = Float(next)
        slots[bundle] = index
        next += 1
        return index
    }
}
