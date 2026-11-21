import MetalKit
import SwiftUI
import simd

/// Draws the graph on a thread of its own, paced by the display.
///
/// SwiftUI lays the window out on the main thread, and a layout pass can take longer
/// than a frame. With drawing on the main thread every such pass was a dropped frame;
/// here the graph keeps its pace whatever the rest of the window is doing. The main
/// thread only changes the camera and the highlights, through `state`.
final class RenderLoop: NSObject, @unchecked Sendable {
    struct State {
        var drawableSize = CGSize.zero
        var backing: Float = 2
        var userZoom: Float = 1
        var pan = SIMD2<Float>.zero
        /// Eased toward the layout's size by the render thread, so the view does not jump.
        var halfSize = SIMD2<Float>(420, 420)
        var highlights = Set<PickTarget>()
        var profile = RenderProfile.cinema
        var nodeCount = 0
        var edgeCount = 0
        var firstDataFrame: Date?

        var camera: Camera {
            let viewport = SIMD2(Float(drawableSize.width), Float(drawableSize.height))
            return Camera(center: pan, scale: Camera.fitting(halfSize: halfSize, viewport: viewport) * userZoom)
        }
    }

    let lock = NSLock()
    private var state = State()
    private let controller: GraphController
    private let renderer: GraphRenderer
    private let queue: MTLCommandQueue
    private let layer: CAMetalLayer
    private let stats: FrameStats
    private let capture: FrameCapture?
    private let epoch: CFTimeInterval
    private var lastFrameTime: CFTimeInterval = 0
    private var thread: Thread?
    nonisolated(unsafe) private var link: CADisplayLink?
    nonisolated(unsafe) private var runLoop: CFRunLoop?

    init(
        controller: GraphController, renderer: GraphRenderer, queue: MTLCommandQueue, layer: CAMetalLayer, stats: FrameStats,
        capture: FrameCapture?, epoch: CFTimeInterval
    ) {
        self.controller = controller
        self.renderer = renderer
        self.queue = queue
        self.layer = layer
        self.stats = stats
        self.capture = capture
        self.epoch = epoch
    }

    func read<T>(_ body: (State) -> T) -> T { lock.withLock { body(state) } }
    func change(_ body: (inout State) -> Void) { lock.withLock { body(&state) } }

    @MainActor
    func start(in view: NSView) {
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = read { $0.profile }.frameRates
        self.link = link
        nonisolated(unsafe) let unsafeLink = link
        let thread = Thread { [weak self] in
            unsafeLink.add(to: .current, forMode: .default)
            self?.runLoop = CFRunLoopGetCurrent()
            // The display link is the run loop's only source; it runs until the link is removed.
            while !Thread.current.isCancelled {
                RunLoop.current.run(mode: .default, before: .distantFuture)
            }
        }
        thread.name = "switchboard.render"
        thread.qualityOfService = .userInteractive
        thread.start()
        self.thread = thread
    }

    func stop() {
        thread?.cancel()
        link?.invalidate()
        if let runLoop { CFRunLoopStop(runLoop) }
    }

    @objc private func tick(_ displayLink: CADisplayLink) {
        autoreleasepool { draw() }
    }

    private func draw() {
        let frameStart = CACurrentMediaTime()
        let view = read { $0 }
        guard view.drawableSize.width > 0, view.drawableSize.height > 0 else { return }
        if layer.drawableSize != view.drawableSize { layer.drawableSize = view.drawableSize }
        if renderer.profile != view.profile {
            renderer.profile = view.profile
            link?.preferredFrameRateRange = view.profile.frameRates
        }

        let time = Float(frameStart - epoch)
        controller.advance(time: time, motion: view.profile != .still)
        controller.step()
        let frame = controller.frame(labelBudget: view.profile.labelBudget, highlights: view.highlights)
        var camera = view.camera
        change { state in
            state.halfSize += (frame.halfSize - state.halfSize) * 0.08
            state.nodeCount = frame.nodes.count
            state.edgeCount = frame.edges.count
            if state.firstDataFrame == nil, !frame.edges.isEmpty { state.firstDataFrame = Date() }
            camera = state.camera
        }

        guard let drawable = layer.nextDrawable(), let commandBuffer = queue.makeCommandBuffer() else { return }
        renderer.render(frame, camera: camera, time: time, backing: view.backing, to: drawable.texture, commandBuffer: commandBuffer)

        var captured: (texture: MTLTexture, url: URL)?
        if let url = capture?.take(), !layer.framebufferOnly {
            let source = drawable.texture
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: source.pixelFormat, width: source.width, height: source.height, mipmapped: false)
            descriptor.storageMode = .shared
            if let copy = queue.device.makeTexture(descriptor: descriptor), let blit = commandBuffer.makeBlitCommandEncoder() {
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
    }
}

/// The live graph: owns the render loop and the camera, and turns pointer movement into
/// hover information. Lives on the main thread; the drawing does not.
@MainActor
public final class GraphSession: NSObject {
    public struct RendererInfo: Sendable {
        public var deviceName: String
        public var shaderCompileMS: Double
        public var resourceOrigin: RenderResources.Origin
    }

