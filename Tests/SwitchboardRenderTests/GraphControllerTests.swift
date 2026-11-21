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
        let lit = controller.frame(labelBudget: 0, highlight: .node(.process(2010)))
        let index = plain.nodes.indices.first { lit.nodes[$0].ring == SIMD4<Float>(1, 1, 1, 1) }
        #expect(index != nil)
        let brighter = zip(plain.edges, lit.edges).filter { $0.1.glow > $0.0.glow }.count
        let dimmer = zip(plain.edges, lit.edges).filter { $0.1.glow < $0.0.glow }.count
        #expect(brighter > 0)
        #expect(dimmer > brighter)
    }
}
