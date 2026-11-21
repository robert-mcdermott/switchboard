import Metal
import QuartzCore
import simd

/// Where the view is looking.
public struct Camera: Sendable, Equatable {
    /// World position at the middle of the view.
    public var center: SIMD2<Float>
    /// Pixels per world unit.
    public var scale: Float

    public init(center: SIMD2<Float> = .zero, scale: Float = 1) {
        self.center = center
        self.scale = scale
    }

    /// The scale at which a layout of the given radius just fits the view.
    public static func fitting(extent: Float, viewport: SIMD2<Float>) -> Float {
        min(viewport.x, viewport.y) * 0.5 / max(extent, 1)
    }

    /// The scale at which a layout of the given half-width and half-height just fits.
    public static func fitting(halfSize: SIMD2<Float>, viewport: SIMD2<Float>) -> Float {
        min(viewport.x * 0.5 / max(halfSize.x, 1), viewport.y * 0.5 / max(halfSize.y, 1))
    }
}

/// How much spectacle to apply (docs/SPEC.md §9.3). Every profile shows the same data.
public enum RenderProfile: String, CaseIterable, Sendable {
    /// Full bloom, travelling pulses, a little grain. For walls and demos.
    case cinema
    /// Restrained bloom, more labels, no grain. For long sessions.
    case `operator`
    /// No motion at all: rate shows as thickness and brightness alone.
    case still

    /// How often to draw. Cinema uses all a ProMotion display offers; Operator, meant for
    /// long sessions, draws half as often for half the cost, which pulses at these speeds
    /// do not show; Still has almost nothing that moves.
    public var frameRates: CAFrameRateRange {
        switch self {
        case .cinema: CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        case .operator: CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        case .still: CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        }
    }

    var bloom: Float {
        switch self {
        case .cinema: 0.8
        case .operator, .still: 0.32
        }
    }

    var grain: Float { self == .cinema ? 0.018 : 0 }
    var pulseGain: Float { self == .still ? 0 : (self == .cinema ? 1 : 0.7) }
    var gridAlpha: Float { self == .cinema ? 1 : 0.7 }

    /// How many endpoints may carry a label.
    public var labelBudget: Int {
        switch self {
        case .cinema: 14
        case .operator: 40
        case .still: 28
        }
    }