    public enum Key: Sendable, Equatable {
        case togglePause, cycleProfile, resetView, focusFilter, toggleInspector, togglePanel, escape, toggleKeepEnded
        /// 1 for the first layout, 2 for the second, and so on.
        case layout(Int)
        case toggleKiosk
        /// Show or hide connections that never leave this Mac.
        case toggleThisMac
        /// The next colour theme.
        case cycleTheme
    }

    public enum ContextAction: Sendable {
        case filterToThis, focusOnThis, copyDetails, revealInFinder, toggleCluster
    }

    public let controller: GraphController
    public let stats = FrameStats()
    public var profile: RenderProfile = .cinema {
        didSet { loop?.change { $0.profile = profile } }
    }

    /// Hover details and where the pointer is, in points from the view's top-left corner.
    public var onHover: ((HoverInfo?, CGPoint) -> Void)?
    public var onKey: ((Key) -> Void)?
    /// A click on the graph: the target, or `nil` for empty space.
    public var onSelect: ((PickTarget?, _ extend: Bool) -> Void)?
    public var onContext: ((ContextAction, PickTarget) -> Void)?
    /// What is pinned in the inspector. Stays lit when the pointer moves away.
    public var selection = Set<PickTarget>() {
        didSet { publishHighlights() }
    }
    public var onFailure: ((String) -> Void)?
    /// Set to have the next frame saved as a PNG.
    public var capture: FrameCapture?

    public private(set) var rendererInfo: RendererInfo?
    /// When a frame containing real data was first drawn.
    public var firstDataFrame: Date? { loop?.read { $0.firstDataFrame } }
    public var nodeCount: Int { loop?.read { $0.nodeCount } ?? 0 }
    public var edgeCount: Int { loop?.read { $0.edgeCount } ?? 0 }

    private var loop: RenderLoop?
    private weak var view: GraphLayerView?
    private let epoch = CACurrentMediaTime()
    private var hoverTarget: PickTarget? {
        didSet { publishHighlights() }
    }
    private var hoverPoint: CGPoint = .zero
    private var hoverTimer: Timer?

    public init(controller: GraphController) {
        self.controller = controller
    }

    /// Animation time: seconds since this session was created.
    public var time: Float { Float(CACurrentMediaTime() - epoch) }

