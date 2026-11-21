import Foundation
import Testing

@testable import SwitchboardCore

private func endpoint(_ text: String, _ port: UInt16) -> Endpoint {
    Endpoint(address: IPAddress(text)!, port: port)
}

private func tcp(
    _ id: UInt64, pid: Int32 = 100, localPort: UInt16 = 50_000, remote: String = "93.184.216.34",
    remotePort: UInt16 = 443, rx: UInt64 = 0, tx: UInt64 = 0, state: TCPState = .established, age: Double? = nil
) -> SourceEvent {
    .seen(SocketObservation(
        sourceID: id, proto: .tcp, local: endpoint("10.0.0.36", localPort), remote: endpoint(remote, remotePort),
        pid: pid, processName: "app", rxBytes: rx, txBytes: tx, tcpState: state, ageSeconds: age))
}

private func listener(_ id: UInt64, pid: Int32 = 100, address: String = "0.0.0.0", port: UInt16) -> SourceEvent {
    .seen(SocketObservation(
        sourceID: id, proto: .tcp, local: endpoint(address, port), remote: endpoint("0.0.0.0", 0),
        pid: pid, processName: "app", tcpState: .listen))
}

@Suite struct RateEstimatorTests {
    @Test func convergesOnASteadyRate() {
        var meter = RateEstimator()
        var count: UInt64 = 0
        for step in 0...40 {
            meter.update(count: count, at: Double(step) * 0.25, halfLife: 1)
            count += 25_000  // 100 KB/s
        }
        #expect(abs(meter.rate - 100_000) < 500)
    }

    @Test func isIndependentOfSamplingInterval() {
        // The same traffic sampled evenly and unevenly should read the same.
        var even = RateEstimator(), uneven = RateEstimator()
        let rate = 80_000.0
        for step in 0...80 { even.update(count: UInt64(rate * Double(step) * 0.1), at: Double(step) * 0.1, halfLife: 1) }
        var time = 0.0
        for step in 0..<60 {
            uneven.update(count: UInt64(rate * time), at: time, halfLife: 1)
            time += step.isMultiple(of: 3) ? 0.31 : 0.07
        }
        #expect(abs(even.rate - rate) < rate * 0.01)
        #expect(abs(uneven.rate - rate) < rate * 0.01)
    }

    @Test func halvesInOneHalfLifeOfSilence() {
        var meter = RateEstimator()
        meter.update(count: 0, at: 0, halfLife: 2)
        for step in 1...200 { meter.update(count: UInt64(step) * 5_000, at: Double(step) * 0.1, halfLife: 2) }
        let before = meter.rate
        meter.update(count: 1_000_000, at: 22, halfLife: 2)  // no new bytes for 2 s
        #expect(abs(meter.rate - before / 2) < before * 0.02)
    }

    @Test func reportsACounterThatGoesBackwards() {
        var meter = RateEstimator()
        #expect(meter.update(count: 500, at: 0, halfLife: 1) == .primed)
        #expect(meter.update(count: 900, at: 1, halfLife: 1) == .advanced(400))
        #expect(meter.update(count: 100, at: 2, halfLife: 1) == .reset)
        #expect(meter.rate == 0)
    }

    @Test func ignoresTwoSamplesAtTheSameInstant() {
        var meter = RateEstimator()
        meter.update(count: 0, at: 1, halfLife: 1)
        #expect(meter.update(count: 10_000, at: 1, halfLife: 1) == .advanced(0))
        #expect(meter.rate == 0)
    }
}

@Suite struct FlowEngineTests {
    @Test func walksAFlowThroughItsLifecycle() {
        let engine = FlowEngine()
        var delta = engine.ingest([tcp(1)], from: "test", at: 10)
        let id = try! #require(delta.opened.first)
        #expect(engine.flows[id]?.state == .new)

        delta = engine.ingest([tcp(1, rx: 4000, tx: 500)], from: "test", at: 10.25)
        #expect(engine.flows[id]?.state == .active)
        #expect(delta.updated == [id])
        #expect(engine.flows[id]?.bytesIn == 4000)
        #expect((engine.flows[id]?.rateIn ?? 0) > 0)

        // Quiet for longer than the idle threshold.
        engine.ingest([tcp(1, rx: 4000, tx: 500)], from: "test", at: 16)
        #expect(engine.flows[id]?.state == .idle)

        // Traffic resumes.
        engine.ingest([tcp(1, rx: 9000, tx: 500)], from: "test", at: 16.25)
        #expect(engine.flows[id]?.state == .active)

        engine.ingest([tcp(1, rx: 9000, tx: 500, state: .finWait1)], from: "test", at: 16.5)
        #expect(engine.flows[id]?.state == .closing)

        delta = engine.ingest([.removed(sourceID: 1)], from: "test", at: 17)
        #expect(delta.closed == [id])
        #expect(engine.flows[id]?.state == .closed)
        #expect(engine.flows[id]?.closedAt == 17)
        #expect(engine.flows[id]?.rateIn == 0)

        // Still present during the fade window, gone after it.
        #expect(engine.ingest([], from: "test", at: 40).purged.isEmpty)
        #expect(engine.ingest([], from: "test", at: 48).purged == [id])
        #expect(engine.flows[id] == nil)
        #expect(engine.processes.isEmpty)
    }

