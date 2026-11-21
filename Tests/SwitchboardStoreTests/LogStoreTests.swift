import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardStore

/// A log in a temporary file, filled from the simulator on a fixed clock.
final class Fixture {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sb-log-\(UUID().uuidString).sqlite")
    let origin = 1_800_000_000.0
    var store: LogStore
    let engine = FlowEngine()
    /// Every connection the engine ever opened, as it last looked.
    var everSeen: [FlowID: Flow] = [:]

    init(detail: LogDetail = .standard) throws {
        store = try LogStore(url: url, detail: detail)
        engine.wallClockOrigin = origin
    }

    deinit {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
    }

    /// Runs a scenario, recording once a simulated second as the app does.
    func run(_ scenario: SimulatorSource.Scenario = .developer, seconds: Double) {
        let source = SimulatorSource(scenario: scenario)
        SteppedRun.run(sources: [source], engine: engine, until: seconds) { [self] time in
            for flow in engine.flows.values { everSeen[flow.id] = flow }
            if time == time.rounded() { store.record(engine.snapshot()) }
        }
        store.flush()
    }

    func reopen() throws {
        store.flush()
        store = try LogStore(url: url)
    }

    var all: (from: Double, to: Double) { (0, origin + 1_000_000) }
}

@Suite struct LogRecordingTests {
    @Test func writesEachConnectionOnceWithItsFinalTotals() throws {
        let fixture = try Fixture()
        fixture.run(seconds: 60)
        let stats = try fixture.store.stats()
        #expect(stats.flows == fixture.everSeen.count)
        #expect(stats.flows > 400)

        let result = try fixture.store.query(.all, from: fixture.all.from, to: fixture.all.to, limit: 100_000)
        #expect(result.matched == stats.flows)
        // Every connection the engine saw close is closed in the log, with the same totals.
        let closed = fixture.everSeen.values.filter { $0.state == .closed }
        let logged = Dictionary(grouping: result.entries) { "\($0.flow.pid) \($0.flow.key.local) \($0.flow.key.remote)" }
        #expect(closed.count > 200)
        for flow in closed {
            let entry = try #require(logged["\(flow.pid) \(flow.key.local) \(flow.key.remote)"]?.first)
            #expect(entry.flow.closedAt != nil)
            #expect(entry.flow.bytesIn == flow.bytesIn)
            #expect(entry.flow.bytesOut == flow.bytesOut)
            #expect(entry.flow.hostname == flow.hostname)
            #expect(entry.flow.service == flow.service)
            #expect(abs(entry.flow.firstSeen - (fixture.origin + flow.firstSeen)) < 0.001)
        }
        #expect(result.entries.allSatisfy { !$0.process.name.isEmpty })
    }

    @Test func closesWhatAPreviousSessionLeftOpen() throws {
        let fixture = try Fixture()
        fixture.run(seconds: 20)
        let before = try fixture.store.query(try FlowFilter("state:active"), from: fixture.all.from, to: fixture.all.to, limit: 100_000)
        #expect(before.matched > 50)
        try fixture.reopen()
        let after = try fixture.store.query(try FlowFilter("state:active"), from: fixture.all.from, to: fixture.all.to, limit: 100_000)
        #expect(after.matched == 0)
        #expect(try fixture.store.stats().flows == fixture.everSeen.count)
    }

    @Test func doesNotDuplicateWhenTheEngineStartsAgain() throws {
        // Switching between Standalone and Full restarts the engine: the same sockets
        // come back with new ids. The log must recognise them.
        let fixture = try Fixture()
        fixture.run(.quiet, seconds: 10)
        let before = try fixture.store.stats().flows
        let open = fixture.engine.flows.values.filter { $0.state != .closed }

        let restarted = FlowEngine()
        restarted.wallClockOrigin = fixture.origin
        let events = open.enumerated().map { offset, flow in
            SourceEvent.seen(SocketObservation(
                sourceID: UInt64(9000 + offset), proto: flow.key.proto, local: flow.key.local, remote: flow.key.remote,
                pid: flow.pid, processName: "x", rxBytes: flow.bytesIn, txBytes: flow.bytesOut))
        }
        restarted.ingest(events, from: "other", at: 11)
        fixture.store.record(restarted.snapshot())
        fixture.store.flush()
        #expect(try fixture.store.stats().flows == before)
    }

