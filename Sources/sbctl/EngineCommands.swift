import Foundation
import SwitchboardCore
import SwitchboardSources

enum TopCommand {
    static func run(_ options: Options) throws -> Int32 {
        let session = try Session(sourceSpec: options.value("--source") ?? "nstat", flows: options.value("--flows").flatMap(Int.init))
        try session.start()
        defer { session.stop() }

        if options.has("--once") {
            try session.run(for: options.number("--seconds", default: 2))
            print(render(session, rows: Int(options.number("--rows", default: 30)), width: 150, ansi: false), terminator: "")
            return 0
        }

        let limit = options.value("--seconds").flatMap(Double.init)
        var lastDraw = -1.0
        while limit.map({ session.now < $0 }) ?? true {
            try session.tick()
            if session.now - lastDraw >= 1 {
                lastDraw = session.now
                let size = terminalSize()
                // Home, draw, clear whatever is left below.
                print("\u{1B}[H" + render(session, rows: max(size.rows - 7, 5), width: size.columns) + "\u{1B}[J", terminator: "")
                fflush(stdout)
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        print("")
        return 0
    }

    private static func terminalSize() -> (rows: Int, columns: Int) {
        var size = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_row > 0 {
            return (Int(size.ws_row), Int(size.ws_col))
        }
        return (40, 150)
    }

    static func render(_ session: Session, rows: Int, width: Int, ansi: Bool = true) -> String {
        let engine = session.engine
        let open = engine.flows.values.filter { $0.state != .closed }
        let rateIn = open.reduce(0) { $0 + $1.rateIn }
        let rateOut = open.reduce(0) { $0 + $1.rateOut }
        let exposed = engine.listeners.values.count { $0.exposed }

        var lines: [String] = []
        lines.append(
            "switchboard \(Switchboard.version)   \(open.count) flows · \(engine.listeners.count) listening (\(exposed) exposed) · \(engine.processes.count) processes   ↓ \(ByteFormat.rate(rateIn))  ↑ \(ByteFormat.rate(rateOut))"
        )
        lines.append(session.sources.map { "\($0.name): \($0.health.detail)" }.joined(separator: "   "))
        lines.append("")
        lines.append(row(["PROCESS", "PID", "USER", "PROTO", "REMOTE", "SERVICE", "STATE", "AGE", "↓ RATE", "↑ RATE", "↓ TOTAL", "↑ TOTAL", "RTT"]))

        let ordered = engine.flows.values.sorted {
            ($0.rateTotal, $0.bytesTotal, $1.id) > ($1.rateTotal, $1.bytesTotal, $0.id)
        }
        for flow in ordered.prefix(rows) {
            let process = engine.processes[flow.pid]
            let age = (flow.ageExact ? "" : "≥") + ByteFormat.duration(flow.age(at: engine.now))
            lines.append(row([
                process?.name ?? "?", "\(flow.pid)", process?.username ?? "-", flow.key.proto.rawValue,
                flow.key.remote.description, flow.service ?? "-", flow.state.rawValue, age,
                ByteFormat.rate(flow.rateIn), ByteFormat.rate(flow.rateOut),
                ByteFormat.bytes(Double(flow.bytesIn)), ByteFormat.bytes(Double(flow.bytesOut)),
                flow.rttMS.map { String(format: "%.0f ms", $0) } ?? "-",
            ]))
        }
        if ordered.count > rows { lines.append("… \(ordered.count - rows) more") }
        // In a live display each line also erases whatever the previous frame left to its right.
        let end = ansi ? "\u{1B}[K\n" : "\n"
        return lines.map { clip($0, to: width) }.joined(separator: end) + end
    }

    private static let widths = [22, 7, 10, 5, 40, 12, 8, 8, 11, 11, 9, 9, 7]

    private static func row(_ cells: [String]) -> String {
        zip(cells, widths).map { cell, width in
            clip(cell, to: width).padding(toLength: width, withPad: " ", startingAt: 0)
        }.joined(separator: " ")
    }

    private static func clip(_ text: String, to width: Int) -> String {
        text.count > width ? String(text.prefix(max(width - 1, 0))) + "…" : text
    }
}

enum DumpCommand {
    static func run(_ options: Options) throws -> Int32 {
        let session = try Session(sourceSpec: options.value("--source") ?? "nstat", flows: options.value("--flows").flatMap(Int.init))
        try session.start()
        defer { session.stop() }
        try session.run(for: options.number("--seconds", default: 1.5))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(session.engine.snapshot()), as: UTF8.self))
        return 0
    }
}

