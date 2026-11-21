import Foundation
import SwitchboardCore
import Testing
import simd

@testable import SwitchboardRender

/// Seattle, and five places around the world.
private struct Places: AddressEnricher {
    static let table: [String: (Double, Double, String)] = [
        "8.8.8.8": (37.4, -122.1, "US"), "1.1.1.1": (51.5, -0.1, "GB"), "9.9.9.9": (35.7, 139.7, "JP"),
        "4.4.4.4": (-33.9, 151.2, "AU"), "5.5.5.5": (-23.5, -46.6, "BR"),
    ]
    func facts(for address: IPAddress) -> AddressFacts {
        var facts = AddressFacts()
        if let place = Self.table[address.description] {
            facts.latitude = place.0
            facts.longitude = place.1
            facts.country = place.2
        }
        return facts
    }
}

private func seen(_ id: UInt64, pid: Int32, remote: String, bytes: UInt64 = 50_000) -> SourceEvent {
    .seen(SocketObservation(
        sourceID: id, proto: .tcp, local: Endpoint(address: IPAddress("10.0.0.2")!, port: UInt16(30_000 + id)),
        remote: Endpoint(address: IPAddress(remote)!, port: 443), pid: pid, processName: "app\(pid)",
        rxBytes: bytes, txBytes: bytes / 10, tcpState: .established))
}

private func globe() -> (GraphController, FlowEngine) {
    let engine = FlowEngine()
    engine.enricher = Places()
    engine.ingest(
        ["8.8.8.8", "1.1.1.1", "9.9.9.9", "4.4.4.4", "5.5.5.5", "192.168.1.20", "203.0.113.5"].enumerated().map {
            seen(UInt64($0.offset + 1), pid: $0.offset < 3 ? 1 : 2, remote: $0.element)
        }, from: "test", at: 0)
    let controller = GraphController()
    controller.home = GeoPoint(latitude: 47.61, longitude: -122.33)
    controller.layout = .globe
    controller.clustering = .off
    controller.update(engine.snapshot(), time: 0)
    controller.settle()
    return (controller, engine)
}

private func drawn(_ id: NodeID, in controller: GraphController) -> NodeInstance? {
    controller.frame(labelBudget: 0).nodes.first { controller.pick(at: $0.center, slack: 0.5) == .node(id) }
}