    func attach(_ view: GraphLayerView) {
        // SwiftUI makes a new view when the window's arrangement changes, as it does on
        // entering kiosk mode; the old view's loop goes with it.
        loop?.stop()
        loop = nil
        hoverTimer?.invalidate()
        self.view = view
        guard let device = view.metalLayer.device, let queue = device.makeCommandQueue() else {
            onFailure?("This Mac has no Metal device")
            return
        }
        do {
            let renderer = try GraphRenderer(device: device, targetFormat: view.metalLayer.pixelFormat)
            renderer.profile = profile
            rendererInfo = RendererInfo(
                deviceName: device.name, shaderCompileMS: renderer.shaderCompileMS, resourceOrigin: renderer.resourceOrigin)
            let loop = RenderLoop(
                controller: controller, renderer: renderer, queue: queue, layer: view.metalLayer, stats: stats, capture: capture,
                epoch: epoch)
            loop.change { $0.profile = profile }
            self.loop = loop
            view.sizeChanged()
            loop.start(in: view)
        } catch {
            onFailure?("\(error)")
        }
        // Keep the tooltip's numbers current while the pointer rests on something.
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.hoverTarget != nil else { return }
                self.refreshHover()
            }
        }
    }

    /// Stops drawing, if `view` is still the one being drawn into.
    func detach(_ view: GraphLayerView) {
        guard self.view === view else { return }
        loop?.stop()
        loop = nil
        hoverTimer?.invalidate()
        hoverTimer = nil
    }

    /// What VoiceOver says the graph shows. Set about once a second.
    public func setAccessibilitySummary(_ text: String) {
        accessibilitySummary = text
        view?.setAccessibilityValue(text)
    }

    /// What VoiceOver was last told, for checking without VoiceOver running.
    public private(set) var accessibilitySummary = ""
    public var accessibilityValueOnView: String? { view?.accessibilityValue() as? String }
    public var accessibilityLabelOnView: String? { view?.accessibilityLabel() }

    /// The view's size in pixels, from the main thread, for the render thread.
    func setDrawableSize(_ size: CGSize, backing: Float) {
        loop?.change {
            $0.drawableSize = size
            $0.backing = backing
        }
    }

    private func publishHighlights() {
        var highlights = selection
        if let hoverTarget { highlights.insert(hoverTarget) }
        loop?.change { $0.highlights = highlights }
    }

    private var camera: Camera { loop?.read { $0.camera } ?? Camera() }
    private var backing: Float { loop?.read { $0.backing } ?? 2 }

    // MARK: - Input

    /// Converts a point in the view (points, origin bottom-left) to world coordinates.
    private static func world(at point: CGPoint, in state: RenderLoop.State) -> SIMD2<Float> {
        let camera = state.camera
        let size = state.drawableSize
        let pixel = SIMD2(
            Float(point.x) * state.backing - Float(size.width) / 2, Float(point.y) * state.backing - Float(size.height) / 2)
        return camera.center + pixel / camera.scale
    }

    private func world(at point: CGPoint) -> SIMD2<Float> {
        loop?.read { Self.world(at: point, in: $0) } ?? .zero
    }

    func zoom(by factor: Float, at point: CGPoint) {
        loop?.change { state in
            let before = Self.world(at: point, in: state)
            state.userZoom = min(max(state.userZoom * factor, 0.25), 40)
            // Keep whatever was under the pointer under the pointer.
            state.pan += before - Self.world(at: point, in: state)
        }
    }

    func pan(byPoints delta: CGSize) {
        loop?.change { state in
            state.pan -= SIMD2(Float(delta.width), Float(delta.height)) * state.backing / state.camera.scale
        }
    }

    public func resetView() {
        loop?.change {
            $0.userZoom = 1
            $0.pan = .zero
        }
        controller.resetGlobe()
        controller.resetSpace()
    }

    /// In the globe, dragging turns the world rather than moving the view; in cyberspace it
    /// orbits the camera.
    var dragTurnsGlobe: Bool { [.globe, .cyberspace].contains(controller.layout) }

    /// Cyberspace is moved through rather than zoomed as a picture.
    var isInSpace: Bool { controller.layout == .cyberspace }

    /// World units per point of pointer travel.
    private var worldPerPoint: Float { loop?.read { $0.backing / $0.camera.scale } ?? 1 }

    func turnGlobe(byPoints delta: CGSize) {
        let distance = SIMD2(Float(delta.width), Float(delta.height)) * worldPerPoint
        if isInSpace { controller.orbitSpace(by: distance) } else { controller.turnGlobe(by: distance) }
    }

    func releaseGlobe(pointsPerSecond velocity: CGSize) {
        let speed = SIMD2(Float(velocity.width), Float(velocity.height)) * worldPerPoint
        if isInSpace { controller.releaseSpace(velocity: speed) } else { controller.releaseGlobe(velocity: speed) }
    }

    /// Nearer for a factor over 1: the camera in cyberspace, the picture elsewhere.
    func zoomOrDolly(by factor: Float, at point: CGPoint) {
        if isInSpace { controller.dollySpace(by: factor) } else { zoom(by: factor, at: point) }
    }

    /// Flying keys held in cyberspace, as a direction: x to the right, z ahead.
    func fly(_ direction: SIMD3<Float>) { controller.flySpace(direction) }

    func hover(at point: CGPoint?) {
        guard let view, let point else {
            if hoverTarget != nil {
                hoverTarget = nil
                onHover?(nil, .zero)
            }
            return
        }
        let slack = 5 * backing / camera.scale
        hoverPoint = CGPoint(x: point.x, y: view.bounds.height - point.y)
        let target = controller.pick(at: world(at: point), slack: slack)
        if target != hoverTarget {
            hoverTarget = target
            refreshHover()
        } else if target != nil {
            onHoverMoved()
        }
    }

    private var lastInfo: HoverInfo?

    private func refreshHover() {
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
        controller.pick(at: world(at: point), slack: 5 * backing / camera.scale)
    }

    func click(at point: CGPoint, count: Int, extend: Bool) {
        let target = target(at: point)
        if count >= 2 {
            // Double-click isolates a neighbourhood; double-clicking it again, or empty space, releases it.
            controller.focus = (target == controller.focus) ? nil : target
            // In cyberspace, double-clicking something also flies to it.
            if isInSpace, case .node(let id) = target { controller.flyTo(id) }
        }
        onSelect?(target, extend)
    }

    func context(_ action: ContextAction, _ target: PickTarget) {
        if action == .focusOnThis { controller.focus = target }
        if action == .toggleCluster, case .node(let id) = target { controller.toggleExpansion(of: id) }
        onContext?(action, target)
    }
}

