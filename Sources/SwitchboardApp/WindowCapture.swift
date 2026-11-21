import AppKit
import QuartzCore

/// Saves a picture of the whole window from inside the app, for checking layout without
/// screen-recording permission. AppKit can draw every view except the Metal one, so the
/// graph is pasted in from a frame the renderer saved. Text that floats over the graph
/// (hints, the tooltip) is covered by the paste and does not appear.
@MainActor
enum WindowCapture {
    static func save(window: NSWindow, graphFrame: URL, to url: URL) {
        guard let content = window.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)
        else { return }
        content.cacheDisplay(in: content.bounds, to: bitmap)

        let image = NSImage(size: content.bounds.size)
        image.lockFocus()
        bitmap.draw(in: content.bounds)
        if let metal = findMetalView(in: content), let graph = NSImage(contentsOf: graphFrame) {
            var frame = metal.convert(metal.bounds, to: content)
            // Drawing into an image is bottom-up; SwiftUI's hosting view is top-down.
            if content.isFlipped { frame.origin.y = content.bounds.height - frame.maxY }
            graph.draw(in: frame)
        }
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return }
        try? png.write(to: url)
    }

    /// The view whose layer the graph is drawn into.
    private static func findMetalView(in view: NSView) -> NSView? {
        if view.layer is CAMetalLayer { return view }
        for child in view.subviews {
            if let found = findMetalView(in: child) { return found }
        }
        return nil
    }
}