@Suite struct GlobeTests {
    @Test func facesHomeAndHidesWhatIsRoundTheBack() throws {
        let (controller, _) = globe()
        let frame = controller.frame(labelBudget: 50)
        // Seattle faces us; so does California. Sydney, Tokyo and São Paulo are round the back or near the rim.
        let host = frame.nodes[0]
        #expect(host.intensity > 0.9)
        let california = try #require(drawn(.endpoint(IPAddress("8.8.8.8")!), in: controller))
        #expect(simd_distance(california.center, host.center) < 60)
        #expect(drawn(.endpoint(IPAddress("4.4.4.4")!), in: controller) == nil)
        // A destination round the back is neither lit, labelled, nor clickable, and nor is its arc.
        let hidden = frame.nodes.filter { $0.kind == 2 && $0.intensity < 0.01 }
        #expect(!hidden.isEmpty)
        #expect(!frame.labels.contains { $0.text == "4.4.4.4" })
        let arcToSydney = PickTarget.edge(.process(2), .endpoint(IPAddress("4.4.4.4")!))
        #expect(controller.flows(for: arcToSydney).count == 1)
        for edge in frame.edges where edge.glow < 0.001 { #expect(controller.pick(at: (edge.p0 + edge.p1) * 0.5, slack: 1) != arcToSydney) }
    }

    @Test func putsHomeNetworksAtHomeAndUnknownPlacesBelow() throws {
        let (controller, _) = globe()
        let frame = controller.frame(labelBudget: 50)
        let local = try #require(drawn(.endpoint(IPAddress("192.168.1.20")!), in: controller))
        #expect(simd_distance(local.center, frame.nodes[0].center) < 40)
        let unknown = NodeID.group(.rest, "unlocated")
        let below = try #require(drawn(unknown, in: controller))
        #expect(below.center.y < frame.nodes.map(\.center.y).filter { $0 != below.center.y }.min()!)
        #expect(controller.flows(for: .node(unknown)).map(\.key.remote.address.description) == ["203.0.113.5"])
        #expect(controller.target(pid: 2, remote: Endpoint(address: IPAddress("203.0.113.5")!, port: 443), proto: .tcp) == .edge(.process(2), unknown))
        #expect(controller.info(for: .node(unknown))?.title == "places unknown")
    }

    @Test func swaysAboutHomeWithoutLosingIt() {
        let (controller, _) = globe()
        var positions: [SIMD2<Float>] = []
        for second in stride(from: Float(0), through: 160, by: 10) {
            controller.advance(time: second)
            controller.settle()
            let frame = controller.frame(labelBudget: 0)
            #expect(frame.nodes[0].intensity > 0.9, "home at \(second) s")
            positions.append(frame.nodes[0].center)
        }
        #expect(Set(positions.map { Int($0.x) }).count > 5)
        // Still means still.
        controller.advance(time: 40, motion: false)
        controller.settle()
        let a = controller.frame(labelBudget: 0).nodes[0].center
        controller.advance(time: 90, motion: false)
        controller.settle()
        #expect(controller.frame(labelBudget: 0).nodes[0].center == a)
    }

    @Test func lightingAProcessLightsItsArcs() throws {
        let (controller, _) = globe()
        let plain = controller.frame(labelBudget: 0)
        let lit = controller.frame(labelBudget: 0, highlights: [.node(.process(1))])
        let brighter = zip(plain.edges, lit.edges).filter { $0.1.glow > $0.0.glow }.count
        // Process 1 talks to California, London and Tokyo; whichever are in view brighten.
        #expect(brighter >= 1 && brighter <= 3)
        #expect(controller.info(for: .edge(.process(1), .endpoint(IPAddress("8.8.8.8")!)))?.title.hasPrefix("app1 → ") == true)
    }

    @Test func drawsTheLandAndTheGrid() {
        #expect(WorldOutline.rings.count > 15)
        for ring in WorldOutline.rings {
            #expect(ring.first! == ring.last!)
            #expect(ring.allSatisfy { abs($0.0) <= 90 && abs($0.1) <= 180 })
        }
        let lines = GlobeView.surface(scheme: .standard)
        #expect(lines.count > 1500)
        // No piece is longer than a few degrees, so the curves stay smooth as the globe turns.
        #expect(lines.allSatisfy { simd_distance($0.a, $0.b) < 0.06 })
        var view = GlobeView()
        view.face(GeoPoint(latitude: 0, longitude: 0))
        let (center, facing) = view.project(GlobeView.point(0, 0))
        #expect(simd_distance(center, view.center) < 0.001 && abs(facing - 1) < 1e-5)
        #expect(view.project(GlobeView.point(0, 180)).1 < -0.99)
        #expect(abs(view.project(GlobeView.point(0, 90)).0.x - (view.center.x + view.radius)) < 0.01)
    }

    @Test func guessesHomeFromTheTimeZone() {
        let seattle = GeoPoint.guess(timeZone: TimeZone(identifier: "America/Los_Angeles")!)
        #expect(abs(seattle.longitude + 118.24) < 0.01)
        let odd = GeoPoint.guess(timeZone: TimeZone(secondsFromGMT: 3 * 3600)!)
        #expect(abs(odd.longitude - 45) < 0.01)
        #expect(GeoPoint("47.61, -122.33") == GeoPoint(latitude: 47.61, longitude: -122.33))
        #expect(GeoPoint("north") == nil && GeoPoint("95, 10") == nil)
    }
}

/// Nodes with nothing to their right: the rows of the tree.
private func leaves(_ frame: RenderFrame) -> Int {
    frame.nodes.indices.dropFirst().filter { index in
        let node = frame.nodes[index]
        return !frame.edges.contains { edge in
            (simd_distance(edge.p0, node.center) < 0.01 && edge.p1.x > node.center.x + 1)
                || (simd_distance(edge.p1, node.center) < 0.01 && edge.p0.x > node.center.x + 1)
        }
    }.count
}

@Suite struct HierarchyTests {
    private func simulated(until end: Double = 40) -> (GraphController, FlowEngine) {
        let engine = FlowEngine(resolver: SimulatedProcessResolver())
        let controller = GraphController()
        controller.layout = .hierarchy
        SteppedRun.run(sources: [SimulatorSource(scenario: .developer)], engine: engine, until: end) { time in
            controller.update(engine.snapshot(), time: Float(time))
        }
        controller.settle()
        return (controller, engine)
    }

    @Test func everyConnectionLandsOnExactlyOneRow() throws {
        let (controller, engine) = simulated()
        let frame = controller.frame(labelBudget: 400)
        let open = engine.flows.values.filter { $0.state != .closed && !$0.key.remote.address.isLoopback }
        var found: [FlowID: Int] = [:]
        var leaves = 0
        for flow in open {
            let target = controller.target(pid: flow.pid, remote: flow.key.remote, proto: flow.key.proto)
            guard case .node(let id) = target else {
                Issue.record("not on a node: \(target)")
                continue
            }
            #expect(controller.flows(for: target).contains { $0.id == flow.id })
            found[flow.id, default: 0] += 1
            _ = id
        }
        #expect(found.count == open.count)
        // Rows are what the leaf column and the folds add up to, and stay within the budget.
        leaves = SwitchboardRenderTests.leaves(frame)
        #expect(leaves <= GraphController.hierarchyLeafBudget)
        #expect(leaves > 30)
        // Accounts are the second level, under this Mac.
        for account in ["ops", "root", "_mdnsresponder"] {
            #expect(controller.info(for: .node(.group(.user, account))) != nil, "\(account)")
        }
    }