    @Test func recordsAConnectionThatCameAndWentBetweenRecordings() throws {
        let fixture = try Fixture()
        fixture.engine.ingest([.seen(SocketObservation(
            sourceID: 1, proto: .tcp, local: Endpoint(address: IPAddress("10.0.0.2")!, port: 50_000),
            remote: Endpoint(address: IPAddress("1.1.1.1")!, port: 443), pid: 7, processName: "blink", rxBytes: 900, txBytes: 100))],
            from: "test", at: 0.2)
        fixture.engine.ingest([.removed(sourceID: 1)], from: "test", at: 0.4)
        // Recorded several times while the engine still remembers it: written once.
        for second in 1...5 {
            fixture.engine.ingest([], from: "test", at: Double(second))
            fixture.store.record(fixture.engine.snapshot())
        }
        fixture.store.flush()
        let result = try fixture.store.query(.all, from: fixture.all.from, to: fixture.all.to)
        #expect(result.matched == 1)
        #expect(result.entries.first?.flow.bytesIn == 900)
        #expect(result.entries.first?.flow.closedAt == fixture.origin + 0.4)
    }

    @Test func recordsDNSAndListenersOnlyAtStandardDetailAndAbove() throws {
        func counts(_ detail: LogDetail) throws -> (dns: Int64, listeners: Int64, samples: Int64) {
            let fixture = try Fixture(detail: detail)
            fixture.run(seconds: 30)
            let database = try Database(path: fixture.url.path)
            return (
                try database.scalar("SELECT COUNT(*) FROM dns_obs"), try database.scalar("SELECT COUNT(*) FROM listener_event"),
                try database.scalar("SELECT COUNT(*) FROM flow_sample"))
        }
        let summary = try counts(.summary), standard = try counts(.standard), detailed = try counts(.detailed)
        #expect(summary.dns == 0 && summary.samples == 0)
        #expect(standard.dns > 20 && standard.samples == 0)
        #expect(detailed.dns == standard.dns && detailed.samples > 500)
        // The listeners already there at the start are not events.
        #expect(standard.listeners == 0)
    }
}

@Suite struct LogQueryTests {
    /// The same connections, selected by evaluating the filter directly on everything in the log.
    static func reference(_ fixture: Fixture, _ filter: FlowFilter, now: Double) throws -> Set<FlowID> {
        let everything = try fixture.store.query(.all, from: fixture.all.from, to: fixture.all.to, limit: 1_000_000, now: now)
        return Set(everything.entries.filter { filter.matches($0.flow, process: $0.process, now: now) }.map(\.id))
    }

    @Test func returnsExactlyWhatTheFilterWouldSelectInMemory() throws {
        let fixture = try Fixture()
        fixture.run(seconds: 90)
        let now = fixture.origin + 90
        let corpus = [
            "process:brave", "process=\"Slack Helper\"", "process!=node", "process:*helper*", "NOT process:*helper*",
            "r_port:443", "port:443 proto:udp", "r_port!=443", "pid>=2500", "pid=2010 OR pid=2144",
            "bytes>1MB", "bytes_in<10KB bytes_out<10KB", "service:quic", "service=https NOT process:brave",
            "host:*.example.com", "host:api", "NOT host:*.example.org", "remote:13.0.0.0/8", "remote:2600::/16",
            "NOT remote:13.0.0.0/8", "remote!=10.0.0.1", "age>30s", "age<5s OR bytes>5MB", "rate>100KB/s",
            "state:closed", "state:active process:docker", "direction:outbound", "docker", "443",
            "(process:brave OR process:safari) r_port:443 NOT service:quic", "NOT (process:brave OR r_port:80)",
            "NOT (age>10s AND process:brave)", "process:brave OR age>60s", "iface:en0 user:nobody",
        ]
        var narrowed = 0
        for text in corpus {
            let filter = try FlowFilter(text)
            let result = try fixture.store.query(filter, from: fixture.all.from, to: fixture.all.to, limit: 1_000_000, now: now)
            let expected = try Self.reference(fixture, filter, now: now)
            #expect(Set(result.entries.map(\.id)) == expected, "\(text)")
            #expect(result.matched == expected.count, "\(text)")
            #expect(result.histogram.reduce(0, +) == result.matched, "\(text)")
            if result.scanned < (try fixture.store.stats().flows) { narrowed += 1 }
            // The count-in-SQL path and the row-by-row path must agree on what is newest.
            #expect(result.entries.map(\.flow.firstSeen) == result.entries.map(\.flow.firstSeen).sorted(by: >), "\(text)")
        }
        // SQL must actually be doing some of the narrowing, or the index is no use.
        #expect(narrowed > corpus.count / 2)
    }

