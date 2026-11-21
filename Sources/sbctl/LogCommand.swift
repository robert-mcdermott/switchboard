import Foundation
import SwitchboardCore
import SwitchboardStore

/// Reads and maintains the log from the terminal.
enum LogCommand {
    static let usage = """
        usage:
          sbctl log stats
          sbctl log query "<filter>" [--since 1h] [--limit 20]
          sbctl log export <file> [--format csv|jsonl] [--filter "<filter>"] [--since 7d] [--redact]
          sbctl log prune [--days 30] [--megabytes 2000]
          sbctl log purge --yes
          sbctl log simulate --db <file> [--days 7] [--scenario quiet]     fill a test log with simulated traffic
          sbctl log bench --db <file>                                      time a set of queries

        Every form takes --db <file>; the default is the app's own log. --since takes 15m, 1h, 24h, 7d, or all.
        """

    static func run(_ arguments: [String]) throws -> Int32 {
        guard let verb = arguments.first else {
            print(usage)
            return 2
        }
        let rest = Array(arguments.dropFirst())
        let options = Options(arguments: rest)
        let url = options.value("--db").map { URL(fileURLWithPath: $0) } ?? LogStore.defaultURL()
        let now = Date().timeIntervalSince1970

        func since() -> Double {
            guard let text = options.value("--since"), text != "all" else { return options.value("--since") == "all" ? 0 : now - 3600 }
            let units: [Character: Double] = ["m": 60, "h": 3600, "d": 86_400]
            guard let unit = text.last, let scale = units[unit], let count = Double(text.dropLast()) else { return now - 3600 }
            return now - count * scale
        }

        switch verb {
        case "stats":
            let stats = try LogStore(url: url).stats()
            print("log: \(url.path)")
            print("connections: \(stats.flows)   destinations ever seen: \(stats.endpoints)   size: \(ByteFormat.bytes(Double(stats.bytesOnDisk)))")
            if let oldest = stats.oldest, let newest = stats.newest {
                print("from \(Date(timeIntervalSince1970: oldest).formatted()) to \(Date(timeIntervalSince1970: newest).formatted())")
            }
            return 0

        case "query":
            let filter = try FlowFilter(rest.first { !$0.hasPrefix("--") } ?? "")
            let limit = Int(options.number("--limit", default: 20))
            let result = try LogStore(url: url).query(filter, from: since(), to: now + 1, limit: limit)
            for entry in result.entries {
                let flow = entry.flow
                let ended = flow.closedAt == nil ? "open" : ByteFormat.duration(flow.age(at: now))
                let remote = flow.hostname.map { "\($0):\(flow.key.remote.port)" } ?? flow.key.remote.description
                print(
                    "\(Date(timeIntervalSince1970: flow.firstSeen).formatted(date: .abbreviated, time: .standard))  \(entry.process.name) (\(flow.pid))  \(flow.key.proto.rawValue) \(remote)  \(flow.service ?? "-")  \(ended)  ↓\(ByteFormat.bytes(Double(flow.bytesIn))) ↑\(ByteFormat.bytes(Double(flow.bytesOut)))"
                )
            }
            print(String(format: "%d matched (%d shown), %d rows examined, %.1f ms", result.matched, result.entries.count, result.scanned, result.milliseconds))
            return 0

        case "export":
            guard let path = rest.first(where: { !$0.hasPrefix("--") }) else {
                print(usage)
                return 2
            }
            let format = options.value("--format").flatMap(ExportFormat.init(rawValue:)) ?? (path.hasSuffix(".jsonl") ? .jsonl : .csv)
            let filter = try FlowFilter(options.value("--filter") ?? "")
            let written = try LogStore(url: url).export(
                filter, from: since(), to: now + 1, format: format, redactHostnames: options.has("--redact"),
                to: URL(fileURLWithPath: path))
            print("wrote \(written) connections to \(path) as \(format.rawValue)\(options.has("--redact") ? ", hostnames removed" : "")")
            return 0

        case "prune":
            let days = options.number("--days", default: 30), megabytes = options.number("--megabytes", default: 2000)
            let removed = try LogStore(url: url).prune(maximumAge: days * 86_400, maximumBytes: Int(megabytes * 1_000_000))
            print("removed \(removed) connections older than \(Int(days)) days or beyond \(Int(megabytes)) MB")
            return 0

        case "purge":
            guard options.has("--yes") else {
                print("This erases the whole log at \(url.path). Run again with --yes to do it.")
                return 2
            }
            try LogStore(url: url).purge()
            print("log erased")
            return 0

        case "simulate":
            guard options.value("--db") != nil else {
                print("simulate writes invented traffic, so it needs --db <file>; it will not touch the app's log")
                return 2
            }
            return try simulate(
                url: url, days: options.number("--days", default: 7),
                scenario: options.value("--scenario").flatMap(SimulatorSource.Scenario.init(rawValue:)) ?? .quiet)

        case "bench":
            return try bench(LogStore(url: url))

        default:
            print(usage)
            return 2
        }
    }

