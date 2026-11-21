import Foundation
import SwitchboardCore
import Testing
import simd

@testable import SwitchboardRender

private func simulated(_ layout: GraphLayout, scenario: SimulatorSource.Scenario = .developer, until end: Double = 40) -> (GraphController, FlowEngine) {
    let engine = FlowEngine()
    let controller = GraphController()
    controller.layout = layout
    controller.lanesWindow = 60
    SteppedRun.run(sources: [SimulatorSource(scenario: scenario)], engine: engine, until: end) { time in
        controller.update(engine.snapshot(), time: Float(time))
    }
    controller.settle()
    return (controller, engine)
}

private func seen(_ id: UInt64, pid: Int32, remote: String, port: UInt16 = 443, bytes: UInt64 = 5000, age: Double? = nil) -> SourceEvent {
    .seen(SocketObservation(
        sourceID: id, proto: .tcp, local: Endpoint(address: IPAddress("10.0.0.2")!, port: UInt16(20_000 + id % 40_000)),
        remote: Endpoint(address: IPAddress(remote)!, port: port), pid: pid, processName: "app\(pid)",
        rxBytes: bytes, txBytes: bytes / 10, tcpState: .established, ageSeconds: age))
}

/// The drawn node for an id, found the way the pointer finds it.
private func node(_ id: NodeID, in controller: GraphController) -> NodeInstance? {
    controller.frame(labelBudget: 0).nodes.first { controller.pick(at: $0.center, slack: 0.5) == .node(id) }
}

@Suite struct FlowLayoutTests {
    @Test func arrangesFourColumnsThatAccountForEveryByte() throws {
        let (controller, engine) = simulated(.flow)
        let frame = controller.frame(labelBudget: 200)
        let columns = Set(frame.nodes.map { ($0.center.x / 10).rounded() * 10 })
        #expect(columns.count == 4)
        // This Mac on the left, alone.
        #expect(frame.nodes[0].center.x == frame.nodes.map(\.center.x).min())
        #expect(frame.nodes.filter { abs($0.center.x - frame.nodes[0].center.x) < 1 }.count == 1)

        // Every byte to somewhere other than this Mac passes through exactly one service
        // and arrives at exactly one destination node.
        let outside = engine.flows.values.filter { !$0.key.remote.address.isLoopback && $0.state != .closed }
        let expected = outside.reduce(UInt64(0)) { $0 + $1.bytesTotal }
        var services: UInt64 = 0, destinations: UInt64 = 0
        for instance in frame.nodes {
            guard case .node(let id)? = controller.pick(at: instance.center, slack: 0.5) else { continue }
            let open = controller.flows(for: .node(id)).filter { $0.state != .closed }.reduce(UInt64(0)) { $0 + $1.bytesTotal }
            switch id {
            case .service: services += open
            case .group, .network, .endpoint: destinations += open
            default: break
            }
        }
        #expect(expected > 1_000_000)
        #expect(services == expected)
        #expect(destinations == expected)
        #expect(frame.labels.contains { $0.text == "HTTPS" })
        // Nothing overlaps: a column is a stack.
        for a in frame.nodes.indices {
            for b in frame.nodes.indices where b > a && abs(frame.nodes[a].center.x - frame.nodes[b].center.x) < 1 {
                #expect(abs(frame.nodes[a].center.y - frame.nodes[b].center.y) >= frame.nodes[a].radius + frame.nodes[b].radius)
            }
        }
    }