    @Test func agreesOnRandomExpressionsToo() throws {
        let fixture = try Fixture()
        fixture.run(seconds: 40)
        let now = fixture.origin + 40
        let terms = [
            "process:helper", "proto:tcp", "r_port:443", "bytes>200KB", "pid>=2500", "service!=HTTPS", "host:*.example.net",
            "age>10s", "remote:13.0.0.0/8", "state:closed", "docker", "l_port<52000",
        ]
        var random = SplitMix64(seed: 0x5E1EC7)
        func expression(_ depth: Int) -> String {
            if depth == 0 || random.below(4) == 0 { return terms[random.below(terms.count)] }
            switch random.below(3) {
            case 0: return "(\(expression(depth - 1)) AND \(expression(depth - 1)))"
            case 1: return "(\(expression(depth - 1)) OR \(expression(depth - 1)))"
            default: return "NOT (\(expression(depth - 1)))"
            }
        }
        for _ in 0..<150 {
            let filter = try FlowFilter(expression(4))
            let result = try fixture.store.query(filter, from: fixture.all.from, to: fixture.all.to, limit: 1_000_000, now: now)
            #expect(Set(result.entries.map(\.id)) == (try Self.reference(fixture, filter, now: now)), "\(filter.text)")
        }
    }

    @Test func limitsToTheNewestAndTheTimeRange() throws {
        let fixture = try Fixture()
        fixture.run(seconds: 60)
        let limited = try fixture.store.query(.all, from: fixture.all.from, to: fixture.all.to, limit: 10)
        #expect(limited.entries.count == 10)
        #expect(limited.matched > 400)
        #expect(limited.entries.map(\.flow.firstSeen) == limited.entries.map(\.flow.firstSeen).sorted(by: >))

        // Only connections alive at some point in the window.
        let from = fixture.origin + 20, to = fixture.origin + 25
        let window = try fixture.store.query(.all, from: from, to: to, limit: 1_000_000)
        #expect(window.matched > 0 && window.matched < limited.matched)
        #expect(window.entries.allSatisfy { $0.flow.firstSeen <= to && ($0.flow.closedAt ?? $0.flow.lastSeen) >= from })
    }

    @Test func rebuildsAMomentFromTheLog() throws {
        let fixture = try Fixture()
        var openAtThirty = Set<FlowKey>()
        let source = SimulatorSource(scenario: .developer)
        SteppedRun.run(sources: [source], engine: fixture.engine, until: 60) { time in
            if time == time.rounded() { fixture.store.record(fixture.engine.snapshot()) }
            if time == 30 { openAtThirty = Set(fixture.engine.flows.values.filter { $0.state != .closed }.map(\.key)) }
        }
        fixture.store.flush()
        let moment = try fixture.store.snapshot(at: fixture.origin + 30)
        let rebuilt = Set(moment.flows.filter { $0.state != .closed }.map(\.key))
        // Recording is once a second, so a connection that closed within the second
        // either side of the moment may differ; everything else must agree.
        #expect(rebuilt.symmetricDifference(openAtThirty).count <= openAtThirty.count / 10)
        #expect(rebuilt.intersection(openAtThirty).count >= openAtThirty.count * 9 / 10)
        #expect(!moment.processes.isEmpty)
        #expect(moment.time == fixture.origin + 30)
    }
}

