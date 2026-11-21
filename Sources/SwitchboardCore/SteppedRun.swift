/// Drives sources and an engine on a simulated clock, with no sleeping and no threads.
///
/// Given a simulator or a trace this produces exactly the same model every time, which
/// is what golden-image tests and reproducible dumps are built on.
public enum SteppedRun {
    public static func run(
        sources: [any FlowSource], engine: FlowEngine, until end: EngineTime, step: Double = 0.25,
        each: (EngineTime) -> Void = { _ in }
    ) {
        var tick = 0
        while Double(tick) * step <= end + 1e-9 {
            let time = Double(tick) * step
            for source in sources {
                engine.ingest(source.poll(now: time), from: source.name, at: time)
            }
            each(time)
            tick += 1
        }
    }
}