    @Test func widensARibbonWithItsShareOfTheTraffic() throws {
        let engine = FlowEngine()
        engine.ingest([
            seen(1, pid: 1, remote: "8.8.8.8", bytes: 9_000_000), seen(2, pid: 2, remote: "1.1.1.1", port: 22, bytes: 1_000_000),
        ], from: "test", at: 0)
        let controller = GraphController()
        controller.layout = .flow
        controller.update(engine.snapshot(), time: 0)
        controller.settle()
        let frame = controller.frame(labelBudget: 10)
        // Host to each process, process to service, service to destination.
        #expect(frame.edges.count == 6)
        let widths = frame.edges.map(\.halfWidth).sorted()
        #expect(widths.suffix(3).allSatisfy { $0 > 3 * widths[0] })
        let big = try #require(node(.process(1), in: controller)), small = try #require(node(.process(2), in: controller))
        #expect(big.radius > small.radius && big.center.y > small.center.y)
        #expect(controller.info(for: .node(.service("SSH")))?.rows.contains { $0.label == "Used by" && $0.value == "app2" } == true)
        #expect(controller.info(for: .edge(.process(1), .service("HTTPS")))?.title == "app1 → HTTPS")
        // A connection is found on the node for its far end.
        let target = controller.target(pid: 1, remote: Endpoint(address: IPAddress("8.8.8.8")!, port: 443), proto: .tcp)
        #expect(target == .node(.network(IPAddress("8.8.8.0")!, bits: 24)))
        #expect(controller.flows(for: target).count == 1)
    }

    @Test func foldsTheSmallestTogetherPastItsLimits() {
        let engine = FlowEngine()
        engine.ingest((1...60).map { seen(UInt64($0), pid: Int32($0), remote: "\($0 + 10).1.1.1", bytes: UInt64($0) * 10_000) }, from: "test", at: 0)
        let controller = GraphController()
        controller.layout = .flow
        controller.update(engine.snapshot(), time: 0)
        controller.settle()
        let frame = controller.frame(labelBudget: 200)
        // Host, 28 processes and the rest, one service, 32 destinations and the rest.
        #expect(frame.nodes.count == 1 + 28 + 1 + 1 + 32 + 1)
        #expect(frame.labels.contains { $0.text == "32 other processes" })
        #expect(controller.flows(for: .node(.group(.rest, "processes"))).count == 32)
        #expect(controller.flows(for: .node(.group(.rest, "destinations"))).count == 28)
        // The largest keep their own nodes.
        #expect(controller.flows(for: .node(.process(60))).count == 1)
        #expect(node(.process(60), in: controller) != nil)
        #expect(node(.process(1), in: controller) == nil)
    }

    @Test func groupsFarEndsByOwnerThenDomainThenNetwork() {
        #expect(GraphController.registeredDomain("api.eu.example.com") == "example.com")
        #expect(GraphController.registeredDomain("example.com") == "example.com")
        #expect(GraphController.registeredDomain("www.bbc.co.uk") == "bbc.co.uk")
        #expect(GraphController.registeredDomain("Edge.Example.NET") == "example.net")
        #expect(GraphController.registeredDomain("localhost") == "localhost")
        let (controller, _) = simulated(.flow)
        // The simulator names its destinations, so they gather by domain.
        #expect(controller.flows(for: .node(.group(.domain, "example.com"))).count > 3)
    }
}