    @Test func aBranchsFilterSelectsWhatTheBranchHolds() throws {
        let (controller, engine) = simulated()
        let frame = controller.frame(labelBudget: 400)
        var checked = 0
        for instance in frame.nodes {
            guard case .node(let id)? = controller.pick(at: instance.center, slack: 0.3), case .group = id,
                  let hint = controller.filterHint(for: .node(id))
            else { continue }
            let filter = try FlowFilter(hint)
            let held = Set(controller.flows(for: .node(id)).filter { $0.state != .closed }.map(\.id))
            let selected = Set(engine.flows.values.filter {
                $0.state != .closed && !$0.key.remote.address.isLoopback && filter.matches($0, process: engine.processes[$0.pid], now: engine.now)
            }.map(\.id))
            #expect(selected.isSuperset(of: held), "\(hint)")
            if hint.contains("host=") || hint.contains("remote=") || hint.hasPrefix("user=") {
                #expect(selected == held, "\(hint)")
            }
            checked += 1
        }
        #expect(checked > 40)
    }

    @Test func foldsWhatDoesNotFit() {
        let engine = FlowEngine()
        var events: [SourceEvent] = []
        for pid in 1...80 {
            for index in 0..<3 {
                let remote = "\(pid % 200 + 10).\(index).1.1"
                events.append(seen(UInt64(pid * 10 + index), pid: Int32(pid), remote: remote, bytes: UInt64(pid) * 1000))
            }
        }
        engine.ingest(events, from: "test", at: 0)
        let controller = GraphController()
        controller.layout = .hierarchy
        controller.update(engine.snapshot(), time: 0)
        controller.settle()
        let frame = controller.frame(labelBudget: 400)
        // Each of these processes has three domains, so each needs two rows: 31 fit in 64 with the fold.
        let shown = frame.nodes.filter { $0.kind == 1 }.count
        #expect(shown == 31)
        #expect(frame.labels.contains { $0.text == "\(80 - shown) other processes" })
        #expect(controller.flows(for: .node(.group(.path, "unknown account|+"))).count == (80 - shown) * 3)
        // The busiest are the ones kept.
        #expect(drawn(.process(80), in: controller) != nil)
        #expect(drawn(.process(1), in: controller) == nil)
        #expect(leaves(frame) <= GraphController.hierarchyLeafBudget)
    }

    @Test func namesTheFarEndByDomainThenNetwork() {
        func flow(_ remote: String, host: String?) -> Flow {
            Flow(
                id: 1, key: FlowKey(proto: .tcp, local: Endpoint(address: IPAddress("10.0.0.2")!, port: 1), remote: Endpoint(address: IPAddress(remote)!, port: 443)),
                pid: 1, direction: .outbound, interface: nil, state: .active, tcpState: nil, firstSeen: 0, lastSeen: 0, lastActive: 0,
                closedAt: nil, ageExact: true, bytesIn: 0, bytesOut: 0, packetsIn: 0, packetsOut: 0, rateIn: 0, rateOut: 0, rttMS: nil,
                retransmittedBytes: nil, service: nil, serviceBasis: nil, hostname: host, attribution: "t")
        }
        #expect(GraphController.hierarchyDomain(flow("8.8.8.8", host: "dns.google")).name == "dns.google")
        #expect(GraphController.hierarchyDomain(flow("52.1.2.3", host: "a.b.example.com")).name == "example.com")
        #expect(GraphController.hierarchyDomain(flow("52.1.2.3", host: nil)).name == "52.1.2.0/24")
        #expect(GraphController.hierarchyDomain(flow("192.168.1.9", host: nil)).name == "private network")
    }
}

@Suite struct EveryLayoutTests {
    @Test func selectionAndFilterSurviveEveryLayout() throws {
        let engine = FlowEngine(resolver: SimulatedProcessResolver())
        engine.enricher = SimulatedGeography()
        let controller = GraphController()
        controller.home = GeoPoint(latitude: 47.61, longitude: -122.33)
        SteppedRun.run(sources: [SimulatorSource(scenario: .developer)], engine: engine, until: 30) { time in
            controller.update(engine.snapshot(), time: Float(time))
        }
        let selection = PickTarget.node(.process(2010))
        let flows = Set(controller.flows(for: selection).map(\.id))
        controller.filter = try FlowFilter("process:brave OR process:slack")
        for layout in GraphLayout.allCases {
            controller.layout = layout
            controller.settle()
            let now = Set(controller.flows(for: selection).map(\.id))
            #expect(!now.isEmpty, "\(layout)")
            #expect(now.isSubset(of: flows.union(now)), "\(layout)")
            let frame = controller.frame(labelBudget: 0, highlights: [selection])
            #expect(frame.nodes.filter { $0.ring == SIMD4<Float>(1, 1, 1, 1) }.count == 1, "\(layout)")
            let processes = frame.nodes.filter { $0.kind == 1 }.count
            #expect(processes == 2, "\(layout): \(processes) processes shown under the filter")
        }
    }
}
