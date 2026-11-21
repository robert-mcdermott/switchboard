import MetalKit
import SwiftUI
import simd

/// The live graph: owns the renderer and the camera, draws every frame, and turns pointer
/// movement into hover information.
@MainActor
public final class GraphSession: NSObject, MTKViewDelegate {
    public struct RendererInfo: Sendable {
        public var deviceName: String
        public var shaderCompileMS: Double
        public var resourceOrigin: RenderResources.Origin
    }

    public enum Key: Sendable {
        case togglePause, cycleProfile, resetView, focusFilter, toggleInspector, togglePanel, escape
    }

    public enum ContextAction: Sendable {
        case filterToThis, focusOnThis, copyDetails, revealInFinder
    }

    public let controller: GraphController
    public let stats = FrameStats()
    public var profile: RenderProfile = .cinema {
        didSet { renderer?.profile = profile }
    }

    /// Hover details and where the pointer is, in points from the view's top-left corner.
    public var onHover: ((HoverInfo?, CGPoint) -> Void)?
    public var onKey: ((Key) -> Void)?
    /// A click on the graph: the target, or `nil` for empty space.
    public var onSelect: ((PickTarget?) -> Void)?
    public var onContext: ((ContextAction, PickTarget) -> Void)?
    /// What is pinned in the inspector. Stays lit when the pointer moves away.
    public var selection: PickTarget?
    public var onFailure: ((String) -> Void)?
    /// Set to have the next frame saved as a PNG.
    public var capture: FrameCapture?

    public private(set) var rendererInfo: RendererInfo?
    /// When a frame containing real data was first drawn.
    public private(set) var firstDataFrame: Date?
    public private(set) var nodeCount = 0
    public private(set) var edgeCount = 0

    private var renderer: GraphRenderer?
    private var commandQueue: MTLCommandQueue?
    private weak var view: MTKView?
    private let epoch = CACurrentMediaTime()
    private var lastFrameTime: CFTimeInterval = 0

    private var userZoom: Float = 1
    private var pan: SIMD2<Float> = .zero
    private var extent: Float = 420
    private var hoverTarget: PickTarget?
    private var hoverPoint: CGPoint = .zero
    private var framesSinceHoverRefresh = 0

    public init(controller: GraphController) {
        self.controller = controller
    }

    /// Animation time: seconds since this session was created.
    public var time: Float { Float(CACurrentMediaTime() - epoch) }

    func attach(_ view: MTKView) {
        self.view = view
        guard let device = view.device, let queue = device.makeCommandQueue() else {
            onFailure?("This Mac has no Metal device")
            return
        }
        do {
            let renderer = try GraphRenderer(device: device, targetFormat: view.colorPixelFormat)
            renderer.profile = profile
            self.renderer = renderer
            commandQueue = queue
            rendererInfo = RendererInfo(
                deviceName: device.name, shaderCompileMS: renderer.shaderCompileMS, resourceOrigin: renderer.resourceOrigin)
        } catch {
            onFailure?("\(error)")
        }
    }