@Suite struct LanesLayoutTests {
    @Test func drawsABarForEachConnectionInItsProcesssLane() throws {
        let engine = FlowEngine()
        engine.ingest([seen(1, pid: 1, remote: "8.8.8.8"), seen(2, pid: 2, remote: "1.1.1.1")], from: "test", at: 0)
        engine.ingest([seen(3, pid: 1, remote: "9.9.9.9")], from: "test", at: 30)
        engine.ingest([], from: "test", at: 40)
        let controller = GraphController()
        controller.layout = .lanes
        controller.lanesWindow = 60
        controller.update(engine.snapshot(), time: 40)
        controller.settle()
        let frame = controller.frame(labelBudget: 50)

        let first = try #require(node(.process(1), in: controller)), second = try #require(node(.process(2), in: controller))
        #expect(first.center.x == second.center.x && first.center.y > second.center.y)
        // Lines that end at the right-hand edge of the time axis are connections still open.
        let rightEdge = frame.edges.map { max($0.p0.x, $0.p1.x) }.max()!
        let bars = frame.edges.filter { abs($0.p0.y - $0.p1.y) < 0.01 && max($0.p0.x, $0.p1.x) == rightEdge && $0.halfWidth > 0.5 }
        #expect(bars.count == 3)
        let lanes = Dictionary(grouping: bars) { abs($0.p0.y - first.center.y) < 15 ? 1 : 2 }
        #expect(lanes[1]?.count == 2 && lanes[2]?.count == 1)
        // The one that began thirty seconds in starts further right than the one from the start.
        let starts = lanes[1]!.map { min($0.p0.x, $0.p1.x) }.sorted()
        #expect(starts[1] - starts[0] > 100)

        // A bar answers the pointer with the connection it stands for.
        let late = lanes[1]!.max { min($0.p0.x, $0.p1.x) < min($1.p0.x, $1.p1.x) }!
        let target = try #require(controller.pick(at: (late.p0 + late.p1) * 0.5, slack: 1))
        #expect(target == .edge(.process(1), .endpoint(IPAddress("9.9.9.9")!)))
        #expect(controller.flows(for: target).count == 1)
        #expect(controller.info(for: target)?.title.hasPrefix("app1 → ") == true)
        #expect(controller.target(pid: 1, remote: Endpoint(address: IPAddress("9.9.9.9")!, port: 443), proto: .tcp) == target)

        // The axis is labelled, and its marks are not things to click.
        #expect(frame.labels.contains { $0.text == "now" })
        #expect(frame.labels.contains { $0.text == "−30s" })
        for instance in frame.nodes where instance.radius < 1 { #expect(controller.pick(at: instance.center, slack: 0.4) == nil) }
    }

    @Test func remembersWhatEndedForAsLongAsItsWindow() {
        let engine = FlowEngine()
        let controller = GraphController()
        controller.layout = .lanes
        controller.lanesWindow = 600
        engine.ingest([seen(1, pid: 1, remote: "8.8.8.8"), seen(2, pid: 1, remote: "1.1.1.1")], from: "test", at: 0)
        controller.update(engine.snapshot(), time: 0)
        engine.ingest([.removed(sourceID: 2)], from: "test", at: 10)
        controller.update(engine.snapshot(), time: 10)
        func bars(at time: Double) -> Int {
            engine.ingest([], from: "test", at: time)
            controller.update(engine.snapshot(), time: Float(time))
            return controller.frame(labelBudget: 0).edges.filter { $0.halfWidth > 0.5 && abs($0.p0.y - $0.p1.y) < 0.01 }.count
        }
        // Long after the engine has forgotten it, the lane still shows that it happened.
        #expect(bars(at: 20) == 2)
        #expect(bars(at: 300) == 2)
        #expect(engine.flows.count == 1)
        // Until it has slid off the left-hand side.
        #expect(bars(at: 700) == 1)
        // And leaving the lanes forgets it, since nobody asked for ended connections to be kept.
        controller.layout = .constellation
        #expect(controller.endedCount == 0)
    }

    @Test func givesTheBusiestProcessesLanesWhenThereAreTooMany() {
        let (controller, engine) = simulated(.lanes, scenario: .stress, until: 0.25)
        let processes = Set(engine.flows.values.map(\.pid)).count
        let frame = controller.frame(labelBudget: 0)
        let shown = frame.nodes.filter { $0.kind == 1 }.count
        #expect(shown == min(processes, GraphController.laneLimit))
        #expect(frame.edges.count <= GraphController.barLimit + 200)
    }
}

@Suite struct LayoutSwitchTests {
    @Test func aProcessGlidesToItsNewPlaceAndKeepsWhatWasSelected() throws {
        let (controller, _) = simulated(.constellation)
        let pid: Int32 = 2010
        let selection = PickTarget.node(.process(pid))
        let flows = controller.flows(for: selection).map(\.id).sorted()
        let before = try #require(node(.process(pid), in: controller)).center
        #expect(!flows.isEmpty)

        for layout in [GraphLayout.flow, .lanes, .constellation] {
            controller.layout = layout
            // The first frame after the change: still where it was, not jumped.
            let starting = controller.frame(labelBudget: 0, highlights: [selection])
            #expect(starting.nodes.contains { simd_distance($0.center, layout == .flow ? before : $0.center) < 0.01 })
            // The lanes also show what has ended, so there the selection holds at least what it did.
            let now = Set(controller.flows(for: selection).map(\.id))
            #expect(layout == .lanes ? now.isSuperset(of: flows) : now == Set(flows), "\(layout)")
            #expect(controller.info(for: selection)?.title == controller.process(pid)?.name)
            controller.settle()
            // Selected, so it carries the white ring wherever it has gone.
            let lit = controller.frame(labelBudget: 0, highlights: [selection])
            #expect(lit.nodes.filter { $0.ring == SIMD4<Float>(1, 1, 1, 1) }.count == 1, "\(layout)")
        }
        // Back in the constellation it is where it always was.
        let after = try #require(node(.process(pid), in: controller)).center
        #expect(simd_distance(before, after) < 0.5)
    }