    /// Fills a log by running the simulator on a fast clock, recording once a simulated second.
    private static func simulate(url: URL, days: Double, scenario: SimulatorSource.Scenario) throws -> Int32 {
        let store = try LogStore(url: url)
        let engine = FlowEngine()
        let seconds = days * 86_400
        engine.wallClockOrigin = Date().timeIntervalSince1970 - seconds
        let started = Date()
        var lastReport = 0.0
        SteppedRun.run(sources: [SimulatorSource(scenario: scenario)], engine: engine, until: seconds, step: 1) { time in
            store.record(engine.snapshot())
            if time - lastReport >= 86_400 {
                lastReport = time
                store.flush()
                print("  day \(Int(time / 86_400)) of \(Int(days))")
            }
        }
        store.flush()
        let stats = try store.stats()
        print(String(
            format: "simulated %.0f days of '%@' in %.0f s: %d connections, %@ on disk",
            days, scenario.rawValue, Date().timeIntervalSince(started), stats.flows, ByteFormat.bytes(Double(stats.bytesOnDisk))))
        return 0
    }

    private static func bench(_ store: LogStore) throws -> Int32 {
        let stats = try store.stats()
        guard let oldest = stats.oldest, let newest = stats.newest else {
            print("the log is empty")
            return 1
        }
        print("\(stats.flows) connections over \(ByteFormat.duration(newest - oldest)), \(ByteFormat.bytes(Double(stats.bytesOnDisk)))")
        print("query                                              range     matched   examined       ms")
        // A destination that really is in the log, for the "everything to this address" question.
        let sample = try store.query(.all, from: newest - 3600, to: newest + 1, limit: 1).entries.first
        let address = sample?.flow.key.remote.address.description ?? "1.1.1.1"
        let queries: [(String, Double)] = [
            ("remote=\(address)", 7 * 86_400), ("process:Safari", 7 * 86_400), ("host:*.example.com", 7 * 86_400),
            ("r_port:993", 7 * 86_400), ("bytes>10MB", 7 * 86_400), ("process:Mail bytes>1MB", 7 * 86_400),
            ("", 3600), ("", 86_400), ("age>1h", 86_400), ("remote:13.0.0.0/8", 86_400), ("", 7 * 86_400),
        ]
        var worst = 0.0
        for (text, span) in queries {
            let result = try store.query(try FlowFilter(text), from: newest - span, to: newest + 1, limit: 1000, now: newest)
            worst = max(worst, result.milliseconds)
            print(String(
                format: "%@ %@ %9d %10d %8.1f", (text.isEmpty ? "(everything)" : text).padding(toLength: 50, withPad: " ", startingAt: 0),
                ByteFormat.duration(span).padding(toLength: 6, withPad: " ", startingAt: 0), result.matched, result.scanned, result.milliseconds))
        }
        print(String(format: "slowest: %.1f ms", worst))
        return 0
    }
}
