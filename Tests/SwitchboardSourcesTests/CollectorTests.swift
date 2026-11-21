import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardSources

/// The collector and a client talking over a real Unix socket, with the simulator standing
/// in for the privileged sources so no root is needed.
@Suite(.serialized) struct CollectorTests {
    /// Unix socket paths are limited to about a hundred bytes, so keep this one short.
    static func socketPath() -> String {
        "/tmp/sb-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).sock"
    }

    static func wait(_ seconds: Double = 2, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
    }

    @Test func aClientRebuildsTheSameModelTheCollectorHas() throws {
        let path = Self.socketPath()
        let source = SimulatorSource(scenario: .developer)
        let server = CollectorServer(path: path, sources: [source], resolver: PassthroughProcessResolver())
        try server.start()
        defer { server.stop() }

        // What a local engine would conclude, to compare against.
        let reference = FlowEngine()
        let local = SimulatorSource(scenario: .developer)

        // Run for a while before anyone connects: the client must be brought up to date.
        var time = 0.0
        for _ in 0..<20 {
            server.tick(now: time, includeHealth: false)
            reference.ingest(local.poll(now: time), from: "sim", at: time)
            time += 0.25
        }

        let client = try CollectorClient(path: path, clientName: "test")
        #expect(client.sources == ["sim"])
        #expect(client.collectorUID == geteuid())
        #expect(Self.wait { server.clientCount == 1 })

        let engine = FlowEngine(resolver: client)
        var received = 0
        for _ in 0..<20 {
            server.tick(now: time, includeHealth: true)
            reference.ingest(local.poll(now: time), from: "sim", at: time)
            // Give the bytes a moment to cross the socket.
            let before = received
            _ = Self.wait(0.5) {
                for (name, events) in client.pollBatches() {
                    received += events.count
                    engine.ingest(events, from: name, at: time)
                }
                return received > before
            }
            time += 0.25
        }

        let open = reference.flows.values.filter { $0.state != .closed }
        let mirrored = engine.flows.values.filter { $0.state != .closed }
        #expect(open.count > 100)
        #expect(Set(mirrored.map(\.key)) == Set(open.map(\.key)))
        // Counters arrive intact.
        let totals = Dictionary(uniqueKeysWithValues: open.map { ($0.key, $0.bytesTotal) })
        #expect(mirrored.allSatisfy { totals[$0.key] == $0.bytesTotal })
        #expect(engine.listeners.count == reference.listeners.count)
        #expect(Self.wait { !client.health.isEmpty })
        #expect(client.health.first?.hasPrefix("sim:") == true)
    }

    @Test func aClientLearnsWhenTheCollectorGoesAway() throws {
        let path = Self.socketPath()
        let server = CollectorServer(path: path, sources: [SimulatorSource(scenario: .quiet)], resolver: PassthroughProcessResolver())
        try server.start()
        let client = try CollectorClient(path: path, clientName: "test")
        #expect(client.isConnected)
        server.stop()
        #expect(Self.wait { !client.isConnected })
        // And there is nothing to connect to afterwards.
        #expect(throws: CollectorClient.ClientError.self) { try CollectorClient(path: path, clientName: "test") }
    }

    @Test func theCollectorNoticesWhenAClientLeaves() throws {
        let path = Self.socketPath()
        let server = CollectorServer(path: path, sources: [SimulatorSource(scenario: .quiet)], resolver: PassthroughProcessResolver())
        try server.start()
        defer { server.stop() }
        let client = try CollectorClient(path: path, clientName: "test")
        #expect(Self.wait { server.clientCount == 1 })
        client.close()
        #expect(Self.wait {
            server.tick(now: 0, includeHealth: false)
            return server.clientCount == 0
        })
    }

    @Test func aSecondCollectorOnTheSameSocketIsRefused() throws {
        let path = Self.socketPath()
        let first = CollectorServer(path: path, sources: [], resolver: PassthroughProcessResolver())
        try first.start()
        defer { first.stop() }
        let second = CollectorServer(path: path, sources: [], resolver: PassthroughProcessResolver())
        #expect(throws: CollectorServer.ServerError.self) { try second.start() }
    }

    @Test func aClientSpeakingAnotherProtocolVersionIsToldWhy() throws {
        let path = Self.socketPath()
        let server = CollectorServer(path: path, sources: [], resolver: PassthroughProcessResolver())
        try server.start()
        defer { server.stop() }

        let fd = try #require(CollectorServer.connect(path))
        defer { close(fd) }
        #expect(CollectorServer.writeAll(fd, Wire.frame(.hello(protocolVersion: 99, client: "future"))))
        var buffer = Wire.FrameBuffer()
        var chunk = [UInt8](repeating: 0, count: 1024)
        var reply: Wire.Message?
        while reply == nil {
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else { break }
            buffer.append(chunk[..<count])
            if let body = try buffer.next() { reply = try Wire.decode(body) }
        }
        guard case .refused(let reason) = reply else {
            Issue.record("expected a refusal, got \(String(describing: reply))")
            return
        }
        #expect(reason.contains("protocol 99"))
    }

    @Test func garbageInsteadOfAHelloIsRefused() throws {
        let path = Self.socketPath()
        let server = CollectorServer(path: path, sources: [], resolver: PassthroughProcessResolver())
        try server.start()
        defer { server.stop() }
        let fd = try #require(CollectorServer.connect(path))
        defer { close(fd) }
        #expect(CollectorServer.writeAll(fd, [9, 0, 0, 0, 200, 1, 2, 3, 4, 5, 6, 7, 8]))
        var chunk = [UInt8](repeating: 0, count: 1024)
        // A refusal, then the connection closes. It is never registered as a client.
        var total = 0
        while true {
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else { break }
            total += count
        }
        #expect(total > 0)
        #expect(server.clientCount == 0)
    }

    @Test func aResetMakesTheClientForgetWhatItWasToldBefore() throws {
        let path = Self.socketPath()
        let source = SimulatorSource(scenario: .quiet)
        let server = CollectorServer(path: path, sources: [source], resolver: PassthroughProcessResolver())
        try server.start()
        defer { server.stop() }
        server.tick(now: 0, includeHealth: false)

        // Two clients: the second one's arrival sends it a reset and the full state,
        // which must contain every socket and no removals of sockets it never saw.
        let client = try CollectorClient(path: path, clientName: "test")
        var events: [SourceEvent] = []
        #expect(Self.wait {
            events.append(contentsOf: client.pollBatches().flatMap(\.events))
            return events.count >= 20
        })
        #expect(events.allSatisfy { if case .seen = $0 { true } else { false } })
        let ids = events.compactMap { event -> UInt64? in
            if case .seen(let observation) = event { return observation.sourceID }
            return nil
        }
        #expect(Set(ids).count == ids.count)
    }
}
