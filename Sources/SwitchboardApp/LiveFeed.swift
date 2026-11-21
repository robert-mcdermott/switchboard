import Foundation
import SwitchboardCore
import SwitchboardRender
import SwitchboardSources

/// Runs the sources and the flow engine on a background thread and hands each result to
/// the graph. This is Standalone mode: the engine lives inside the app (docs/SPEC.md §5.1).
final class LiveFeed: @unchecked Sendable {
    struct Summary: Sendable {
        var flows = 0
        var listeners = 0
        var exposed = 0
        var processes = 0
        var rateIn = 0.0
        var rateOut = 0.0
        var sources: [String] = []
        var healthy = true
    }

    private let sources: [any FlowSource]
    private let engine: FlowEngine
    private let controller: GraphController
    private let clock: @Sendable () -> Float
    private let onSummary: @Sendable (Summary) -> Void
    private let lock = NSLock()
    private var running = false
    /// Synthetic or recorded traffic.
    let simulated: Bool

    init(
        spec: String, flows: Int?, controller: GraphController, clock: @escaping @Sendable () -> Float,
        onSummary: @escaping @Sendable (Summary) -> Void
    ) throws {
        let resolved = try SourceSpec.make(spec, flows: flows)
        sources = resolved.sources
        simulated = resolved.simulated
        engine = FlowEngine(resolver: SourceSpec.resolver(for: resolved))
        engine.wallClockOrigin = Date().timeIntervalSince1970
        self.controller = controller
        self.clock = clock
        self.onSummary = onSummary
    }

    func start() {
        lock.withLock { running = true }
        let thread = Thread { [self] in run() }
        thread.name = "switchboard.feed"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func stop() {
        lock.withLock { running = false }
    }

    /// Counters are refreshed twice as often while the window is in front. Asking for them
    /// is what costs CPU, so there is no reason to pay when nobody is looking.
    func setForeground(_ foreground: Bool) {
        for case let source as NStatSource in sources {
            source.counterInterval = foreground ? 0.5 : 1.0
        }
    }

    private func run() {
        var failures: [String] = []
        for source in sources {
            do { try source.start() } catch { failures.append("\(source.name): \(error)") }
        }
        let started = DispatchTime.now().uptimeNanoseconds
        var tick = 0
        while lock.withLock({ running }) {
            let now = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
            for source in sources {
                engine.ingest(source.poll(now: now), from: source.name, at: now)
            }
            controller.update(engine.snapshot(), time: clock())

            if tick % 2 == 0 {
                var summary = Summary()
                for flow in engine.flows.values where flow.state != .closed {
                    summary.flows += 1
                    summary.rateIn += flow.rateIn
                    summary.rateOut += flow.rateOut
                }
                summary.listeners = engine.listeners.count
                summary.exposed = engine.listeners.values.count { $0.exposed }
                summary.processes = engine.processes.count
                summary.sources = sources.map { "\($0.name): \($0.health.detail)" } + failures
                summary.healthy = failures.isEmpty && sources.allSatisfy { $0.health.running }
                onSummary(summary)
            }
            tick += 1
            Thread.sleep(forTimeInterval: 0.25)
        }
        for source in sources { source.stop() }
    }
}
