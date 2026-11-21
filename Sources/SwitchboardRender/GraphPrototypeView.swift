import MetalKit
import SwiftUI

/// Hosts the prototype renderer in SwiftUI.
public struct GraphPrototypeView: NSViewRepresentable {
    private let edgeCount: Int
    private let stats: FrameStats
    private let capture: FrameCapture?
    private let onReady: @MainActor (Result<PrototypeRenderer.Info, Error>) -> Void

    public init(
        edgeCount: Int,
        stats: FrameStats,
        capture: FrameCapture? = nil,
        onReady: @escaping @MainActor (Result<PrototypeRenderer.Info, Error>) -> Void
    ) {
        self.edgeCount = edgeCount
        self.stats = stats
        self.capture = capture
        self.onReady = onReady
    }

    @MainActor
    public final class Coordinator {
        var renderer: PrototypeRenderer?
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 5 / 255, green: 8 / 255, blue: 15 / 255, alpha: 1)
        view.preferredFramesPerSecond = 120
        // Reading frames back needs a drawable that is more than a framebuffer.
        view.framebufferOnly = capture == nil
        do {
            let renderer = try PrototypeRenderer(view: view, edgeCount: edgeCount, stats: stats, capture: capture)
            context.coordinator.renderer = renderer
            view.delegate = renderer
            let info = renderer.info
            let onReady = self.onReady
            Task { @MainActor in onReady(.success(info)) }
        } catch {
            let onReady = self.onReady
            Task { @MainActor in onReady(.failure(error)) }
        }
        return view
    }

    public func updateNSView(_ view: MTKView, context: Context) {}
}
