import Foundation
import SwitchboardCore
import Testing
import simd

@testable import SwitchboardRender

/// A graph built from the simulator on a fixed clock, so every test sees the same scene.
private func simulated(_ scenario: SimulatorSource.Scenario = .developer, until end: Double = 20) -> (GraphController, FlowEngine) {
    let source = SimulatorSource(scenario: scenario)
    let engine = FlowEngine()
    let controller = GraphController()
    SteppedRun.run(sources: [source], engine: engine, until: end) { time in
        controller.update(engine.snapshot(), time: Float(time))
    }
    controller.settle()
    return (controller, engine)
}

private func flow(pid: Int32, remote: String, port: UInt16 = 443, id: UInt64) -> SourceEvent {
    .seen(SocketObservation(
        sourceID: id, proto: .tcp, local: Endpoint(address: IPAddress("10.0.0.2")!, port: UInt16(40_000 + id)),
        remote: Endpoint(address: IPAddress(remote)!, port: port), pid: pid, processName: "app\(pid)",
        rxBytes: 5000, txBytes: 500, tcpState: .established))
}

@Suite struct PlacementTests {
    @Test func spacesTheRingEvenly() {
        let wanted: [Float] = [0.1, 0.11, 0.12, 0.13, 3.0, 3.01, 5.5, 5.51]
        let placed = GraphController.spread(wanted).sorted()
        let slot = 2 * Float.pi / Float(wanted.count)
        for pair in zip(placed, placed.dropFirst()) { #expect(abs(pair.1 - pair.0 - slot) < 1e-4) }
    }

    @Test func keepsTheOrderNamesAskedFor() {
        let wanted: [Float] = [4.0, 1.0, 2.5, 0.2]
        let placed = GraphController.spread(wanted)
        let wantedOrder = wanted.indices.sorted { wanted[$0] < wanted[$1] }
        // Starting from the same node, both go round the circle in the same sequence.
        let turn = 2 * Float.pi
        let start = placed[wantedOrder[0]]
        let placedOrder = placed.indices.sorted {
            (placed[$0] - start + 2 * turn).truncatingRemainder(dividingBy: turn)
                < (placed[$1] - start + 2 * turn).truncatingRemainder(dividingBy: turn)
        }
        #expect(placedOrder == wantedOrder)
    }

    @Test func hashesSimilarNamesFarApart() {
        // Names differing only in a trailing number must not cluster.
        let values = (0..<60).map { GraphController.unit("worker-\($0)", salt: 0x51) }
        var buckets = [Int](repeating: 0, count: 6)
        for value in values {
            #expect(value >= 0 && value < 1)
            buckets[Int(value * 6)] += 1
        }
        #expect(buckets.allSatisfy { $0 >= 3 })
        #expect(GraphController.unit("Safari", salt: 0x51) == GraphController.unit("Safari", salt: 0x51))
        #expect(GraphController.unit("Safari", salt: 0x51) != GraphController.unit("Safari", salt: 0xA1))
    }

    @Test func putsTheSameSceneInTheSamePlaceEveryTime() {
        let first = simulated().0.frame(labelBudget: 10)
        let second = simulated().0.frame(labelBudget: 10)
        #expect(first.nodes.count == second.nodes.count)
        #expect(first.nodes.count > 50)
        for pair in zip(first.nodes, second.nodes) { #expect(pair.0.center == pair.1.center) }
    }

    @Test func settlesWithoutOverlappingProcesses() {
        let frame = simulated().0.frame(labelBudget: 0)
        let processes = frame.nodes.filter { $0.kind == 1 }
        #expect(processes.count > 5)
        for (index, a) in processes.enumerated() {
            for b in processes[(index + 1)...] {
                #expect(simd_distance(a.center, b.center) >= a.radius + b.radius)
            }
        }
        // Everything lies within the extent the camera is told to frame.
        #expect(frame.nodes.allSatisfy { simd_length($0.center) <= frame.extent })
    }
}

@Suite struct SceneTests {
    @Test func drawsOneEdgePerProcessAndPerProcessDestinationPair() {
        let engine = FlowEngine()
        engine.ingest(
            [flow(pid: 1, remote: "93.184.216.34", id: 1), flow(pid: 1, remote: "93.184.216.34", port: 80, id: 2),
             flow(pid: 1, remote: "1.1.1.1", id: 3), flow(pid: 2, remote: "1.1.1.1", id: 4)],
            from: "test", at: 0)
        let controller = GraphController()
        controller.update(engine.snapshot(), time: 0)
        let frame = controller.frame(labelBudget: 10)
        // Host, two processes, two destinations.
        #expect(frame.nodes.count == 5)
        #expect(frame.nodes.map(\.kind) == [0, 1, 1, 2, 2])
        // Two trunks, and three process-to-destination edges (two flows share one).
        #expect(frame.edges.count == 5)
    }

    @Test func keepsLoopbackOffTheOuterField() {
        let engine = FlowEngine()
        engine.ingest([flow(pid: 1, remote: "127.0.0.1", port: 5432, id: 1)], from: "test", at: 0)
        let controller = GraphController()
        controller.update(engine.snapshot(), time: 0)
        let frame = controller.frame(labelBudget: 10)
        #expect(frame.nodes.map(\.kind) == [0, 1])
        #expect(frame.edges.count == 1)
        let info = controller.info(for: .node(.process(1)))
        #expect(info?.rows.first { $0.label == "Destinations" }?.value == "0 (+1 loopback connections)")
    }

    @Test func fadesClosedFlowsOutOfTheGraph() {
        let engine = FlowEngine()
        let controller = GraphController()
        engine.ingest([flow(pid: 1, remote: "1.1.1.1", id: 1)], from: "test", at: 0)
        engine.ingest([.removed(sourceID: 1)], from: "test", at: 1)
        controller.update(engine.snapshot(), time: 1)
        #expect(controller.frame(labelBudget: 0).nodes.count == 3)
        // Past the fade, the engine still remembers the flow but the graph has let it go.
        engine.ingest([], from: "test", at: 1 + GraphController.fadeSeconds + 0.5)
        controller.update(engine.snapshot(), time: 8)
        #expect(controller.frame(labelBudget: 0).nodes.count == 1)
    }

    @Test func holdsStillWhilePaused() {
        let engine = FlowEngine()
        let controller = GraphController()
        engine.ingest([flow(pid: 1, remote: "1.1.1.1", id: 1)], from: "test", at: 0)
        controller.update(engine.snapshot(), time: 0)
        controller.paused = true
        engine.ingest([flow(pid: 2, remote: "8.8.8.8", id: 2)], from: "test", at: 1)
        controller.update(engine.snapshot(), time: 1)
        #expect(controller.frame(labelBudget: 0).nodes.count == 3)
        controller.paused = false
        controller.update(engine.snapshot(), time: 2)
        #expect(controller.frame(labelBudget: 0).nodes.count == 5)
    }

    @Test func doesNotAnnounceAProcessThatReconnects() {
        let engine = FlowEngine()
        let controller = GraphController()
        engine.ingest([flow(pid: 1, remote: "1.1.1.1", id: 1)], from: "test", at: 0)
        controller.update(engine.snapshot(), time: 0)
        let firstBirth = controller.frame(labelBudget: 0).nodes[1].birth
        // Gone long enough to leave the graph, then back within the minute.
        engine.ingest([.removed(sourceID: 1)], from: "test", at: 1)
        engine.ingest([], from: "test", at: 10)
        controller.update(engine.snapshot(), time: 10)
        #expect(controller.frame(labelBudget: 0).nodes.count == 1)
        engine.ingest([flow(pid: 1, remote: "1.1.1.1", id: 2)], from: "test", at: 12)
        controller.update(engine.snapshot(), time: 12)
        #expect(controller.frame(labelBudget: 0).nodes[1].birth == firstBirth)
    }
}

@Suite struct PickingAndTooltipTests {
    @Test func findsTheNodeUnderThePointerAndNothingInEmptySpace() {
        let (controller, _) = simulated()
        let frame = controller.frame(labelBudget: 0)
        #expect(controller.pick(at: .zero, slack: 2) == .node(.host))
        let process = frame.nodes.first { $0.kind == 1 }!
        guard case .node(.process) = controller.pick(at: process.center, slack: 2) else {
            Issue.record("expected a process under the pointer")
            return
        }
        #expect(controller.pick(at: SIMD2(frame.extent * 3, frame.extent * 3), slack: 2) == nil)
    }

    @Test func findsAnEdgeAlongItsCurve() {
        let (controller, _) = simulated()
        let frame = controller.frame(labelBudget: 0)
        // The midpoint of the first trunk: on the curve, away from both nodes.
        let trunk = frame.edges[0]
        let middle = (trunk.p0 + trunk.p1) * 0.25 + trunk.control * 0.5
        guard case .edge(.host, .process) = controller.pick(at: middle, slack: 2) else {
            Issue.record("expected the trunk edge under the pointer")
            return
        }
    }

    @Test func reportsTheSameTotalsAsTheEngine() throws {
        let (controller, engine) = simulated()
        let pid: Int32 = 2010
        let flows = engine.flows.values.filter { flow in
            guard flow.pid == pid else { return false }
            guard flow.state == .closed, let closedAt = flow.closedAt else { return true }
            return engine.now - closedAt < GraphController.fadeSeconds
        }
        let info = try #require(controller.info(for: .node(.process(pid))))
        #expect(info.title == "Brave Browser Helper")
        let total = try #require(info.rows.first { $0.label == "Total" }?.value)
        let bytesIn = flows.reduce(0.0) { $0 + Double($1.bytesIn) }
        let bytesOut = flows.reduce(0.0) { $0 + Double($1.bytesOut) }
        #expect(total == "↓ \(ByteFormat.bytes(bytesIn))  ↑ \(ByteFormat.bytes(bytesOut))")
        let rate = try #require(info.rows.first { $0.label == "Rate" }?.value)
        let rateIn = flows.reduce(0.0) { $0 + $1.rateIn }, rateOut = flows.reduce(0.0) { $0 + $1.rateOut }
        #expect(rate == "↓ \(ByteFormat.rate(rateIn))  ↑ \(ByteFormat.rate(rateOut))")
    }

    @Test func highlightingBrightensWhatIsHoveredAndDimsTheRest() {
        let (controller, _) = simulated()
        let plain = controller.frame(labelBudget: 0)
        let lit = controller.frame(labelBudget: 0, highlights: [.node(.process(2010))])
        let index = plain.nodes.indices.first { lit.nodes[$0].ring == SIMD4<Float>(1, 1, 1, 1) }
        #expect(index != nil)
        let brighter = zip(plain.edges, lit.edges).filter { $0.1.glow > $0.0.glow }.count
        let dimmer = zip(plain.edges, lit.edges).filter { $0.1.glow < $0.0.glow }.count
        #expect(brighter > 0)
        #expect(dimmer > brighter)
    }
}

@Suite struct FilterAndFocusTests {
    @Test func drawsOnlyWhatTheFilterMatches() throws {
        let (controller, engine) = simulated()
        let everything = controller.frame(labelBudget: 0)
        controller.filter = try FlowFilter("pid=2010")
        let filtered = controller.frame(labelBudget: 0)
        // The host, one process, and that process's destinations.
        #expect(filtered.nodes.filter { $0.kind == 1 }.count == 1)
        #expect(filtered.nodes.count < everything.nodes.count)
        let destinations = Set(engine.flows.values.filter { flow in
            guard flow.pid == 2010 else { return false }
            guard flow.state == .closed, let closedAt = flow.closedAt else { return true }
            return engine.now - closedAt < GraphController.fadeSeconds
        }.map(\.key.remote.address))
        #expect(filtered.nodes.filter { $0.kind == 2 }.count == destinations.count)
        #expect(controller.flows(for: .node(.host)).allSatisfy { $0.pid == 2010 })

        controller.filter = .all
        #expect(controller.frame(labelBudget: 0).nodes.count == everything.nodes.count)
    }

    @Test func appliesANewFilterEvenWhilePaused() throws {
        let (controller, _) = simulated()
        controller.paused = true
        controller.filter = try FlowFilter("pid=2010")
        #expect(controller.frame(labelBudget: 0).nodes.filter { $0.kind == 1 }.count == 1)
    }

    @Test func focusDimsEverythingOutsideTheNeighbourhood() {
        let (controller, _) = simulated()
        let plain = controller.frame(labelBudget: 0)
        controller.focus = .node(.process(2010))
        let focused = controller.frame(labelBudget: 0)

        let dimmedNodes = zip(plain.nodes, focused.nodes).filter { $0.1.intensity < $0.0.intensity * 0.5 }.count
        let keptNodes = zip(plain.nodes, focused.nodes).filter { $0.1.intensity == $0.0.intensity }.count
        #expect(dimmedNodes > 0)
        // The focused process, the host, and its destinations keep their brightness.
        #expect(keptNodes >= 3)
        #expect(dimmedNodes + keptNodes == plain.nodes.count)

        let stilled = zip(plain.edges, focused.edges).filter { $0.0.pulse > 0 && $0.1.pulse == 0 }.count
        #expect(stilled > 0)
        // Only the neighbourhood keeps its labels.
        #expect(focused.labels.count < plain.labels.count)

        controller.focus = nil
        #expect(controller.frame(labelBudget: 0).nodes.map(\.intensity) == plain.nodes.map(\.intensity))
    }

    @Test func aFocusThatHasGoneAwayDimsNothing() {
        let (controller, _) = simulated()
        let plain = controller.frame(labelBudget: 0)
        controller.focus = .node(.process(99_999))
        #expect(controller.frame(labelBudget: 0).nodes.map(\.intensity) == plain.nodes.map(\.intensity))
    }

    @Test func listsTheFlowsBehindEachKindOfTarget() {
        let (controller, _) = simulated()
        let all = controller.flows(for: .node(.host))
        let process = controller.flows(for: .node(.process(2010)))
        #expect(!process.isEmpty && process.count < all.count)
        #expect(process.allSatisfy { $0.pid == 2010 })
        let address = process[0].key.remote.address
        let edge = controller.flows(for: .edge(.process(2010), .endpoint(address)))
        #expect(!edge.isEmpty)
        #expect(edge.allSatisfy { $0.pid == 2010 && $0.key.remote.address == address })
        #expect(controller.flows(for: .node(.endpoint(address))).count >= edge.count)
    }
}

@Suite struct ClusteringAndLocalEdgeTests {
    private func events(_ count: Int, network: String, pid: Int32 = 1, start: UInt64 = 1) -> [SourceEvent] {
        (0..<count).map { flow(pid: pid, remote: "\(network).\($0 + 10)", id: start + UInt64($0)) }
    }

    @Test func mergesAddressesInOneNetworkIntoOneNode() {
        let engine = FlowEngine()
        engine.ingest(events(5, network: "52.21.130") + [flow(pid: 1, remote: "8.8.8.8", id: 99)], from: "test", at: 0)
        let controller = GraphController()
        controller.clustering = .off
        controller.update(engine.snapshot(), time: 0)
        #expect(controller.frame(labelBudget: 0).nodes.count == 8)

        controller.clustering = .subnet
        let network = NodeID.network(IPAddress("52.21.130.0")!, bits: 24)
        // Selecting a node always shows its label, however quiet it is.
        let clustered = controller.frame(labelBudget: 20, highlights: [.node(network)])
        // Host, process, one network node, and the address that is alone in its network.
        #expect(clustered.nodes.count == 4)
        #expect(clustered.labels.contains { $0.text == "52.21.130.0/24 ×5" })
        #expect(controller.flows(for: .node(network)).count == 5)
        #expect(controller.info(for: .node(network))?.subtitle.hasPrefix("5 addresses") == true)
        // A connection is found on the node that now stands for it.
        let target = controller.target(pid: 1, remote: Endpoint(address: IPAddress("52.21.130.12")!, port: 443), proto: .tcp)
        #expect(target == .edge(.process(1), network))
    }

    @Test func clustersAutomaticallyOnlyPastTheThreshold() {
        let engine = FlowEngine()
        engine.ingest(events(6, network: "52.21.130"), from: "test", at: 0)
        let controller = GraphController()
        controller.clustering = .automatic(threshold: 10)
        controller.update(engine.snapshot(), time: 0)
        #expect(controller.frame(labelBudget: 0).nodes.count == 8)
        controller.clustering = .automatic(threshold: 5)
        #expect(controller.frame(labelBudget: 0).nodes.count == 3)
    }

    @Test func expandsAndCollapsesANetworkOnRequest() {
        let engine = FlowEngine()
        engine.ingest(events(4, network: "52.21.130"), from: "test", at: 0)
        let controller = GraphController()
        controller.clustering = .subnet
        controller.update(engine.snapshot(), time: 0)
        let network = NodeID.network(IPAddress("52.21.130.0")!, bits: 24)
        #expect(controller.frame(labelBudget: 0).nodes.count == 3)
        controller.toggleExpansion(of: network)
        #expect(controller.frame(labelBudget: 0).nodes.count == 6)
        controller.toggleExpansion(of: .endpoint(IPAddress("52.21.130.11")!))
        #expect(controller.frame(labelBudget: 0).nodes.count == 3)
    }

    @Test func groupsIPv6ByItsFirst48Bits() {
        #expect(GraphController.network(of: IPAddress("2606:4700:10:1::5")!) == .network(IPAddress("2606:4700:10::")!, bits: 48))
        #expect(GraphController.network(of: IPAddress("10.1.2.3")!) == .network(IPAddress("10.1.2.0")!, bits: 24))
    }

    @Test func drawsALocalConnectionBetweenItsTwoProcesses() {
        let engine = FlowEngine()
        let listener = SourceEvent.seen(SocketObservation(
            sourceID: 1, proto: .tcp, local: Endpoint(address: IPAddress("127.0.0.1")!, port: 5432),
            remote: Endpoint(address: IPAddress("0.0.0.0")!, port: 0), pid: 20, processName: "postgres", tcpState: .listen))
        // The same connection as each end sees it.
        let client = SourceEvent.seen(SocketObservation(
            sourceID: 2, proto: .tcp, local: Endpoint(address: IPAddress("127.0.0.1")!, port: 51_000),
            remote: Endpoint(address: IPAddress("127.0.0.1")!, port: 5432), pid: 10, processName: "node",
            rxBytes: 900, txBytes: 100, tcpState: .established))
        let server = SourceEvent.seen(SocketObservation(
            sourceID: 3, proto: .tcp, local: Endpoint(address: IPAddress("127.0.0.1")!, port: 5432),
            remote: Endpoint(address: IPAddress("127.0.0.1")!, port: 51_000), pid: 20, processName: "postgres",
            rxBytes: 100, txBytes: 900, tcpState: .established))
        engine.ingest([listener, client, server], from: "test", at: 0)

        let controller = GraphController()
        controller.update(engine.snapshot(), time: 0)
        let frame = controller.frame(labelBudget: 0)
        // Host and two processes; two trunks and one line between the processes.
        #expect(frame.nodes.map(\.kind) == [0, 1, 1])
        #expect(frame.edges.count == 3)
        let local = PickTarget.edge(.process(10), .process(20))
        #expect(controller.flows(for: local).count == 1)
        #expect(controller.info(for: local)?.title == "node → postgres")
        #expect(controller.target(pid: 10, remote: Endpoint(address: IPAddress("127.0.0.1")!, port: 5432), proto: .tcp) == local)
        // The line bows toward the centre rather than cutting straight across.
        let line = frame.edges[2]
        #expect(simd_length(line.control) < simd_length((line.p0 + line.p1) * 0.5))
    }

    @Test func showsAPastMomentAndReturnsToThePresent() {
        let engine = FlowEngine()
        let controller = GraphController()
        engine.ingest([flow(pid: 1, remote: "1.1.1.1", id: 1)], from: "test", at: 0)
        let earlier = engine.snapshot()
        controller.update(earlier, time: 0)
        engine.ingest([flow(pid: 2, remote: "8.8.8.8", id: 2)], from: "test", at: 1)
        controller.update(engine.snapshot(), time: 1)
        #expect(controller.frame(labelBudget: 0).nodes.count == 5)

        controller.hold(earlier)
        #expect(controller.paused)
        #expect(controller.frame(labelBudget: 0).nodes.count == 3)
        // The present keeps arriving, unseen, while the past is on screen.
        engine.ingest([flow(pid: 3, remote: "9.9.9.9", id: 3)], from: "test", at: 2)
        controller.update(engine.snapshot(), time: 2)
        #expect(controller.frame(labelBudget: 0).nodes.count == 3)
        controller.hold(nil)
        #expect(controller.frame(labelBudget: 0).nodes.count == 7)
    }

    @Test func lightsEverySelectedItem() {
        let (controller, _) = simulated()
        let lit = controller.frame(labelBudget: 0, highlights: [.node(.process(2010)), .node(.process(2144))])
        #expect(lit.nodes.filter { $0.ring == SIMD4<Float>(1, 1, 1, 1) }.count == 2)
    }
}

@Suite struct KeepEndedTests {
    /// One connection that opens at 0, closes at 1, and is long forgotten by the engine at 100.
    private func ended(keeping: Bool) -> (GraphController, FlowEngine) {
        let engine = FlowEngine()
        let controller = GraphController()
        controller.keepsEnded = keeping
        engine.ingest([flow(pid: 1, remote: "1.1.1.1", id: 1), flow(pid: 2, remote: "8.8.8.8", id: 2)], from: "test", at: 0)
        controller.update(engine.snapshot(), time: 0)
        engine.ingest([.removed(sourceID: 1)], from: "test", at: 1)
        controller.update(engine.snapshot(), time: 1)
        engine.ingest([], from: "test", at: 100)
        controller.update(engine.snapshot(), time: 100)
        return (controller, engine)
    }

    @Test func byDefaultEndedConnectionsLeave() {
        let (controller, engine) = ended(keeping: false)
        #expect(engine.flows.count == 1)
        // Host, the process still connected, and its destination.
        #expect(controller.frame(labelBudget: 0).nodes.count == 3)
        #expect(controller.endedCount == 0)
    }

    @Test func whenKeptTheyStayButSubdued() throws {
        let (controller, engine) = ended(keeping: true)
        // The engine has forgotten it; the graph has not.
        #expect(engine.flows.count == 1)
        let frame = controller.frame(labelBudget: 0)
        #expect(frame.nodes.count == 5)
        #expect(controller.endedCount == 1)

        // Its line is dimmer than a live one and carries no pulses.
        let live = try #require(frame.edges.first { $0.p1 == frame.nodes[4].center || $0.p0 == frame.nodes[4].center })
        let gone = try #require(frame.edges.first { $0.p1 == frame.nodes[3].center || $0.p0 == frame.nodes[3].center })
        #expect(gone.glow < live.glow * 0.5)
        #expect(gone.pulse == 0)
        // And its process is dimmer than the one still connected.
        #expect(frame.nodes[1].intensity < frame.nodes[2].intensity)

        let info = try #require(controller.info(for: .node(.process(1))))
        #expect(info.title == "app1")
        #expect(info.rows.first { $0.label == "Connections" }?.value == "0 open, 1 ended")
        #expect(controller.flows(for: .node(.endpoint(IPAddress("1.1.1.1")!))).first?.state == .closed)
    }

    @Test func turningItOffForgetsThem() {
        let (controller, _) = ended(keeping: true)
        controller.keepsEnded = false
        #expect(controller.frame(labelBudget: 0).nodes.count == 3)
        #expect(controller.endedCount == 0)
        // Turning it back on does not bring them back.
        controller.keepsEnded = true
        #expect(controller.frame(labelBudget: 0).nodes.count == 3)
    }

    @Test func canBeClearedWithoutLeavingTheMode() {
        let (controller, _) = ended(keeping: true)
        controller.clearEnded()
        #expect(controller.keepsEnded)
        #expect(controller.frame(labelBudget: 0).nodes.count == 3)
    }

    @Test func respectsTheFilter() throws {
        let (controller, _) = ended(keeping: true)
        controller.filter = try FlowFilter("pid=2")
        #expect(controller.frame(labelBudget: 0).nodes.count == 3)
        controller.filter = try FlowFilter("state:closed")
        #expect(controller.frame(labelBudget: 0).nodes.count == 3)
        #expect(controller.flows(for: .node(.host)).map(\.pid) == [1])
    }

    @Test func doesNotShowAsEndedWhatHadNotEndedYet() {
        let engine = FlowEngine()
        let controller = GraphController()
        controller.keepsEnded = true
        engine.ingest([flow(pid: 1, remote: "1.1.1.1", id: 1)], from: "test", at: 0)
        engine.ingest([], from: "test", at: 5)
        let before = engine.snapshot()
        controller.update(before, time: 5)
        engine.ingest([.removed(sourceID: 1)], from: "test", at: 10)
        controller.update(engine.snapshot(), time: 10)
        engine.ingest([], from: "test", at: 100)
        controller.update(engine.snapshot(), time: 100)
        #expect(controller.endedCount == 1)

        // Scrubbed back to before it closed, the connection is shown open, once.
        controller.hold(before)
        let flows = controller.flows(for: .node(.host))
        #expect(flows.count == 1)
        #expect(flows.first?.state != .closed)
    }

    @Test func remembersOnlySoMany() {
        let engine = FlowEngine()
        let controller = GraphController()
        controller.keepsEnded = true
        let total = GraphController.endedLimit + 200
        let local = IPAddress("10.0.0.2")!
        var opened: [SourceEvent] = []
        var removed: [SourceEvent] = []
        for index in 0..<total {
            let id = UInt64(index + 1)
            let localPort = UInt16(1024 + index % 60_000)
            let remote = Endpoint(address: IPAddress.v4(0x0800_0000 + UInt32(index)), port: 443)
            let observation = SocketObservation(
                sourceID: id, proto: .tcp, local: Endpoint(address: local, port: localPort), remote: remote,
                pid: 1, processName: "app", tcpState: .established)
            opened.append(.seen(observation))
            removed.append(.removed(sourceID: id))
        }
        engine.ingest(opened, from: "test", at: 0)
        engine.ingest(removed, from: "test", at: 1)
        controller.update(engine.snapshot(), time: 1)
        #expect(controller.endedCount == GraphController.endedLimit)
    }
}
