import Foundation
import SwitchboardCore
import SwitchboardRender
import SwitchboardSources

/// Runs the sources and the flow engine on a background thread and hands each result to
/// the graph.
///
/// It starts in Standalone mode, with the engine fed by sources inside the app. When the
/// root collector's socket appears it switches to Full mode and feeds the engine from the
/// collector instead; if the collector goes away it switches back (docs/SPEC.md §5.1).
final class LiveFeed: @unchecked Sendable {
    enum Mode: Sendable, Equatable {
        case simulated
        /// Sources inside the app: this account's processes.
        case standalone
        /// The collector, and the account it runs as. Zero is root, which sees everyone.
        case full(collectorUID: UInt32)
    }

    struct Summary: Sendable {
        var flows = 0
        var listeners = 0
        var exposed = 0
        var processes = 0
        var rateIn = 0.0
        var rateOut = 0.0
        var sources: [String] = []
        var healthy = true
        var mode = Mode.standalone
    }

    private let spec: String
    private let flows: Int?
    private let controller: GraphController
    private let clock: @Sendable () -> Float
    private let onSummary: @Sendable (Summary) -> Void
    private let onSnapshot: @Sendable (EngineSnapshot) -> Void
    private let collectorPath: String
    /// Only the default source gives way to the collector; an explicit choice is kept.
    private let followsCollector: Bool
    private let lock = NSLock()
    private var running = false
    private var foreground = true
    // Set from the main thread, picked up by the feed thread on its next tick.
    private var wantedEnricher: (any AddressEnricher)?
    private var enricherChanged = false
    private var activeLookups = false
    /// Synthetic or recorded traffic.
    let simulated: Bool

    // Touched only on the feed thread.
    private var sources: [any FlowSource]
    private var engine: FlowEngine
    private var collector: CollectorClient?
    private var failures: [String] = []
    private let trust = TrustCache()
    /// Exists only while the user has chosen active lookups: nothing else here sends packets.
    private var reverse: ReverseResolver?

    init(
        spec: String, flows: Int?, collectorPath: String, controller: GraphController,
        clock: @escaping @Sendable () -> Float,
        onSummary: @escaping @Sendable (Summary) -> Void,
        onSnapshot: @escaping @Sendable (EngineSnapshot) -> Void
    ) throws {
        let resolved = try SourceSpec.make(spec, flows: flows)
        self.spec = spec
        self.flows = flows
        self.collectorPath = collectorPath
        sources = resolved.sources
        simulated = resolved.simulated
        collector = resolved.collector
        followsCollector = spec == "nstat"
        engine = FlowEngine(resolver: SourceSpec.resolver(for: resolved))
        engine.wallClockOrigin = Date().timeIntervalSince1970
        self.controller = controller
        self.clock = clock
        self.onSummary = onSummary
        self.onSnapshot = onSnapshot
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
        lock.withLock { self.foreground = foreground }
    }

    /// Supplies location, network owner, and tags. Applied on the next tick.
    func setEnricher(_ enricher: (any AddressEnricher)?) {
        lock.withLock {
            wantedEnricher = enricher
            enricherChanged = true
        }
    }

    /// Whether to ask the system resolver for names of addresses nothing else has named.
    func setActiveLookups(_ on: Bool) {
        lock.withLock { activeLookups = on }
    }

    private func startSources() {
        failures = []
        for source in sources {
            do { try source.start() } catch { failures.append("\(source.name): \(error)") }
        }
    }

    /// Replaces the sources and starts the engine afresh. Flows are keyed by the source
    /// that reported them, so they cannot be carried across; the graph keeps its layout.
    private func switchSources(to resolved: SourceSpec.Resolved, origin: Double) {
        sources.forEach { $0.stop() }
        sources = resolved.sources
        collector = resolved.collector
        engine = FlowEngine(resolver: SourceSpec.resolver(for: resolved))
        engine.wallClockOrigin = origin
        engine.enricher = lock.withLock { wantedEnricher }
        startSources()
    }

    private func run() {
        startSources()
        let started = DispatchTime.now().uptimeNanoseconds
        let origin = engine.wallClockOrigin
        var tick = 0
        while lock.withLock({ running }) {
            let now = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9

            if followsCollector {
                if let collector, !collector.isConnected {
                    // The collector has gone: carry on with what the app can see by itself.
                    if let local = try? SourceSpec.make(spec, flows: flows) { switchSources(to: local, origin: origin) }
                } else if collector == nil, tick % 8 == 0, FileManager.default.fileExists(atPath: collectorPath),
                          let full = try? SourceSpec.make("collector:\(collectorPath)")
                {
                    switchSources(to: full, origin: origin)
                }
            }

            let (newEnricher, changed, lookups) = lock.withLock { () -> ((any AddressEnricher)?, Bool, Bool) in
                defer { enricherChanged = false }
                return (wantedEnricher, enricherChanged, activeLookups)
            }
            if changed {
                engine.enricher = newEnricher
                engine.refreshEnrichment()
            }
            if lookups, !simulated {
                if reverse == nil { reverse = ReverseResolver() }
            } else {
                reverse = nil
            }

            let interval = lock.withLock { foreground } ? 0.5 : 1.0
            for case let source as NStatSource in sources where source.counterInterval != interval {
                source.counterInterval = interval
            }

            for source in sources {
                engine.ingest(source.poll(now: now), from: source.name, at: now)
                // Hostnames and observed services, where a source can supply them.
                if let capture = source as? CaptureProvider { engine.observe(capture.pollCapture(now: now), at: now) }
            }
            // Signatures are checked in the background; results are picked up as they land.
            if !simulated {
                for process in engine.processes.values where process.signing == .unknown {
                    guard let path = process.path, let verdict = trust.verdict(forPath: path) else { continue }
                    engine.setSigning(pid: process.pid, status: verdict.status, teamID: verdict.teamID)
                }
            }
            if let reverse {
                for flow in engine.flows.values where flow.hostname == nil && flow.state != .closed {
                    reverse.request(flow.key.remote.address)
                }
                engine.observe(reverse.pollCapture(now: now), at: now)
            }
            let snapshot = engine.snapshot()
            controller.update(snapshot, time: clock())
            // The tables and charts need the model too, but only once a second.
            if tick % 4 == 0 { onSnapshot(snapshot) }

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
                // In Full mode the collector describes all of its sources, including packet capture.
                let reported = collector?.health ?? []
                summary.sources = (reported.isEmpty ? sources.map { "\($0.name): \($0.health.detail)" } : reported) + failures
                // In Full mode a source the collector could not run is reported, not treated as a fault here.
                summary.healthy = failures.isEmpty && (collector != nil || sources.allSatisfy { $0.health.running })
                if let collector {
                    summary.mode = .full(collectorUID: collector.collectorUID)
                } else {
                    summary.mode = simulated ? .simulated : .standalone
                }
                onSummary(summary)
            }
            tick += 1
            Thread.sleep(forTimeInterval: 0.25)
        }
        sources.forEach { $0.stop() }
    }
}