    // MARK: - Drawing

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        let frameStart = CACurrentMediaTime()
        guard let renderer, let commandQueue, let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }

        controller.step()
        let frame = controller.frame(labelBudget: profile.labelBudget, highlight: hoverTarget ?? selection)
        nodeCount = frame.nodes.count
        edgeCount = frame.edges.count
        if firstDataFrame == nil, !frame.edges.isEmpty { firstDataFrame = Date() }

        // Ease toward the layout's size so the view does not jump as the graph grows.
        extent += (frame.extent - extent) * 0.08
        let camera = camera(for: view)
        let backing = Float(view.window?.backingScaleFactor ?? 2)
        renderer.render(frame, camera: camera, time: time, backing: backing, to: drawable.texture, commandBuffer: commandBuffer)

        var captured: (texture: MTLTexture, url: URL)?
        if let url = capture?.take(), !view.framebufferOnly, let device = view.device {
            let source = drawable.texture
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: source.pixelFormat, width: source.width, height: source.height, mipmapped: false)
            descriptor.storageMode = .shared
            if let copy = device.makeTexture(descriptor: descriptor), let blit = commandBuffer.makeBlitCommandEncoder() {
                blit.copy(from: source, to: copy)
                blit.endEncoding()
                captured = (copy, url)
            }
        }

        let stats = self.stats
        nonisolated(unsafe) let finished = captured
        commandBuffer.addCompletedHandler { buffer in
            let gpu = buffer.gpuEndTime - buffer.gpuStartTime
            if gpu > 0 { stats.recordGPU(gpu) }
            if let finished { FrameCapture.writePNG(from: finished.texture, to: finished.url) }
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()

        if lastFrameTime > 0 {
            stats.recordFrame(interval: frameStart - lastFrameTime, encode: CACurrentMediaTime() - frameStart)
        }
        lastFrameTime = frameStart

        // Keep the tooltip's numbers current while the pointer rests on something.
        framesSinceHoverRefresh += 1
        if hoverTarget != nil, framesSinceHoverRefresh >= 20 { refreshHover() }
    }

    private func camera(for view: MTKView) -> Camera {
        let size = view.drawableSize
        let viewport = SIMD2(Float(size.width), Float(size.height))
        return Camera(center: pan, scale: Camera.fitting(extent: extent, viewport: viewport) * userZoom)
    }

    // MARK: - Input

    /// Converts a point in the view (points, origin bottom-left) to world coordinates.
    private func world(at point: CGPoint, in view: MTKView) -> SIMD2<Float> {
        let backing = Float(view.window?.backingScaleFactor ?? 2)
        let camera = camera(for: view)
        let size = view.drawableSize
        let pixel = SIMD2(Float(point.x) * backing - Float(size.width) / 2, Float(point.y) * backing - Float(size.height) / 2)
        return camera.center + pixel / camera.scale
    }

    func zoom(by factor: Float, at point: CGPoint) {
        guard let view else { return }
        let before = world(at: point, in: view)
        userZoom = min(max(userZoom * factor, 0.25), 40)
        // Keep whatever was under the pointer under the pointer.
        pan += before - world(at: point, in: view)
    }

    func pan(byPoints delta: CGSize) {
        guard let view else { return }
        let backing = Float(view.window?.backingScaleFactor ?? 2)
        let scale = camera(for: view).scale
        pan -= SIMD2(Float(delta.width), Float(delta.height)) * backing / scale
    }

    public func resetView() {
        userZoom = 1
        pan = .zero
    }

    func hover(at point: CGPoint?) {
        guard let view, let point else {
            if hoverTarget != nil {
                hoverTarget = nil
                onHover?(nil, .zero)
            }
            return
        }
        let backing = Float(view.window?.backingScaleFactor ?? 2)
        let slack = 5 * backing / camera(for: view).scale
        hoverPoint = CGPoint(x: point.x, y: view.bounds.height - point.y)
        let target = controller.pick(at: world(at: point, in: view), slack: slack)
        if target != hoverTarget {
            hoverTarget = target
            refreshHover()
        } else if target != nil {
            onHoverMoved()
        }
    }

    private var lastInfo: HoverInfo?

    private func refreshHover() {
        framesSinceHoverRefresh = 0
        lastInfo = hoverTarget.flatMap { controller.info(for: $0) }
        onHover?(lastInfo, hoverPoint)
    }

    private func onHoverMoved() {
        onHover?(lastInfo, hoverPoint)
    }

    func key(_ key: Key) {
        if key == .resetView { resetView() }
        if key == .escape { controller.focus = nil }
        onKey?(key)
    }

    func target(at point: CGPoint) -> PickTarget? {
        guard let view else { return nil }
        let backing = Float(view.window?.backingScaleFactor ?? 2)
        return controller.pick(at: world(at: point, in: view), slack: 5 * backing / camera(for: view).scale)
    }

    func click(at point: CGPoint, count: Int) {
        let target = target(at: point)
        if count >= 2 {
            // Double-click isolates a neighbourhood; double-clicking it again, or empty space, releases it.
            controller.focus = (target == controller.focus) ? nil : target
        }
        selection = target
        onSelect?(target)
    }

    func context(_ action: ContextAction, _ target: PickTarget) {
        if action == .focusOnThis { controller.focus = target }
        onContext?(action, target)
    }
}