/// A view backed by a Metal layer, with the pointer and keyboard handling the graph needs.
/// It draws nothing itself: the render loop draws into its layer from another thread.
final class GraphLayerView: NSView {
    weak var session: GraphSession?
    private var tracking: NSTrackingArea?
    let metalLayer = CAMetalLayer()

    init(device: MTLDevice?, capture: Bool) {
        super.init(frame: .zero)
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        // Frames can only be read back from a drawable that is more than a framebuffer.
        metalLayer.framebufferOnly = !capture
        metalLayer.maximumDrawableCount = 3
        metalLayer.isOpaque = true
        metalLayer.backgroundColor = CGColor(red: 5 / 255, green: 8 / 255, blue: 15 / 255, alpha: 1)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        // VoiceOver hears a summary; the tables under the graph hold the same facts row by row.
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Network graph")
        setAccessibilityHelp("A picture of this Mac's connections. The Connections table below lists them one by one.")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func makeBackingLayer() -> CALayer { metalLayer }
    override var wantsUpdateLayer: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        sizeChanged()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        sizeChanged()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        sizeChanged()
        if window == nil { session?.detach(self) }
    }

    func sizeChanged() {
        let backing = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        metalLayer.contentsScale = backing
        let size = CGSize(width: bounds.width * backing, height: bounds.height * backing)
        session?.setDrawableSize(size, backing: Float(backing))
    }

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