    @Test func theConstellationIsUntouchedByAVisitElsewhere() {
        let (plain, _) = simulated(.constellation)
        let (visited, _) = simulated(.constellation)
        visited.layout = .flow
        visited.settle()
        visited.layout = .lanes
        visited.settle()
        visited.layout = .constellation
        visited.settle(maximumSteps: 2000)
        plain.settle(maximumSteps: 2000)
        let a = plain.frame(labelBudget: 30), b = visited.frame(labelBudget: 30)
        #expect(a.nodes.count == b.nodes.count && a.edges.count == b.edges.count)
        #expect(a.halfSize == b.halfSize)
        // Processes return to their exact places; destinations to within the settling tolerance.
        for (x, y) in zip(a.nodes, b.nodes) { #expect(simd_distance(x.center, y.center) < (x.kind == 1 ? 1 : 12)) }
    }

    @Test func eachLayoutFitsItsOwnShape() {
        let (constellation, _) = simulated(.constellation)
        let (flow, _) = simulated(.flow)
        let (lanes, _) = simulated(.lanes)
        let round = constellation.frame(labelBudget: 0).halfSize
        #expect(round.x == round.y)
        for controller in [flow, lanes] {
            let frame = controller.frame(labelBudget: 0)
            #expect(frame.halfSize.x > frame.halfSize.y)
            #expect(frame.nodes.allSatisfy { abs($0.center.x) <= frame.halfSize.x && abs($0.center.y) <= frame.halfSize.y })
            #expect(frame.edges.allSatisfy { abs($0.p0.x) <= frame.halfSize.x && abs($0.p1.y) <= frame.halfSize.y })
        }
        #expect(Camera.fitting(halfSize: SIMD2(600, 600), viewport: SIMD2(2400, 1500)) == Camera.fitting(extent: 600, viewport: SIMD2(2400, 1500)))
        #expect(Camera.fitting(halfSize: SIMD2(1200, 300), viewport: SIMD2(2400, 1500)) == 1)
    }

    @Test func theFilterAppliesInEveryLayout() throws {
        for layout in GraphLayout.allCases {
            let (controller, _) = simulated(layout)
            let all = controller.frame(labelBudget: 0)
            controller.filter = try FlowFilter("process:brave")
            controller.settle()
            let some = controller.frame(labelBudget: 0)
            #expect(some.nodes.filter { $0.kind == 1 }.count < all.nodes.filter { $0.kind == 1 }.count, "\(layout)")
            #expect(some.nodes.filter { $0.kind == 1 }.count >= 1, "\(layout)")
            #expect(some.edges.count < all.edges.count, "\(layout)")
        }
    }
}