/// The Metal view, with the pointer and keyboard handling the graph needs.
final class GraphMTKView: MTKView {
    weak var session: GraphSession?
    private var tracking: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    private func location(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    override func mouseMoved(with event: NSEvent) { session?.hover(at: location(event)) }
    override func mouseExited(with event: NSEvent) { session?.hover(at: nil) }

    private var pressedAt: CGPoint?
    private var dragged = false
    private var contextTarget: PickTarget?

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        pressedAt = location(event)
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        // A press that wanders a few points is still a click.
        if let pressedAt, hypot(location(event).x - pressedAt.x, location(event).y - pressedAt.y) > 3 { dragged = true }
        guard dragged else { return }
        session?.pan(byPoints: CGSize(width: event.deltaX, height: -event.deltaY))
        session?.hover(at: nil)
    }

    override func mouseUp(with event: NSEvent) {
        if !dragged { session?.click(at: location(event), count: event.clickCount) }
        pressedAt = nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let session, let target = session.target(at: location(event)) else { return nil }
        contextTarget = target
        let menu = NSMenu()
        var entries: [(String, Int)] = [("Filter to This", 0), ("Focus on This", 1), ("Copy Details", 2)]
        if case .node(.process) = target { entries.append(("Reveal in Finder", 3)) }
        for (title, tag) in entries {
            let item = NSMenuItem(title: title, action: #selector(contextChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = tag
            menu.addItem(item)
        }
        return menu
    }

    @objc private func contextChosen(_ sender: NSMenuItem) {
        guard let contextTarget else { return }
        let actions: [GraphSession.ContextAction] = [.filterToThis, .focusOnThis, .copyDetails, .revealInFinder]
        session?.context(actions[sender.tag], contextTarget)
    }

    override func scrollWheel(with event: NSEvent) {
        if event.hasPreciseScrollingDeltas, !event.modifierFlags.contains(.command) {
            // Two fingers on a trackpad pan; a wheel, or ⌘-scroll, zooms.
            session?.pan(byPoints: CGSize(width: event.scrollingDeltaX, height: -event.scrollingDeltaY))
        } else {
            let amount = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.08
            session?.zoom(by: Float(exp(amount)), at: location(event))
        }
    }

    override func magnify(with event: NSEvent) {
        session?.zoom(by: Float(1 + event.magnification), at: location(event))
    }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case " ": session?.key(.togglePause)
        case "p", "P": session?.key(.cycleProfile)
        case "0": session?.key(.resetView)
        case "/": session?.key(.focusFilter)
        case "i", "I": session?.key(.toggleInspector)
        case "b", "B": session?.key(.togglePanel)
        case "\u{1B}": session?.key(.escape)
        default: super.keyDown(with: event)
        }
    }
}

public struct GraphView: NSViewRepresentable {
    private let session: GraphSession

    public init(session: GraphSession) {
        self.session = session
    }

    public func makeNSView(context: Context) -> MTKView {
        let view = GraphMTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 5 / 255, green: 8 / 255, blue: 15 / 255, alpha: 1)
        view.preferredFramesPerSecond = 120
        // Frames can only be read back from a drawable that is more than a framebuffer.
        view.framebufferOnly = session.capture == nil
        view.session = session
        session.attach(view)
        view.delegate = session
        return view
    }

    public func updateNSView(_ view: MTKView, context: Context) {}
}
