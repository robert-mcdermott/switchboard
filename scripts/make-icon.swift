// Draws Switchboard's app icon and writes it as an .icns file.
//
//   swift scripts/make-icon.swift Assets/AppIcon.icns [preview.png]
//
// The icon is drawn here in code, at every size the .icns holds, so there is no source
// artwork to keep and nothing is downloaded. scripts/bundle.sh copies the result into the app.
//
// What it shows: this Mac as a bright core, with curved links out to the far ends of its
// connections, in the colours the graph uses for TLS, QUIC, DNS, and remote access, on the
// graph's dark field of graph paper.

import AppKit

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write("usage: swift make-icon.swift OUTPUT.icns [PREVIEW.png]\n".data(using: .utf8)!)
    exit(2)
}
let output = URL(fileURLWithPath: arguments[1])
let preview = arguments.count >= 3 ? URL(fileURLWithPath: arguments[2]) : nil

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha)
}

let teal = 0x2EE6D6 as UInt32, violet = 0xA07CFF as UInt32, green = 0x55E38F as UInt32, amber = 0xFFB547 as UInt32
let cyan = 0x56CCFF as UInt32

/// The far ends: angle in degrees (0 is to the right, counter-clockwise), distance from the
/// core on the 1024 canvas, dot radius, colour, and how strongly the link is lit.
let ends: [(angle: CGFloat, distance: CGFloat, radius: CGFloat, color: UInt32, weight: CGFloat)] = [
    (28, 300, 20, teal, 1.0),
    (82, 262, 15, violet, 0.7),
    (138, 318, 22, teal, 0.9),
    (192, 250, 14, green, 0.55),
    (236, 322, 18, cyan, 0.8),
    (292, 276, 16, amber, 0.65),
    (338, 228, 12, violet, 0.5),
]