@Suite struct LogMaintenanceTests {
    @Test func exportsCSVThatReadsBack() throws {
        let fixture = try Fixture()
        fixture.run(seconds: 30)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("sb-export-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: out) }
        let filter = try FlowFilter("process:brave")
        let written = try fixture.store.export(filter, from: fixture.all.from, to: fixture.all.to, format: .csv, redactHostnames: false, to: out)
        let lines = try String(contentsOf: out, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == written + 1)
        #expect(lines[0] == Substring(LogStore.exportColumns.joined(separator: ",")))
        #expect(written == (try fixture.store.query(filter, from: fixture.all.from, to: fixture.all.to).matched))
        #expect(lines.dropFirst().allSatisfy { $0.split(separator: ",", omittingEmptySubsequences: false).count == LogStore.exportColumns.count })
        #expect(lines.dropFirst().allSatisfy { $0.contains("Brave Browser Helper") && $0.contains(".example") })

        let redacted = try fixture.store.export(filter, from: fixture.all.from, to: fixture.all.to, format: .csv, redactHostnames: true, to: out)
        #expect(redacted == written)
        #expect(!(try String(contentsOf: out, encoding: .utf8)).contains(".example"))
    }

    @Test func exportsJSONLinesThatParse() throws {
        let fixture = try Fixture()
        fixture.run(seconds: 20)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("sb-export-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: out) }
        let written = try fixture.store.export(.all, from: fixture.all.from, to: fixture.all.to, format: .jsonl, redactHostnames: false, to: out)
        let lines = try String(contentsOf: out, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == written)
        for line in lines.prefix(50) {
            let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            #expect(object["process"] is String)
            #expect(object["remote_port"] is Int)
            #expect(object["bytes_in"] is Int)
        }
    }

    @Test func quotesAndDefusesCSVFields() {
        #expect(LogStore.csvField("plain") == "plain")
        #expect(LogStore.csvField("a,b") == "\"a,b\"")
        #expect(LogStore.csvField("say \"hi\"") == "\"say \"\"hi\"\"\"")
        // A process name must not be able to run as a spreadsheet formula.
        #expect(LogStore.csvField("=HYPERLINK(\"x\")") == "\"'=HYPERLINK(\"\"x\"\")\"")
        #expect(LogStore.csvField("-1") == "'-1")
        #expect(LogStore.csvField("") == "")
    }

    @Test func forgetsByAge() throws {
        let fixture = try Fixture()
        fixture.run(seconds: 60)
        let before = try fixture.store.stats().flows
        // Keep only what ended in the last 20 simulated seconds.
        let removed = try fixture.store.prune(maximumAge: 20, maximumBytes: .max, now: fixture.origin + 60)
        let after = try fixture.store.stats()
        #expect(removed > 0)
        #expect(after.flows == before - removed)
        let remaining = try fixture.store.query(.all, from: fixture.all.from, to: fixture.all.to, limit: 1_000_000)
        #expect(remaining.entries.allSatisfy { ($0.flow.closedAt ?? .infinity) >= fixture.origin + 40 })
    }

    @Test func shrinksToASizeLimit() throws {
        let fixture = try Fixture()
        fixture.run(seconds: 120)
        try fixture.reopen()  // everything closed, so everything is eligible
        let before = try fixture.store.stats()
        let limit = before.bytesOnDisk / 3
        try fixture.store.prune(maximumAge: .infinity, maximumBytes: limit, now: fixture.origin + 120)
        let after = try fixture.store.stats()
        #expect(after.bytesOnDisk <= limit)
        #expect(after.flows < before.flows && after.flows > 0)
        // The oldest went first.
        #expect((after.oldest ?? 0) > (before.oldest ?? 0))
    }

    @Test func purgesEverything() throws {
        let fixture = try Fixture()
        fixture.run(seconds: 30)
        let before = try fixture.store.stats()
        try fixture.store.purge()
        let after = try fixture.store.stats()
        #expect(after.flows == 0 && after.endpoints == 0 && after.oldest == nil)
        #expect(after.bytesOnDisk < before.bytesOnDisk)
        // And it carries on recording afterwards.
        fixture.run(.quiet, seconds: 5)
        #expect(try fixture.store.stats().flows > 0)
    }

    @Test func remarksOnNewDestinationsOnlyOnceItKnowsTheMachine() throws {
        final class Seen: @unchecked Sendable {
            let lock = NSLock()
            var addresses: [IPAddress] = []
        }
        let fixture = try Fixture()
        let first = Seen()
        fixture.store.onFirstSeen = { new in first.lock.withLock { first.addresses += new } }
        fixture.run(seconds: 60)
        // A brand-new log has no idea what is normal, so it says nothing.
        #expect(first.addresses.isEmpty)
        let known = try fixture.store.stats().endpoints
        #expect(known > 50)
        #expect(try fixture.store.recentFirstSeen(limit: 5).count == 5)

        // Next session: an address never seen before is remarked on; a familiar one is not.
        try fixture.reopen()
        fixture.store.firstSeenBaseline = 50
        let second = Seen()
        fixture.store.onFirstSeen = { new in second.lock.withLock { second.addresses += new } }
        let familiar = try #require(fixture.everSeen.values.first { !$0.key.remote.address.isLoopback })
        let engine = FlowEngine()
        engine.wallClockOrigin = fixture.origin
        func open(_ id: UInt64, _ remote: IPAddress) -> SourceEvent {
            .seen(SocketObservation(
                sourceID: id, proto: .tcp, local: Endpoint(address: IPAddress("10.0.0.2")!, port: UInt16(40_000 + id)),
                remote: Endpoint(address: remote, port: 443), pid: 1, processName: "app"))
        }
        engine.ingest([open(1, familiar.key.remote.address), open(2, IPAddress("203.0.113.77")!)], from: "test", at: 100)
        fixture.store.record(engine.snapshot())
        fixture.store.flush()
        #expect(second.addresses == [IPAddress("203.0.113.77")!])
        #expect(try fixture.store.firstSeen([IPAddress("203.0.113.77")!]).count == 1)
        #expect(try fixture.store.stats().endpoints == known + 1)
    }
}

@Suite struct NonASCIITests {
    @Test func textThatIsNotASCIIIsStillMatchedTheWayTheFilterMatches() throws {
        // SQLite's LIKE folds case for ASCII only. A row with other text must send the
        // query down the path that checks each row with the real filter.
        let fixture = try Fixture()
        fixture.run(.quiet, seconds: 10)
        let engine = FlowEngine(resolver: Renamer())
        engine.wallClockOrigin = fixture.origin
        engine.ingest([.seen(SocketObservation(
            sourceID: 1, proto: .tcp, local: Endpoint(address: IPAddress("10.0.0.2")!, port: 50_000),
            remote: Endpoint(address: IPAddress("1.1.1.1")!, port: 443), pid: 77, processName: "x"))], from: "test", at: 11)
        fixture.store.record(engine.snapshot())
        fixture.store.flush()

        for text in ["process:ÉDITEUR", "process:éditeur", "process=\"Éditeur de Texte\"", "NOT process:safari", "r_port:443"] {
            let filter = try FlowFilter(text)
            let result = try fixture.store.query(filter, from: fixture.all.from, to: fixture.all.to, limit: 100_000, now: fixture.origin + 12)
            #expect(Set(result.entries.map(\.id)) == (try LogQueryTests.reference(fixture, filter, now: fixture.origin + 12)), "\(text)")
        }
        let found = try fixture.store.query(try FlowFilter("process:éditeur"), from: fixture.all.from, to: fixture.all.to)
        #expect(found.matched == 1)
    }

    struct Renamer: ProcessResolver {
        func resolve(pid: Int32, name: String, uniqueID: UInt64?) -> ProcessRecord {
            ProcessRecord(pid: pid, name: "Éditeur de Texte")
        }
    }
}

@Suite struct SQLPrefilterTests {
    @Test func compilesWhatSQLCanExpressAndLeavesTheRest() throws {
        func clause(_ text: String) throws -> String? { try FlowFilter(text).sqlPrefilter()?.clause }
        #expect(try clause("") == nil)
        #expect(try clause("r_port:443") == "r_port = ?")
        #expect(try clause("r_port:443 pid>10") == "(r_port = ? AND pid > ?)")
        // A term SQL cannot express is dropped from an AND…
        #expect(try clause("r_port:443 age>1h") == "r_port = ?")
        // …but poisons an OR, which would otherwise lose its matches…
        #expect(try clause("r_port:443 OR age>1h") == nil)
        // …and a NOT over anything that admits too much.
        #expect(try clause("NOT (r_port:443 age>1h)") == nil)
        #expect(try clause("NOT r_port:443") == "(NOT r_port = ?)")
        #expect(try clause("remote:10.0.0.0/8") == nil)
        #expect(try clause("remote:10.0.0.1") == "r_ip = ?")
        #expect(try clause("state:closed") == nil)
        #expect(try clause("port!=443") == "(r_port != ? AND l_port != ?)")
    }

    @Test func escapesWildcardsAndBindsValues() throws {
        let prefilter = try #require(try FlowFilter("process:50%_off").sqlPrefilter())
        #expect(prefilter.bindings == [.text("%50\\%\\_off%")])
        let glob = try #require(try FlowFilter("host=*.example.com").sqlPrefilter())
        #expect(glob.bindings == [.text("%.example.com")])
        // Text that is not plain ASCII is left to the in-memory pass, where case rules match.
        #expect(try FlowFilter("process:Café").sqlPrefilter() == nil)
    }
}
