import Foundation
import SwitchboardCore
import SwitchboardSources

/// Command-line options shared by the engine commands.
struct Options {
    let arguments: [String]

    func value(_ flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    func number(_ flag: String, default fallback: Double) -> Double {
        value(flag).flatMap(Double.init) ?? fallback
    }

    func has(_ flag: String) -> Bool { arguments.contains(flag) }

    /// The first argument that is neither a flag nor a flag's value.
    var positional: String? {
        var skip = false
        for argument in arguments {
            if skip {
                skip = false
                continue
            }
            if argument.hasPrefix("--") {
                skip = !["--once", "--json", "--live", "--loop"].contains(argument)
                continue
            }
            return argument
        }
        return nil
    }
}

/// An engine and the sources feeding it, ticked by whoever owns the session.
final class Session {
    let engine: FlowEngine
    let sources: [any FlowSource]
    /// Synthetic or recorded traffic, which can be stepped on a simulated clock.
    let simulated: Bool
    private let startedAt = DispatchTime.now().uptimeNanoseconds

    init(sourceSpec: String, flows: Int? = nil, counterInterval: Double = 1.0) throws {
        let resolved = try SourceSpec.make(sourceSpec, flows: flows, counterInterval: counterInterval)
        sources = resolved.sources
        simulated = resolved.simulated
        engine = FlowEngine(resolver: SourceSpec.resolver(for: resolved))
        engine.wallClockOrigin = Date().timeIntervalSince1970
    }

    func start() throws {
        for source in sources { try source.start() }
    }

    func stop() {
        for source in sources { source.stop() }
    }

    var now: EngineTime {
        Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1e9
    }

    /// Polls every source and advances the engine. Sources listed first win when two
    /// report the same flow.
    @discardableResult
    func tick(recordingTo writer: TraceWriter? = nil) throws -> EngineDelta {
        var combined = EngineDelta()
        let time = now
        for source in sources {
            let events = source.poll(now: time)
            try writer?.append(TraceFile.Record(t: time, source: source.name, events: events))
            let delta = engine.ingest(events, from: source.name, at: time)
            if let capture = source as? CaptureProvider { engine.observe(capture.pollCapture(now: time), at: time) }
            combined.opened += delta.opened
            combined.updated += delta.updated
            combined.closed += delta.closed
            combined.purged += delta.purged
            combined.listenersChanged = combined.listenersChanged || delta.listenersChanged
        }
        return combined
    }

    /// Ticks at 4 Hz for the given time.
    func run(for seconds: Double, recordingTo writer: TraceWriter? = nil) throws {
        let end = now + seconds
        while now < end {
            try tick(recordingTo: writer)
            Thread.sleep(forTimeInterval: 0.25)
        }
        try tick(recordingTo: writer)
    }
}