    @Test func treatsACounterResetAsANewFlow() {
        let engine = FlowEngine()
        let first = engine.ingest([tcp(1, rx: 5000)], from: "test", at: 0).opened[0]
        let delta = engine.ingest([tcp(1, rx: 100)], from: "test", at: 1)
        #expect(delta.closed == [first])
        #expect(delta.opened.count == 1)
        #expect(delta.opened[0] != first)
        #expect(engine.flows[delta.opened[0]]?.bytesIn == 100)
    }

    @Test func treatsAChangedPeerAsANewFlow() {
        let engine = FlowEngine()
        let first = engine.ingest([tcp(1, remotePort: 443)], from: "test", at: 0).opened[0]
        let delta = engine.ingest([tcp(1, remotePort: 8443)], from: "test", at: 1)
        #expect(delta.closed == [first])
        #expect(delta.opened.count == 1)
    }

    @Test func separatesListenersFromFlowsAndMarksExposure() {
        let engine = FlowEngine()
        let delta = engine.ingest(
            [listener(1, port: 8080), listener(2, address: "127.0.0.1", port: 5432)], from: "test", at: 0)
        #expect(delta.opened.isEmpty)
        #expect(delta.listenersChanged)
        #expect(engine.flows.isEmpty)
        let exposed = engine.listeners.values.filter(\.exposed).map(\.local.port)
        #expect(exposed == [8080])

        #expect(engine.ingest([.removed(sourceID: 1)], from: "test", at: 1).listenersChanged)
        #expect(engine.listeners.count == 1)
    }

    @Test func marksConnectionsToOurOwnListenersAsInbound() {
        let engine = FlowEngine()
        engine.ingest([listener(1, pid: 7, port: 8080)], from: "test", at: 0)
        let delta = engine.ingest(
            [tcp(2, pid: 7, localPort: 8080, remotePort: 51_000), tcp(3, pid: 7, localPort: 50_001)], from: "test", at: 1)
        let directions = delta.opened.map { engine.flows[$0]!.direction }
        #expect(directions == [.inbound, .outbound])
    }

    @Test func ignoresTCPSocketsThatAreNeitherListeningNorConnected() {
        let engine = FlowEngine()
        let unconnected = SourceEvent.seen(SocketObservation(
            sourceID: 1, proto: .tcp, local: endpoint("0.0.0.0", 0), remote: endpoint("0.0.0.0", 0),
            pid: 1, processName: "app", tcpState: .closed))
        let delta = engine.ingest([unconnected], from: "test", at: 0)
        #expect(delta.isEmpty)
        // …until it connects.
        #expect(engine.ingest([tcp(1, pid: 1)], from: "test", at: 1).opened.count == 1)
    }

    @Test func knowsWhenAnAgeIsOnlyALowerBound() {
        let engine = FlowEngine()
        // Present at startup, no age from the source: approximate.
        let early = engine.ingest([tcp(1)], from: "test", at: 0).opened[0]
        #expect(engine.flows[early]?.ageExact == false)
        // Appears well after startup: we watched it open.
        let late = engine.ingest([tcp(2, localPort: 50_001)], from: "test", at: 60).opened[0]
        #expect(engine.flows[late]?.ageExact == true)
        // The source knows the true age.
        let aged = engine.ingest([tcp(3, localPort: 50_002, age: 7200)], from: "test", at: 61).opened[0]
        #expect(engine.flows[aged]?.ageExact == true)
        #expect(engine.flows[aged]?.age(at: 61) == 7200)
        #expect(engine.flows[aged]?.state == .new)
        // A long-standing connection is idle until its counters move.
        engine.ingest([tcp(3, localPort: 50_002, age: 7200.25)], from: "test", at: 61.25)
        #expect(engine.flows[aged]?.state == .idle)
        // The source learns the first flow's age late; the engine takes the correction.
        engine.ingest([tcp(1, age: 500)], from: "test", at: 62)
        #expect(engine.flows[early]?.ageExact == true)
        #expect(engine.flows[early]?.age(at: 62) == 500)
    }

    @Test func letsTheFirstSourceOwnAFlowTwoSourcesReport() {
        let engine = FlowEngine()
        let owned = engine.ingest([tcp(1, rx: 100)], from: "primary", at: 0).opened[0]
        #expect(engine.ingest([tcp(900, rx: 90)], from: "secondary", at: 0).opened.isEmpty)
        // The second source can add what the first does not have.
        #expect(engine.ingest([tcp(901, localPort: 50_009)], from: "secondary", at: 0).opened.count == 1)
        // Its copy of the shared flow going away changes nothing.
        #expect(engine.ingest([.removed(sourceID: 900)], from: "secondary", at: 1).closed.isEmpty)
        #expect(engine.flows[owned]?.attribution == "primary")
        #expect(engine.flows[owned]?.state != .closed)
    }