    /// The pointer's recent speed while turning the globe, in points a second, and when it last moved.
    private var dragVelocity = CGSize.zero
    private var lastDragTime: TimeInterval = 0

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        pressedAt = location(event)
        dragged = false
        dragVelocity = .zero
        lastDragTime = event.timestamp
    }

    override func mouseDragged(with event: NSEvent) {
        // A press that wanders a few points is still a click.
        if let pressedAt, hypot(location(event).x - pressedAt.x, location(event).y - pressedAt.y) > 3 { dragged = true }
        guard dragged else { return }
        let delta = CGSize(width: event.deltaX, height: -event.deltaY)
        // On the globe a drag turns the world; with ⌥ it moves the view, as elsewhere.
        if session?.dragTurnsGlobe == true, !event.modifierFlags.contains(.option) {
            session?.turnGlobe(byPoints: delta)
            let elapsed = event.timestamp - lastDragTime
            if elapsed > 0.001 {
                // Smoothed, so one uneven event does not decide the spin.
                let blend = min(1, elapsed / 0.05)
                dragVelocity = CGSize(
                    width: dragVelocity.width * (1 - blend) + delta.width / elapsed * blend,
                    height: dragVelocity.height * (1 - blend) + delta.height / elapsed * blend)
            }
        } else {
            session?.pan(byPoints: delta)
        }
        lastDragTime = event.timestamp
        session?.hover(at: nil)
    }

    override func mouseUp(with event: NSEvent) {
        if !dragged {
            session?.click(at: location(event), count: event.clickCount, extend: event.modifierFlags.contains(.command))
        } else if session?.dragTurnsGlobe == true {
            // Held still before letting go: it stays put. Let go mid-swipe: it spins on and slows.
            let still = event.timestamp - lastDragTime > 0.08
            session?.releaseGlobe(pointsPerSecond: still ? .zero : dragVelocity)
        }
        pressedAt = nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let session, let target = session.target(at: location(event)) else { return nil }
        contextTarget = target
        let menu = NSMenu()
        var entries: [(String, Int)] = [("Filter to This", 0), ("Focus on This", 1), ("Copy Details", 2)]
        if case .node(.process) = target { entries.append(("Reveal in Finder", 3)) }
        // Grouping belongs to the constellation, and the globe places the same groups; the
        // other layouts arrange destinations their own way.
        if [.constellation, .globe, .cyberspace].contains(session.controller.layout) {
            if case .node(.network) = target { entries.append(("Expand into Addresses", 4)) }
            if case .node(.group(.asn, _)) = target { entries.append(("Expand into Addresses", 4)) }
            if case .node(.group(.country, _)) = target { entries.append(("Expand into Addresses", 4)) }
            if case .node(.endpoint) = target { entries.append(("Collapse into Its Group", 4)) }
        }
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
        let actions: [GraphSession.ContextAction] = [.filterToThis, .focusOnThis, .copyDetails, .revealInFinder, .toggleCluster]
        session?.context(actions[sender.tag], contextTarget)
    }

    override func scrollWheel(with event: NSEvent) {
        if event.hasPreciseScrollingDeltas, !event.modifierFlags.contains(.command) {
            // Two fingers on a trackpad pan, or turn the globe; a wheel, or ⌘-scroll, zooms.
            // The trackpad's own momentum carries a swipe on after the fingers lift.
            let delta = CGSize(width: event.scrollingDeltaX, height: -event.scrollingDeltaY)
            if session?.dragTurnsGlobe == true, !event.modifierFlags.contains(.option) {
                session?.turnGlobe(byPoints: delta)
            } else {
                session?.pan(byPoints: delta)
            }
        } else {
            let amount = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.08
            session?.zoomOrDolly(by: Float(exp(amount)), at: location(event))
        }
    }

    override func magnify(with event: NSEvent) {
        session?.zoomOrDolly(by: Float(1 + event.magnification), at: location(event))
    }

    /// Flying keys held down: W A S D and the arrows.
    private var flying = Set<UInt16>()

    /// The flying key an event is, if it is one: W, A, S, D, or an arrow.
    private static func flightKey(_ event: NSEvent) -> UInt16? {
        // Key codes, so the keyboard's layout does not matter: W A S D, then left, right, down, up.
        let codes: Set<UInt16> = [13, 0, 1, 2, 123, 124, 125, 126]
        return codes.contains(event.keyCode) && event.modifierFlags.intersection([.command, .control, .option]).isEmpty
            ? event.keyCode : nil
    }

    private func updateFlight() {
        var direction = SIMD3<Float>.zero
        for code in flying {
            switch code {
            case 13, 126: direction.z += 1
            case 1, 125: direction.z -= 1
            case 0, 123: direction.x -= 1
            case 2, 124: direction.x += 1
            default: break
            }
        }
        session?.fly(simd_clamp(direction, SIMD3(repeating: -1), SIMD3(repeating: 1)))
    }

    override func keyUp(with event: NSEvent) {
        if let code = Self.flightKey(event), flying.remove(code) != nil {
            updateFlight()
        } else {
            super.keyUp(with: event)
        }
    }

    override func resignFirstResponder() -> Bool {
        // A key released while the window was elsewhere never arrives; stop rather than fly on.
        if !flying.isEmpty {
            flying.removeAll()
            updateFlight()
        }
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        if session?.isInSpace == true, let code = Self.flightKey(event) {
            if !event.isARepeat, flying.insert(code).inserted { updateFlight() }
            return
        }
        switch event.charactersIgnoringModifiers {
        case " ": session?.key(.togglePause)
        case "p", "P": session?.key(.cycleProfile)
        case "0": session?.key(.resetView)
        case "/": session?.key(.focusFilter)
        case "i", "I": session?.key(.toggleInspector)
        case "e", "E": session?.key(.toggleKeepEnded)
        case "b", "B": session?.key(.togglePanel)
        case "1": session?.key(.layout(1))
        case "2": session?.key(.layout(2))
        case "3": session?.key(.layout(3))
        case "4": session?.key(.layout(4))
        case "5": session?.key(.layout(5))
        case "6": session?.key(.layout(6))
        case "k", "K": session?.key(.toggleKiosk)
        case "l", "L": session?.key(.toggleThisMac)
        case "t", "T": session?.key(.cycleTheme)
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

    public func makeNSView(context: Context) -> NSView {
        let view = GraphLayerView(device: MTLCreateSystemDefaultDevice(), capture: session.capture != nil)
        view.session = session
        session.attach(view)
        return view
    }

    public func updateNSView(_ view: NSView, context: Context) {}
}