enum RecordCommand {
    static func run(_ options: Options) throws -> Int32 {
        guard let path = options.positional else {
            print("usage: sbctl record <file.sbtrace> [--seconds N] [--source S]")
            return 2
        }
        let spec = options.value("--source") ?? "nstat"
        let seconds = options.number("--seconds", default: 10)
        let session = try Session(sourceSpec: spec, flows: options.value("--flows").flatMap(Int.init))
        let writer = try TraceWriter(
            url: URL(fileURLWithPath: path), wallClock: session.engine.wallClockOrigin, note: "sbctl record --source \(spec)")
        try session.start()
        defer { session.stop() }
        try session.run(for: seconds, recordingTo: writer)
        try writer.close()
        print("recorded \(writer.recordCount) ticks over \(Int(seconds)) s to \(path): \(session.engine.flows.count) flows, \(session.engine.listeners.count) listeners at the end")
        return 0
    }
}

enum BenchCommand {
    static func run(_ options: Options) throws -> Int32 {
        options.has("--live") ? try live(options) : try simulated(options)
    }

    /// Engine cost on synthetic load, on a simulated clock: no sleeping, so it measures
    /// pure compute per tick.
    private static func simulated(_ options: Options) throws -> Int32 {
        let sizes = options.value("--flows").flatMap(Int.init).map { [$0] } ?? [1000, 5000, 20000]
        let simulatedSeconds = options.number("--seconds", default: 60)
        print("flows     ticks   source ms/tick   engine ms/tick   engine % of a core at 4 Hz   opened   closed")
        for size in sizes {
            let source = SimulatorSource(scenario: .stress, flows: size)
            let engine = FlowEngine()
            var sourceTime = 0.0, engineTime = 0.0
            var opened = 0, closed = 0, ticks = 0
            var time = 0.0
            while time <= simulatedSeconds {
                let a = DispatchTime.now().uptimeNanoseconds
                let events = source.poll(now: time)
                let b = DispatchTime.now().uptimeNanoseconds
                let delta = engine.ingest(events, from: source.name, at: time)
                let c = DispatchTime.now().uptimeNanoseconds
                sourceTime += Double(b - a) / 1e6
                engineTime += Double(c - b) / 1e6
                opened += delta.opened.count
                closed += delta.closed.count
                ticks += 1
                time += 0.25
            }
            let perTick = engineTime / Double(ticks)
            let live = engine.flows.values.count { $0.state != .closed }
            print(String(
                format: "%-9d %5d   %14.3f   %14.3f   %26.2f   %6d   %6d",
                live, ticks, sourceTime / Double(ticks), perTick, perTick * 4 / 10, opened, closed))
        }
        return 0
    }

    /// Whole-process CPU while watching the real machine.
    private static func live(_ options: Options) throws -> Int32 {
        let seconds = options.number("--seconds", default: 10)
        let session = try Session(
            sourceSpec: options.value("--source") ?? "nstat", counterInterval: options.number("--counter-interval", default: 1.0))
        try session.start()
        defer { session.stop() }
        try session.run(for: 2)

        func cpuSeconds() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
                + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        }
        let cpuBefore = cpuSeconds()
        let wallBefore = session.now
        try session.run(for: seconds)
        let cpu = cpuSeconds() - cpuBefore
        let wall = session.now - wallBefore

        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        let memory = result == KERN_SUCCESS ? ByteFormat.bytes(Double(info.resident_size)) : "?"

        let open = session.engine.flows.values.count { $0.state != .closed }
        print(String(
            format: "live engine at 4 Hz over %.1f s: %d flows, %d listeners — %.2f%% of one core, resident memory %@",
            wall, open, session.engine.listeners.count, cpu / wall * 100, memory))
        return 0
    }
}