    @Test func labelsServicesWithTheirBasis() {
        let engine = FlowEngine()
        let https = engine.ingest([tcp(1)], from: "test", at: 0).opened[0]
        #expect(engine.flows[https]?.service == "HTTPS")
        #expect(engine.flows[https]?.serviceBasis == .port)

        var observation = SocketObservation(
            sourceID: 2, proto: .udp, local: endpoint("10.0.0.36", 50_100), remote: endpoint("142.250.1.1", 443),
            pid: 1, processName: "app")
        #expect(ServiceTable.service(for: FlowKey(proto: .udp, local: observation.local, remote: observation.remote)) == "QUIC")
        observation.serviceHint = "QUIC"
        let quic = engine.ingest([.seen(observation)], from: "test", at: 0).opened[0]
        #expect(engine.flows[quic]?.serviceBasis == .heuristic)
        #expect(ServiceTable.service(proto: .tcp, port: 61_234) == nil)
    }
}

@Suite struct SimulatorAndTraceTests {
    private func run(
        _ scenario: SimulatorSource.Scenario, seconds: Double, configuration: EngineConfiguration = EngineConfiguration()
    ) -> (engine: FlowEngine, records: [TraceFile.Record]) {
        let source = SimulatorSource(scenario: scenario)
        let engine = FlowEngine(configuration: configuration)
        var records: [TraceFile.Record] = []
        var time = 0.0
        while time <= seconds {
            let events = source.poll(now: time)
            records.append(TraceFile.Record(t: time, source: source.name, events: events))
            engine.ingest(events, from: source.name, at: time)
            time += 0.25
        }
        return (engine, records)
    }

    @Test func isDeterministic() {
        let first = run(.developer, seconds: 20), second = run(.developer, seconds: 20)
        #expect(first.records.map(\.events) == second.records.map(\.events))
        #expect(first.engine.flows.count == second.engine.flows.count)
        #expect(first.engine.flows.count > 100)
        #expect(!first.engine.listeners.isEmpty)
    }

    @Test func beaconScenarioPhonesHomeOnAFixedPeriod() {
        // Keep closed flows around for the whole run so every beacon can be counted.
        var configuration = EngineConfiguration()
        configuration.fadeWindow = 1000
        let engine = run(.beacon, seconds: 100, configuration: configuration).engine
        let starts = engine.flows.values.filter { $0.pid == 4444 }.map(\.firstSeen).sorted()
        #expect(starts.count == 4)
        for pair in zip(starts, starts.dropFirst()) { #expect(abs(pair.1 - pair.0 - 30) < 0.5) }
    }

    @Test func portScanScenarioSweepsOneHost() {
        let engine = run(.portscan, seconds: 10).engine
        let scan = engine.flows.values.filter { $0.pid == 5555 }
        #expect(scan.count > 300)
        #expect(Set(scan.map(\.key.remote.address)).count == 1)
        #expect(Set(scan.map(\.key.remote.port)).count > 300)
    }

    @Test func replayingATraceRebuildsTheSameModel() throws {
        let original = run(.developer, seconds: 15)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sb-test-\(UUID().uuidString).sbtrace")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try TraceWriter(url: url, wallClock: 1_800_000_000, note: "test")
        for record in original.records { try writer.append(record) }
        try writer.close()

        let trace = try TraceFile.read(url)
        #expect(trace.header.wallClock == 1_800_000_000)
        #expect(trace.records.count == original.records.count)

        let replayed = FlowEngine()
        TraceFile.replay(trace.records, into: replayed)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(replayed.snapshot()) == encoder.encode(original.engine.snapshot()))
    }

    @Test func rejectsATraceFromAnotherVersion() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sb-test-\(UUID().uuidString).sbtrace")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"sbtrace":99,"wallClock":0,"note":""}"#.utf8).write(to: url)
        #expect(throws: TraceFile.TraceError.self) { try TraceFile.read(url) }
    }
}

@Suite struct FormattingTests {
    @Test func formatsBytesRatesAndDurations() {
        #expect(ByteFormat.bytes(980) == "980 B")
        #expect(ByteFormat.bytes(12_400) == "12.4 KB")
        #expect(ByteFormat.bytes(1_400_000) == "1.4 MB")
        #expect(ByteFormat.bytes(250_000_000) == "250 MB")
        #expect(ByteFormat.rate(0) == "–")
        #expect(ByteFormat.rate(12_000) == "12.0 KB/s")
        #expect(ByteFormat.duration(12) == "12s")
        #expect(ByteFormat.duration(8040) == "2h14m")
        #expect(ByteFormat.duration(200_000) == "2d7h")
    }

    @Test func parsesAddressesFromText() {
        #expect(IPAddress("10.0.0.36") == .v4(0x0A00_0024))
        #expect(IPAddress("::1")?.isLoopback == true)
        #expect(IPAddress("2001:db8::2a")?.description == "2001:db8::2a")
        #expect(IPAddress("not an address") == nil)
        #expect(Endpoint(address: IPAddress("::1")!, port: 443).description == "[::1]:443")
    }
}