/// Draws the icon onto a 1024-unit canvas; the caller scales the context to the size wanted.
func draw(_ context: CGContext, size: CGFloat) {
    let s = size / 1024
    context.scaleBy(x: s, y: s)
    context.setShouldAntialias(true)
    let center = CGPoint(x: 512, y: 512)

    // The body: Apple's macOS icon grid puts an 824-point rounded square in a 1024 canvas,
    // with room around it for the shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.45))
    context.addPath(shape)
    context.setFillColor(color(0x070A14))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(shape)
    context.clip()

    // A deep navy field, lighter at the top.
    let field = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0x18234A), color(0x0A0F22), color(0x04060D)] as CFArray,
        locations: [0, 0.55, 1])!
    context.drawLinearGradient(field, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // A glow behind the core.
    let glow = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(cyan, 0.30), color(cyan, 0.08), color(cyan, 0)] as CFArray,
        locations: [0, 0.4, 1])!
    context.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: 420, options: [])

    // Graph paper, as behind the graph.
    context.setLineWidth(2)
    context.setStrokeColor(color(0x8FB3FF, 0.07))
    for line in stride(from: CGFloat(100 + 51.5), to: 924, by: 103) {
        context.move(to: CGPoint(x: line, y: 100))
        context.addLine(to: CGPoint(x: line, y: 924))
        context.move(to: CGPoint(x: 100, y: line))
        context.addLine(to: CGPoint(x: 924, y: line))
    }
    context.strokePath()

    // Distant nodes, faint, so the picture reads as a network rather than a star.
    let distant: [(CGFloat, CGFloat, CGFloat)] = [
        (210, 790, 6), (330, 840, 4), (760, 820, 5), (850, 700, 4), (180, 420, 4), (240, 230, 5),
        (690, 190, 6), (820, 300, 4), (560, 860, 4), (870, 520, 5), (150, 640, 5), (420, 160, 4),
    ]
    for (x, y, r) in distant {
        context.saveGState()
        context.setShadow(offset: .zero, blur: 10, color: color(cyan, 0.6))
        context.setFillColor(color(0xBFE9FF, 0.35))
        context.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
        context.restoreGState()
    }

    // Second hops: a few far ends lead on to something further out.
    for (from, to) in [(0, (840.0, 760.0)), (2, (196.0, 820.0)), (4, (232.0, 168.0)), (5, (760.0, 140.0))] as [(Int, (CGFloat, CGFloat))] {
        let end = ends[from]
        let angle = end.angle * .pi / 180
        let start = CGPoint(x: center.x + cos(angle) * end.distance, y: center.y + sin(angle) * end.distance)
        let target = CGPoint(x: to.0, y: to.1)
        context.saveGState()
        context.setShadow(offset: .zero, blur: 12, color: color(end.color, 0.6))
        context.setLineCap(.round)
        context.setLineWidth(3)
        context.setStrokeColor(color(end.color, 0.38))
        context.move(to: start)
        context.addLine(to: target)
        context.strokePath()
        context.setFillColor(color(end.color, 0.7))
        context.fillEllipse(in: CGRect(x: target.x - 9, y: target.y - 9, width: 18, height: 18))
        context.restoreGState()
    }

    // A faint orbit.
    context.setLineWidth(3)
    context.setStrokeColor(color(cyan, 0.16))
    context.addEllipse(in: CGRect(x: center.x - 190, y: center.y - 190, width: 380, height: 380))
    context.strokePath()

    // Links: each bows the same way round, as the graph's edges do, with a pulse along it.
    for end in ends {
        let angle = end.angle * .pi / 180
        let point = CGPoint(x: center.x + cos(angle) * end.distance, y: center.y + sin(angle) * end.distance)
        let middle = CGPoint(x: (center.x + point.x) / 2, y: (center.y + point.y) / 2)
        let bow = end.distance * 0.2
        let control = CGPoint(x: middle.x - sin(angle) * bow, y: middle.y + cos(angle) * bow)

        let path = CGMutablePath()
        path.move(to: center)
        path.addQuadCurve(to: point, control: control)

        // A wide soft glow, then the line itself.
        context.saveGState()
        context.setShadow(offset: .zero, blur: 26, color: color(end.color, 0.9 * end.weight))
        context.addPath(path)
        context.setLineCap(.round)
        context.setLineWidth(5 + 7 * end.weight)
        context.setStrokeColor(color(end.color, 0.35 + 0.5 * end.weight))
        context.strokePath()
        context.restoreGState()
        context.addPath(path)
        context.setLineCap(.round)
        context.setLineWidth(2 + 2.5 * end.weight)
        context.setStrokeColor(color(0xFFFFFF, 0.25 + 0.35 * end.weight))
        context.strokePath()

        // The pulse: a bright bead partway out.
        let t: CGFloat = 0.62
        let bead = CGPoint(
            x: (1 - t) * (1 - t) * center.x + 2 * (1 - t) * t * control.x + t * t * point.x,
            y: (1 - t) * (1 - t) * center.y + 2 * (1 - t) * t * control.y + t * t * point.y)
        context.saveGState()
        context.setShadow(offset: .zero, blur: 18, color: color(end.color, 1))
        context.setFillColor(color(0xFFFFFF, 0.95))
        let beadRadius = 5 + 4 * end.weight
        context.fillEllipse(in: CGRect(x: bead.x - beadRadius, y: bead.y - beadRadius, width: beadRadius * 2, height: beadRadius * 2))
        context.restoreGState()

        // The far end.
        context.saveGState()
        context.setShadow(offset: .zero, blur: 30, color: color(end.color, 1))
        context.setFillColor(color(end.color))
        let r = end.radius
        context.fillEllipse(in: CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2))
        context.restoreGState()
        context.setFillColor(color(0xFFFFFF, 0.85))
        let inner = r * 0.45
        context.fillEllipse(in: CGRect(x: point.x - inner, y: point.y - inner, width: inner * 2, height: inner * 2))
    }

    // The core: this Mac.
    context.saveGState()
    context.setShadow(offset: .zero, blur: 60, color: color(cyan, 1))
    context.setFillColor(color(cyan))
    context.fillEllipse(in: CGRect(x: center.x - 54, y: center.y - 54, width: 108, height: 108))
    context.restoreGState()
    let core = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0xFFFFFF), color(0xBFF2FF), color(cyan)] as CFArray,
        locations: [0, 0.45, 1])!
    context.saveGState()
    context.addEllipse(in: CGRect(x: center.x - 54, y: center.y - 54, width: 108, height: 108))
    context.clip()
    context.drawRadialGradient(
        core, startCenter: CGPoint(x: center.x - 14, y: center.y + 16), startRadius: 0, endCenter: center, endRadius: 56, options: [])
    context.restoreGState()
    context.setLineWidth(5)
    context.setStrokeColor(color(0xFFFFFF, 0.55))
    context.addEllipse(in: CGRect(x: center.x - 80, y: center.y - 80, width: 160, height: 160))
    context.strokePath()

    // A sheen across the top, and a fine edge, as glass catches light.
    let sheen = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0xFFFFFF, 0.10), color(0xFFFFFF, 0)] as CFArray,
        locations: [0, 1])!
    context.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 640), options: [])
    context.restoreGState()

    context.addPath(shape)
    context.setLineWidth(3)
    context.setStrokeColor(color(0xFFFFFF, 0.12))
    context.strokePath()
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    draw(graphics.cgContext, size: CGFloat(size))
    graphics.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }
for base in [16, 32, 128, 256, 512] {
    try png(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
if let preview { try png(size: 1024).write(to: preview) }

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }
print("wrote \(output.path)")
