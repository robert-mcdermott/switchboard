import MetalKit
import QuartzCore
import SwitchboardCore
import simd

/// M0 prototype renderer: a field of animated edges, enough to prove the pipeline and
/// measure it. Replaced by the real engine in M2.
@MainActor
public final class PrototypeRenderer: NSObject, MTKViewDelegate {
    /// Must match `EdgeInstance` in EdgePrototype.metal.
    struct EdgeInstance {
        var p0: SIMD2<Float>
        var p1: SIMD2<Float>
        var control: SIMD2<Float>
        var halfWidth: Float
        var phase: Float
        var color: SIMD4<Float>
        var speed: Float
        var density: Float
        var padding: SIMD2<Float> = .zero
    }

    /// Must match `Uniforms` in EdgePrototype.metal.
    struct Uniforms {
        var viewport: SIMD2<Float>
        var time: Float
        var scale: Float
    }

    public struct Info: Sendable {
        public var deviceName: String
        public var edgeCount: Int
        public var shaderCompileMS: Double
        public var resourceOrigin: RenderResources.Origin
    }

    public let info: Info
    public let stats: FrameStats
    private let capture: FrameCapture?
    private let device: MTLDevice

    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let instances: MTLBuffer
    private let edgeCount: Int
    private let startTime = CACurrentMediaTime()
    private var lastFrameTime: CFTimeInterval = 0

    private static let segments = 24
    /// World-space radius that is fitted to the shorter side of the view.
    private static let worldRadius: Float = 600

    public init(view: MTKView, edgeCount: Int, stats: FrameStats, capture: FrameCapture? = nil) throws {
        guard let device = view.device, let commandQueue = device.makeCommandQueue() else {
            throw RendererError.noDevice
        }
        precondition(MemoryLayout<EdgeInstance>.stride == 64, "EdgeInstance must match the shader layout")

        let source = try RenderResources.shaderSource(named: "EdgePrototype")
        let compileStart = CACurrentMediaTime()
        let library = try device.makeLibrary(source: source, options: nil)
        let compileMS = (CACurrentMediaTime() - compileStart) * 1000

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "edge_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "edge_fragment")
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = view.colorPixelFormat
        // Additive: light accumulates where edges cross.
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .one
        attachment.destinationRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .one
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        let edges = Self.makeEdges(count: edgeCount)
        guard let buffer = device.makeBuffer(
            bytes: edges, length: MemoryLayout<EdgeInstance>.stride * edges.count, options: .storageModeShared)
        else { throw RendererError.noDevice }
        instances = buffer

        self.commandQueue = commandQueue
        self.edgeCount = edges.count
        self.stats = stats
        self.capture = capture
        self.device = device
        info = Info(
            deviceName: device.name, edgeCount: edges.count, shaderCompileMS: compileMS,
            resourceOrigin: RenderResources.located.origin)
        super.init()
    }

    public enum RendererError: Error {
        case noDevice
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        let frameStart = CACurrentMediaTime()
        guard let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }

        let size = view.drawableSize
        var uniforms = Uniforms(
            viewport: SIMD2(Float(size.width), Float(size.height)),
            time: Float(frameStart - startTime),
            scale: Float(min(size.width, size.height)) * 0.5 / Self.worldRadius)

        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(instances, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.drawPrimitives(
            type: .triangleStrip, vertexStart: 0, vertexCount: (Self.segments + 1) * 2, instanceCount: edgeCount)
        encoder.endEncoding()

        // Copy the finished frame out if someone asked for it.
        var captured: (texture: MTLTexture, url: URL)?
        if let url = capture?.take(), !view.framebufferOnly {
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
    }

    // MARK: - Synthetic scene

    /// A stand-in constellation: this Mac at the centre, a ring of processes, and remote
    /// endpoints scattered beyond. Deterministic, so every run draws the same picture.
    private static func makeEdges(count: Int) -> [EdgeInstance] {
        var random = SplitMix64(seed: 0x5B17_C0DE)
        let palette: [(color: SIMD4<Float>, weight: Float)] = [
            (SIMD4(0.216, 0.902, 1.000, 1), 0.52),  // TLS — cyan
            (SIMD4(0.608, 0.549, 1.000, 1), 0.20),  // QUIC — violet
            (SIMD4(0.361, 0.949, 0.647, 1), 0.12),  // DNS — green
            (SIMD4(1.000, 0.784, 0.341, 1), 0.06),  // SSH — amber
            (SIMD4(1.000, 0.541, 0.239, 1), 0.04),  // cleartext HTTP — orange
            (SIMD4(0.486, 0.553, 0.651, 1), 0.06),  // other — slate
        ]
        func pickColor() -> SIMD4<Float> {
            var roll = random.unit()
            for entry in palette {
                if roll < entry.weight { return entry.color }
                roll -= entry.weight
            }
            return palette[0].color
        }
        func polar(_ radius: Float, _ angle: Float) -> SIMD2<Float> {
            SIMD2(cos(angle), sin(angle)) * radius
        }

        let processCount = max(8, min(48, count / 20))
        let turn: Float = 2 * .pi
        var processAngles: [Float] = []
        for index in 0..<processCount {
            let jitter: Float = (random.unit() - 0.5) * 0.08
            processAngles.append(Float(index) / Float(processCount) * turn + jitter)
        }
        let processRadius: Float = 170

        var edges: [EdgeInstance] = []
        edges.reserveCapacity(count)

        // Mac → each process.
        for angle in processAngles.prefix(count) {
            edges.append(
                EdgeInstance(
                    p0: .zero, p1: polar(processRadius, angle), control: polar(processRadius * 0.5, angle + 0.12),
                    halfWidth: 3.2, phase: random.unit(), color: SIMD4(0.55, 0.75, 0.95, 1),
                    speed: 0.25 + random.unit() * 0.5, density: 1.5))
        }

        // Each remaining edge runs from a process to a remote endpoint in its sector.
        while edges.count < count {
            // Skew toward a few busy processes, as on a real machine.
            let skew: Float = pow(random.unit(), 2.2)
            let index = Int(skew * Float(processCount)) % processCount
            let origin: SIMD2<Float> = polar(processRadius, processAngles[index])
            let spread: Float = turn / Float(processCount) * 2.4
            let offset: Float = (random.unit() - 0.5) * spread
            let reach: Float = pow(random.unit(), 0.8)
            let destination: SIMD2<Float> = polar(290 + reach * 290, processAngles[index] + offset)

            let middle: SIMD2<Float> = (origin + destination) * Float(0.5)
            let along: SIMD2<Float> = destination - origin
            let curvature: Float = (random.unit() - 0.5) * 0.28
            let bend: SIMD2<Float> = SIMD2<Float>(-along.y, along.x) * curvature
            let busy: Float = pow(random.unit(), 3)
            let lanes: Float = 1 + floor(random.unit() * 3)

            edges.append(
                EdgeInstance(
                    p0: origin, p1: destination, control: middle + bend,
                    halfWidth: 1.4 + busy * 3.2, phase: random.unit(), color: pickColor(),
                    speed: 0.12 + busy * 0.9, density: lanes))
        }
        return edges
    }
}