    public var next: RenderProfile {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

/// Draws a `RenderFrame`: field, edges, nodes, bloom, tone map, labels.
///
/// It renders into any texture, so the window and the headless snapshot path share every
/// line of drawing code.
/// Used from one thread at a time: the render thread in the app, the main thread headless.
public final class GraphRenderer: @unchecked Sendable {
    public enum RendererError: Error {
        case unavailable(String)
    }

    public var profile: RenderProfile = .cinema
    public let shaderCompileMS: Double
    public let resourceOrigin: RenderResources.Origin

    private let device: MTLDevice
    private let labels: LabelAtlas
    private let icons: IconAtlas
    private let sampler: MTLSamplerState

    private let fieldPipeline: MTLRenderPipelineState
    private let edgePipeline: MTLRenderPipelineState
    private let nodePipeline: MTLRenderPipelineState
    private let downPipeline: MTLRenderPipelineState
    private let upPipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState
    private let labelPipeline: MTLRenderPipelineState

    private var scene: MTLTexture?
    private var bloomChain: [MTLTexture] = []
    private var edgeBuffer: MTLBuffer?
    private var nodeBuffer: MTLBuffer?
    private var labelBuffer: MTLBuffer?

    private static let sceneFormat = MTLPixelFormat.rgba16Float
    private static let bloomLevels = 4
    private static let edgeSegments = 24

    private enum Blend { case none, additive, premultiplied }

    public init(device: MTLDevice, targetFormat: MTLPixelFormat) throws {
        precondition(MemoryLayout<EdgeInstance>.stride == 64, "EdgeInstance must match the shader")
        precondition(MemoryLayout<NodeInstance>.stride == 64, "NodeInstance must match the shader")
        precondition(MemoryLayout<LabelInstance>.stride == 64, "LabelInstance must match the shader")
        precondition(MemoryLayout<Uniforms>.stride == 80, "Uniforms must match the shader")
        precondition(MemoryLayout<Uniforms>.offset(of: \Uniforms.field) == 48, "Uniforms must match the shader")

        guard let labels = LabelAtlas(device: device), let icons = IconAtlas(device: device) else {
            throw RendererError.unavailable("could not create texture atlases")
        }
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw RendererError.unavailable("could not create a sampler")
        }

        let source = try RenderResources.shaderSource(named: "Graph")
        let started = CACurrentMediaTime()
        let library = try device.makeLibrary(source: source, options: nil)
        shaderCompileMS = (CACurrentMediaTime() - started) * 1000
        resourceOrigin = RenderResources.located.origin

        func pipeline(_ vertex: String, _ fragment: String, _ format: MTLPixelFormat, _ blend: Blend) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = fragment
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = format
            switch blend {
            case .none:
                break
            case .additive:
                attachment.isBlendingEnabled = true
                attachment.sourceRGBBlendFactor = .one
                attachment.destinationRGBBlendFactor = .one
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationAlphaBlendFactor = .one
            case .premultiplied:
                attachment.isBlendingEnabled = true
                attachment.sourceRGBBlendFactor = .one
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }

        fieldPipeline = try pipeline("fullscreen_vertex", "field_fragment", Self.sceneFormat, .additive)
        edgePipeline = try pipeline("edge_vertex", "edge_fragment", Self.sceneFormat, .additive)
        nodePipeline = try pipeline("node_vertex", "node_fragment", Self.sceneFormat, .premultiplied)
        downPipeline = try pipeline("fullscreen_vertex", "downsample_fragment", Self.sceneFormat, .none)
        upPipeline = try pipeline("fullscreen_vertex", "upsample_fragment", Self.sceneFormat, .additive)
        compositePipeline = try pipeline("fullscreen_vertex", "composite_fragment", targetFormat, .none)
        labelPipeline = try pipeline("label_vertex", "label_fragment", targetFormat, .premultiplied)

        self.device = device
        self.labels = labels
        self.icons = icons
        self.sampler = sampler
    }

    /// Encodes one frame into `commandBuffer`, ending on `target`.
    public func render(
        _ frame: RenderFrame, camera: Camera, time: Float, backing: Float, to target: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) {
        let width = target.width, height = target.height
        guard width > 0, height > 0 else { return }
        prepareTargets(width: width, height: height)
        guard let scene, bloomChain.count == Self.bloomLevels else { return }

        var uniforms = Uniforms(
            viewport: SIMD2(Float(width), Float(height)), center: camera.center, scale: camera.scale, time: time,
            pulseGain: profile.pulseGain, bloom: profile.bloom * frame.bloomScale, grain: profile.grain, gridAlpha: frame.flatGrid ? profile.gridAlpha : 0,
            backing: backing, field: SIMD4(frame.palette.field, 1), grid: SIMD4(frame.palette.grid, 1))
        let uniformLength = MemoryLayout<Uniforms>.stride

        // Icons and label textures are filled in on the way through.
        var nodes = frame.nodes
        for entry in frame.icons where nodes.indices.contains(entry.node) {
            nodes[entry.node].icon = icons.slot(forExecutable: entry.path)
        }
        let labelInstances = makeLabels(frame, nodes: nodes, camera: camera, backing: backing)

        let edgeCount = fill(&edgeBuffer, with: frame.edges)
        let nodeCount = fill(&nodeBuffer, with: nodes)
        let labelCount = fill(&labelBuffer, with: labelInstances)

        // 1. The scene, in linear light.
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass(scene, clear: true)) {
            encoder.label = "scene"
            encoder.setVertexBytes(&uniforms, length: uniformLength, index: 1)
            encoder.setFragmentBytes(&uniforms, length: uniformLength, index: 1)
            encoder.setFragmentSamplerState(sampler, index: 0)

            encoder.setRenderPipelineState(fieldPipeline)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

            if edgeCount > 0, let edgeBuffer {
                encoder.setRenderPipelineState(edgePipeline)
                encoder.setVertexBuffer(edgeBuffer, offset: 0, index: 0)
                encoder.drawPrimitives(
                    type: .triangleStrip, vertexStart: 0, vertexCount: (Self.edgeSegments + 1) * 2, instanceCount: edgeCount)
            }
            if nodeCount > 0, let nodeBuffer {
                encoder.setRenderPipelineState(nodePipeline)
                encoder.setVertexBuffer(nodeBuffer, offset: 0, index: 0)
                encoder.setFragmentTexture(icons.texture, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: nodeCount)
            }
            encoder.endEncoding()
        }

        // 2. Bloom: shrink the bright parts down a chain, then add each level back up.
        var source = scene
        for (level, destination) in bloomChain.enumerated() {
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass(destination, clear: true)) else { continue }
            encoder.label = "bloom down \(level)"
            // Only the first step decides what counts as bright.
            var params = level == 0 ? SIMD4<Float>(0.4, 0.6, 0, 0) : SIMD4<Float>(0, 0, 0, 0)
            encoder.setRenderPipelineState(downPipeline)
            encoder.setFragmentTexture(source, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.setFragmentBytes(&params, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            source = destination
        }
        for level in stride(from: bloomChain.count - 1, to: 0, by: -1) {
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass(bloomChain[level - 1], clear: false)) else { continue }
            encoder.label = "bloom up \(level)"
            encoder.setRenderPipelineState(upPipeline)
            encoder.setFragmentTexture(bloomChain[level], index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }

        // 3. Tone map onto the target, then labels on top where bloom cannot smear them.
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass(target, clear: true)) {
            encoder.label = "composite"
            encoder.setVertexBytes(&uniforms, length: uniformLength, index: 1)
            encoder.setFragmentBytes(&uniforms, length: uniformLength, index: 1)
            encoder.setFragmentSamplerState(sampler, index: 0)

            encoder.setRenderPipelineState(compositePipeline)
            encoder.setFragmentTexture(scene, index: 0)
            encoder.setFragmentTexture(bloomChain[0], index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

            if labelCount > 0, let labelBuffer {
                encoder.setRenderPipelineState(labelPipeline)
                encoder.setVertexBuffer(labelBuffer, offset: 0, index: 0)
                encoder.setFragmentTexture(labels.texture, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: labelCount)
            }
            encoder.endEncoding()
        }
    }

    // MARK: - Internals

    private func makeLabels(_ frame: RenderFrame, nodes: [NodeInstance], camera: Camera, backing: Float) -> [LabelInstance] {
        var instances: [LabelInstance] = []
        instances.reserveCapacity(frame.labels.count)
        // Glyphs were rasterised at two pixels per point; scale to this display.
        let glyphScale = backing / Float(LabelAtlas.rasterScale)
        // This Mac's label keeps the standard theme's cyan in the colour-safe theme, as it always has.
        let theme = frame.palette
        let hostLabel = theme == .colorSafe ? Palette.host : theme.host
        let colors: [SIMD4<Float>] = [
            SIMD4(hostLabel, 1), SIMD4(theme.text, 0.95), SIMD4(theme.secondaryText * 1.25, 0.95),
        ]
        // Labels arrive most important first; a label that would cover an earlier one is dropped.
        var placed: [SIMD4<Float>] = []
        for request in frame.labels where nodes.indices.contains(request.node) {
            guard let entry = labels.entry(for: request.text, kind: request.kind) else { continue }
            let node = nodes[request.node]
            let size = entry.size * glyphScale
            let radius = max(node.radius * camera.scale, 1.6 * backing)
            let reach = radius + 9 * backing

            var offset: SIMD2<Float>
            let distance = simd_length(node.center)
            if let side = request.side {
                // A layout that has said where its labels go: beside the node, or beneath it.
                offset = side == 0
                    ? SIMD2(-size.x * 0.5, -reach)
                    : SIMD2(side > 0 ? reach : -reach - size.x, size.y * 0.5)
            } else if request.kind == 0 || distance < 1 {
                // The host: centred beneath the node.
                offset = SIMD2(-size.x * 0.5, -reach)
            } else {
                // Everything else: pushed outward, away from the centre, so labels sit in
                // open space instead of across the edges. Text to the right of the centre
                // starts at the node; text to the left ends at it.
                let outward = node.center / distance
                let side = min(max((outward.x + 0.35) / 0.7, 0), 1)
                let vertical = 1 - abs(2 * side - 1)
                offset = SIMD2(
                    outward.x * reach - size.x * (1 - side),
                    outward.y * reach + size.y * 0.5 + outward.y * size.y * 0.5 * vertical)
            }

            let origin = (node.center - camera.center) * camera.scale + offset
            let box = SIMD4(origin.x, origin.y - size.y, origin.x + size.x, origin.y)
            let margin = 2 * backing
            if placed.contains(where: { $0.x < box.z + margin && box.x < $0.z + margin && $0.y < box.w + margin && box.y < $0.w + margin }) {
                continue
            }
            placed.append(box)
            instances.append(LabelInstance(
                anchor: node.center, offset: offset, size: size, uv: entry.uv,
                color: colors[min(max(request.kind, 0), colors.count - 1)]))
        }
        return instances
    }

    private func pass(_ texture: MTLTexture, clear: Bool) -> MTLRenderPassDescriptor {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = texture
        descriptor.colorAttachments[0].loadAction = clear ? .clear : .load
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        return descriptor
    }

    private func prepareTargets(width: Int, height: Int) {
        if let scene, scene.width == width, scene.height == height { return }
        func make(_ w: Int, _ h: Int) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: Self.sceneFormat, width: max(w, 1), height: max(h, 1), mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            return device.makeTexture(descriptor: descriptor)
        }
        scene = make(width, height)
        bloomChain = (1...Self.bloomLevels).compactMap { make(width >> $0, height >> $0) }
    }

    /// Copies instances into a buffer, growing it when needed. Returns the count.
    private func fill<T>(_ buffer: inout MTLBuffer?, with instances: [T]) -> Int {
        guard !instances.isEmpty else { return 0 }
        let needed = MemoryLayout<T>.stride * instances.count
        if buffer == nil || buffer!.length < needed {
            buffer = device.makeBuffer(length: max(needed * 3 / 2, 4096), options: .storageModeShared)
        }
        guard let buffer else { return 0 }
        instances.withUnsafeBytes { buffer.contents().copyMemory(from: $0.baseAddress!, byteCount: needed) }
        return instances.count
    }
}
