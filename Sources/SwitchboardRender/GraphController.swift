import Foundation
import SwitchboardCore
import simd

public enum NodeID: Hashable, Sendable {
    case host
    case process(Int32)
    case endpoint(IPAddress)
}

public enum PickTarget: Hashable, Sendable {
    case node(NodeID)
    /// Always process first, endpoint second; or host first, process second.
    case edge(NodeID, NodeID)
}

/// What the tooltip shows for whatever is under the pointer.
public struct HoverInfo: Sendable, Equatable {
    public struct Row: Sendable, Equatable, Identifiable {
        public var label: String
        public var value: String
        public var id: String { label }
    }

    public var title: String
    public var subtitle: String
    public var rows: [Row]
    public var footnote: String?
}

public struct LabelRequest: Sendable {
    public var text: String
    public var node: Int
    /// 0 host, 1 process, 2 endpoint.
    public var kind: Int
}

/// Everything the renderer needs for one frame.
public struct RenderFrame: Sendable {
    public var nodes: [NodeInstance] = []
    public var edges: [EdgeInstance] = []
    public var labels: [LabelRequest] = []
    /// Executable paths for nodes that should carry an app icon.
    public var icons: [(node: Int, path: String)] = []
    /// Radius of the layout, in world units.
    public var extent: Float = 600
}

/// Holds the graph: turns engine snapshots into nodes and edges, lays them out, and
/// answers what is under the pointer.
///
/// Placement is a pure function of names and addresses, so the same process and the same
/// destination land in the same part of the field on every launch (docs/SPEC.md §9.1,
/// "position is memory"). A short relaxation then nudges overlapping nodes apart.
///
/// Thread-safe: the engine thread calls `update`, the main thread everything else.
public final class GraphController: @unchecked Sendable {
    private struct Node {
        var id: NodeID
        var position: SIMD2<Float>
        var anchor: SIMD2<Float>
        var radius: Float
        var color: SIMD3<Float>
        var intensity: Float
        var bornAt: Float
        var ring: SIMD4<Float> = .zero
        var label: String
        var priority: Double
        var iconPath: String?
    }

    private struct Edge {
        /// Node indexes. Pulses travel from `from` to `to`.
        var from: Int
        var to: Int
        var target: PickTarget
        var halfWidth: Float
        var glow: Float
        var pulse: Float
        var speed: Float
        var density: Float
        var color: SIMD3<Float>
        var phase: Float
        var bend: Float
    }

    private struct EdgeKey: Hashable {
        var pid: Int32
        var address: IPAddress
    }

    private struct Aggregate {
        var rateIn = 0.0
        var rateOut = 0.0
        var bytesIn: UInt64 = 0
        var bytesOut: UInt64 = 0
        var open = 0
        var total = 0
        /// 1 while any flow is open, falling to 0 as the last closed flow fades.
        var life = 0.0
        var services: [String: Int] = [:]
        var flows: [Flow] = []

        var rate: Double { rateIn + rateOut }
        var bytes: UInt64 { bytesIn &+ bytesOut }
        var service: String? { services.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key }

        mutating func add(_ flow: Flow, life flowLife: Double) {
            rateIn += flow.rateIn
            rateOut += flow.rateOut
            bytesIn &+= flow.bytesIn
            bytesOut &+= flow.bytesOut
            total += 1
            if flow.state != .closed { open += 1 }
            life = max(life, flowLife)
            if let service = flow.service { services[service, default: 0] += 1 }
            flows.append(flow)
        }
    }

    private let lock = NSLock()
    private let hostLabel: String
    private var nodes: [Node] = []
    private var edges: [Edge] = []
    private var index: [NodeID: Int] = [:]
    private var settled = false
    private var arrivals: [NodeID: (bornAt: Float, lastSeen: Float)] = [:]
    private var extent: Float = 420

    // Kept from the last snapshot for tooltips.
    private var edgeAggregates: [EdgeKey: Aggregate] = [:]
    private var processAggregates: [Int32: Aggregate] = [:]
    private var endpointAggregates: [IPAddress: Aggregate] = [:]
    private var processes: [Int32: ProcessRecord] = [:]
    private var listeners: [Int32: [Listener]] = [:]
    private var snapshotTime: EngineTime = 0

    /// While true, snapshots are ignored and the picture holds still. Collection carries on.
    public var paused: Bool {
        get { lock.withLock { isPaused } }
        set { lock.withLock { isPaused = newValue } }
    }
    private var isPaused = false

    /// Closed flows linger this long before leaving the graph.
    public static let fadeSeconds = 6.0

    public init(hostLabel: String = "THIS MAC") {
        self.hostLabel = hostLabel
    }

    // MARK: - Building the scene

    /// Rebuilds the graph from the engine's current model. `time` is animation time.
    public func update(_ snapshot: EngineSnapshot, time: Float) {
        lock.lock()
        defer { lock.unlock() }
        guard !isPaused else { return }

        var byEdge: [EdgeKey: Aggregate] = [:]
        var byProcess: [Int32: Aggregate] = [:]
        var byEndpoint: [IPAddress: Aggregate] = [:]
        for flow in snapshot.flows {
            var life = 1.0
            if flow.state == .closed {
                life = 1 - (snapshot.time - (flow.closedAt ?? snapshot.time)) / Self.fadeSeconds
                guard life > 0 else { continue }
            }
            byProcess[flow.pid, default: Aggregate()].add(flow, life: life)
            // A loopback connection is this Mac talking to itself. It counts toward the
            // process and its line to the centre, but gets no node of its own: one shared
            // "127.0.0.1" would pull lines from every corner of the graph.
            if flow.key.remote.address.isLoopback { continue }
            byEdge[EdgeKey(pid: flow.pid, address: flow.key.remote.address), default: Aggregate()].add(flow, life: life)
            byEndpoint[flow.key.remote.address, default: Aggregate()].add(flow, life: life)
        }

        edgeAggregates = byEdge
        processAggregates = byProcess
        endpointAggregates = byEndpoint
        processes = Dictionary(uniqueKeysWithValues: snapshot.processes.map { ($0.pid, $0) })
        listeners = Dictionary(grouping: snapshot.listeners, by: \.pid)
        snapshotTime = snapshot.time

        let previous = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        // When did each node first appear? Remembered for a minute after it leaves, so a
        // process that reconnects every few seconds is not announced as new each time.
        func born(_ id: NodeID) -> Float {
            let at = arrivals[id]?.bornAt ?? time
            arrivals[id] = (at, time)
            return at
        }
        var built: [Node] = []
        built.reserveCapacity(byProcess.count + byEndpoint.count + 1)

        // This Mac, at the centre.
        built.append(Node(
            id: .host, position: .zero, anchor: .zero, radius: 15, color: Palette.host, intensity: 1,
            bornAt: -100, label: hostLabel, priority: .infinity))

        // Processes on a ring, each at an angle fixed by its name.
        let pids = byProcess.keys.sorted()
        // Each process gets at least 80 units of arc, enough for its node and label.
        let ringRadius = max(250, Float(pids.count) * 80 / (2 * .pi))
        let sector = 2 * Float.pi / Float(max(pids.count, 1))
        let angles = Self.spread(pids.map { pid in
            Self.unit(processes[pid]?.name ?? "pid \(pid)", salt: 0x51) * 2 * .pi
        })
        var processAngle: [Int32: Float] = [:]
        for (offset, pid) in pids.enumerated() {
            let aggregate = byProcess[pid]!
            let record = processes[pid]
            let angle = angles[offset]
            processAngle[pid] = angle
            let anchor = SIMD2(cos(angle), sin(angle)) * ringRadius
            let id = NodeID.process(pid)
            let exposed = listeners[pid]?.contains { $0.exposed } ?? false
            var node = Node(
                id: id, position: previous[id]?.position ?? anchor * 0.15, anchor: anchor,
                radius: 10 + 4 * Self.level(Double(aggregate.bytes), scale: 9),
                color: Palette.process, intensity: 0.34 + 0.5 * Self.level(aggregate.rate, scale: 6.5) * Float(aggregate.life),
                bornAt: born(id), label: Self.clip(record?.name ?? "pid \(pid)", to: 22),
                priority: 1e15 + aggregate.rate, iconPath: record?.path)
            // A process listening on a non-loopback address is reachable from outside.
            if exposed { node.ring = SIMD4(Palette.remoteAccess, 0.85) }
            built.append(node)
        }

        // Remote endpoints beyond the ring, each in the sector of the process that uses it most.
        var owner: [IPAddress: (pid: Int32, bytes: UInt64)] = [:]
        for (key, aggregate) in byEdge {
            if let current = owner[key.address], (current.bytes, -Int64(current.pid)) >= (aggregate.bytes, -Int64(key.pid)) {
                continue
            }
            owner[key.address] = (key.pid, aggregate.bytes)
        }
        var owned: [Int32: Int] = [:]
        for entry in owner.values { owned[entry.pid, default: 0] += 1 }

        var farthest = ringRadius
        for address in byEndpoint.keys.sorted(by: Self.addressOrder) {
            let aggregate = byEndpoint[address]!
            let ownerPID = owner[address]!.pid
            let count = Float(owned[ownerPID] ?? 1)
            let text = address.description
            let fan = min(1.5, sector * 0.85 + 0.05 * count.squareRoot())
            let angle = (processAngle[ownerPID] ?? 0) + (Self.unit(text, salt: 0xA1) - 0.5) * fan
            let radius = ringRadius + 170 + Self.unit(text, salt: 0xB2) * (130 + 30 * count.squareRoot())
            farthest = max(farthest, radius)
            let anchor = SIMD2(cos(angle), sin(angle)) * radius
            let id = NodeID.endpoint(address)
            let start = previous[.process(ownerPID)]?.position ?? SIMD2(cos(angle), sin(angle)) * ringRadius
            built.append(Node(
                id: id, position: previous[id]?.position ?? start, anchor: anchor,
                radius: 2.6 + 6 * Self.level(Double(aggregate.bytes), scale: 9),
                color: Palette.color(forService: aggregate.service),
                intensity: (0.3 + 0.7 * Self.level(aggregate.rate, scale: 6.5)) * Float(max(aggregate.life, 0.15)),
                bornAt: born(id), label: text, priority: aggregate.rate + Double(aggregate.bytes) * 1e-9))
        }

        var lookup: [NodeID: Int] = [:]
        lookup.reserveCapacity(built.count)
        for (offset, node) in built.enumerated() { lookup[node.id] = offset }

        var links: [Edge] = []
        links.reserveCapacity(byEdge.count + pids.count)
        for pid in pids {
            guard let to = lookup[.process(pid)], let aggregate = byProcess[pid] else { continue }
            links.append(Self.edge(
                from: 0, to: to, target: .edge(.host, .process(pid)), aggregate: aggregate, color: Palette.trunk,
                seed: "trunk \(pid)", bend: 0, outbound: aggregate.rateOut >= aggregate.rateIn, trunk: true))
        }
        let orderedKeys = byEdge.keys.sorted { a, b in
            a.pid != b.pid ? a.pid < b.pid : Self.addressOrder(a.address, b.address)
        }
        for key in orderedKeys {
            guard let aggregate = byEdge[key], let process = lookup[.process(key.pid)], let endpoint = lookup[.endpoint(key.address)]
            else { continue }
            let seed = "\(key.pid) \(key.address)"
            // A process with many destinations gets dimmer edges, so a fan of hundreds
            // reads as a texture rather than burning out to white.
            let crowd = Float(byProcess[key.pid]?.flows.reduce(into: Set<IPAddress>()) { $0.insert($1.key.remote.address) }.count ?? 1)
            links.append(Self.edge(
                from: process, to: endpoint, target: .edge(.process(key.pid), .endpoint(key.address)), aggregate: aggregate,
                color: Palette.color(forService: aggregate.service), seed: seed,
                bend: (Self.unit(seed, salt: 0xC3) - 0.5) * 0.26, outbound: aggregate.rateOut >= aggregate.rateIn, trunk: false,
                dimming: min(1, pow(10 / max(crowd, 1), 0.6))))
        }

        arrivals = arrivals.filter { time - $0.value.lastSeen < 60 }
        nodes = built
        edges = links
        index = lookup
        extent = farthest + 90
        settled = false
    }

    private static func edge(
        from: Int, to: Int, target: PickTarget, aggregate: Aggregate, color: SIMD3<Float>, seed: String,
        bend: Float, outbound: Bool, trunk: Bool, dimming: Float = 1
    ) -> Edge {
        let level = level(aggregate.rate, scale: 6.5)
        let life = Float(aggregate.life)
        return Edge(
            // Pulses run the way most of the bytes are going.
            from: outbound ? from : to, to: outbound ? to : from, target: target,
            halfWidth: (trunk ? 1.5 : 1.0) + 2.6 * level,
            glow: (0.035 + 0.2 * level) * life * dimming,
            pulse: level > 0.02 ? (0.3 + 0.95 * level) * life * max(dimming, 0.5) : 0,
            speed: 0.16 + 0.85 * level, density: 1 + (3 * level).rounded(.down),
            color: color, phase: unit(seed, salt: 0xD4), bend: bend)
    }

    // MARK: - Layout

    /// One relaxation step: every node drifts to its anchor while overlapping nodes push apart.
    public func step() {
        lock.lock()
        defer { lock.unlock() }
        guard !settled, !isPaused, nodes.count > 1 else { return }

        var moved: Float = 0
        var push = [SIMD2<Float>](repeating: .zero, count: nodes.count)

        // Bucket nodes on a grid so only near neighbours are compared.
        let cell: Float = 30
        var buckets: [SIMD2<Int32>: [Int]] = [:]
        buckets.reserveCapacity(nodes.count)
        for offset in nodes.indices.dropFirst() {
            let position = nodes[offset].position
            buckets[SIMD2(Int32((position.x / cell).rounded(.down)), Int32((position.y / cell).rounded(.down))), default: []]
                .append(offset)
        }
        for (key, members) in buckets {
            for dx in Int32(0)...1 {
                for dy in Int32(-1)...1 where dx == 1 || dy >= 0 {
                    let same = dx == 0 && dy == 0
                    guard let others = same ? members : buckets[SIMD2(key.x + dx, key.y + dy)] else { continue }
                    for (i, a) in members.enumerated() {
                        for b in same ? Array(members[(i + 1)...]) : others {
                            let delta = nodes[a].position - nodes[b].position
                            let distance = max(simd_length(delta), 0.01)
                            let wanted = nodes[a].radius + nodes[b].radius + 5
                            guard distance < wanted else { continue }
                            // Coincident nodes separate along a direction fixed by their order.
                            let direction = distance > 0.02 ? delta / distance : SIMD2(cos(Float(a)), sin(Float(a)))
                            let shove = direction * (wanted - distance) * 0.5
                            push[a] += shove
                            push[b] -= shove
                        }
                    }
                }
            }
        }

        for offset in nodes.indices.dropFirst() {
            let change = (nodes[offset].anchor - nodes[offset].position) * 0.09 + push[offset] * 0.45
            nodes[offset].position += change
            moved = max(moved, simd_length(change))
        }
        if moved < 0.02 { settled = true }
    }

    /// Runs the layout to rest. For rendering a single frame with nobody watching.
    public func settle(maximumSteps: Int = 400) {
        for _ in 0..<maximumSteps {
            if lock.withLock({ settled }) { break }
            step()
        }
    }

    // MARK: - Rendering

    /// The current picture. `labelBudget` is how many endpoints may carry a label.
    public func frame(labelBudget: Int, highlight: PickTarget? = nil) -> RenderFrame {
        lock.lock()
        defer { lock.unlock() }
        var frame = RenderFrame()
        frame.extent = extent
        frame.nodes.reserveCapacity(nodes.count)
        frame.edges.reserveCapacity(edges.count)

        var highlightedNode: NodeID?
        if case .node(let id) = highlight { highlightedNode = id }

        for (offset, node) in nodes.enumerated() {
            var ring = node.ring
            var intensity = node.intensity
            if node.id == highlightedNode {
                ring = SIMD4(1, 1, 1, 1)
                intensity = 1
            }
            let kind: Float = offset == 0 ? 0 : (offset <= processCount ? 1 : 2)
            frame.nodes.append(NodeInstance(
                center: node.position, radius: node.radius, icon: -1, color: SIMD4(node.color, 1), ring: ring,
                birth: node.bornAt, intensity: intensity, kind: kind))
            if let path = node.iconPath { frame.icons.append((offset, path)) }
        }

        for edge in edges {
            let a = nodes[edge.from].position, b = nodes[edge.to].position
            let along = b - a
            let control = (a + b) * 0.5 + SIMD2(-along.y, along.x) * edge.bend
            var glow = edge.glow
            var halfWidth = edge.halfWidth
            if let highlight {
                let touches: Bool
                switch highlight {
                case .node(let id): touches = nodes[edge.from].id == id || nodes[edge.to].id == id
                case .edge: touches = edge.target == highlight
                }
                if touches {
                    glow = glow * 1.8 + 0.22
                    halfWidth += 0.6
                } else {
                    glow *= 0.45
                }
            }
            frame.edges.append(EdgeInstance(
                p0: a, p1: b, control: control, halfWidth: halfWidth, phase: edge.phase,
                color: SIMD4(edge.color, 1), speed: edge.speed, density: edge.density, glow: glow, pulse: edge.pulse))
        }

        // The host and every process are named; endpoints compete for the remaining labels.
        if !nodes.isEmpty { frame.labels.append(LabelRequest(text: nodes[0].label, node: 0, kind: 0)) }
        let named = (1..<min(processCount + 1, nodes.count)).sorted { nodes[$0].priority > nodes[$1].priority }
        for offset in named.prefix(160) {
            frame.labels.append(LabelRequest(text: nodes[offset].label, node: offset, kind: 1))
        }
        let endpoints = nodes.indices.dropFirst(processCount + 1)
        var chosen = endpoints.filter { nodes[$0].priority > 1 }
            .sorted { nodes[$0].priority > nodes[$1].priority }.prefix(labelBudget).map { $0 }
        if let highlightedNode, let offset = index[highlightedNode], offset > processCount, !chosen.contains(offset) {
            chosen.append(offset)
        }
        if case .edge(_, let far) = highlight, let offset = index[far], offset > processCount, !chosen.contains(offset) {
            chosen.append(offset)
        }
        for offset in chosen {
            frame.labels.append(LabelRequest(text: nodes[offset].label, node: offset, kind: 2))
        }
        return frame
    }

    /// Nodes are stored host first, then processes, then endpoints.
    private var processCount: Int { processAggregates.count }

    // MARK: - Picking

    /// What is at `point` (world units). `slack` widens small targets so they can be hit.
    public func pick(at point: SIMD2<Float>, slack: Float) -> PickTarget? {
        lock.lock()
        defer { lock.unlock() }
        var best: (target: PickTarget, distance: Float)?
        for node in nodes {
            let distance = simd_distance(node.position, point)
            if distance <= node.radius + slack, distance < (best?.distance ?? .infinity) {
                best = (.node(node.id), distance)
            }
        }
        if let best { return best.target }

        for edge in edges {
            let a = nodes[edge.from].position, b = nodes[edge.to].position
            let along = b - a
            let control = (a + b) * 0.5 + SIMD2(-along.y, along.x) * edge.bend
            var nearest = Float.infinity
            var previous = a
            for step in 1...12 {
                let t = Float(step) / 12
                let next = simd_mix(simd_mix(a, control, SIMD2(repeating: t)), simd_mix(control, b, SIMD2(repeating: t)), SIMD2(repeating: t))
                nearest = min(nearest, Self.distance(from: point, toSegment: previous, next))
                previous = next
            }
            if nearest <= max(edge.halfWidth, slack), nearest < (best?.distance ?? .infinity) {
                best = (edge.target, nearest)
            }
        }
        return best?.target
    }

    private static func distance(from point: SIMD2<Float>, toSegment a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        let ab = b - a
        let lengthSquared = simd_length_squared(ab)
        guard lengthSquared > 1e-9 else { return simd_distance(point, a) }
        let t = min(max(simd_dot(point - a, ab) / lengthSquared, 0), 1)
        return simd_distance(point, a + ab * t)
    }

    // MARK: - Tooltips

    public func info(for target: PickTarget) -> HoverInfo? {
        lock.lock()
        defer { lock.unlock() }
        switch target {
        case .node(.host):
            let open = processAggregates.values.reduce(0) { $0 + $1.open }
            let rateIn = processAggregates.values.reduce(0) { $0 + $1.rateIn }
            let rateOut = processAggregates.values.reduce(0) { $0 + $1.rateOut }
            let exposed = listeners.values.joined().filter(\.exposed).count
            return HoverInfo(
                title: hostLabel, subtitle: "\(processAggregates.count) processes on the network",
                rows: [
                    .init(label: "Connections", value: "\(open)"),
                    .init(label: "Destinations", value: "\(endpointAggregates.count)"),
                    .init(label: "Rate", value: "↓ \(ByteFormat.rate(rateIn))  ↑ \(ByteFormat.rate(rateOut))"),
                    .init(label: "Listening", value: "\(listeners.values.joined().count) sockets, \(exposed) exposed"),
                ])
        case .node(.process(let pid)), .edge(.host, .process(let pid)):
            guard let aggregate = processAggregates[pid] else { return nil }
            return processInfo(pid, aggregate)
        case .node(.endpoint(let address)):
            guard let aggregate = endpointAggregates[address] else { return nil }
            let users = Set(aggregate.flows.map(\.pid)).sorted().map { processes[$0]?.name ?? "pid \($0)" }
            var rows = trafficRows(aggregate)
            rows.insert(.init(label: "Used by", value: Self.list(users)), at: 0)
            return HoverInfo(title: address.description, subtitle: Self.classification(address), rows: rows, footnote: nil)
        case .edge(.process(let pid), .endpoint(let address)):
            guard let aggregate = edgeAggregates[EdgeKey(pid: pid, address: address)] else { return nil }
            let name = processes[pid]?.name ?? "pid \(pid)"
            var rows = trafficRows(aggregate)
            // The busiest connection, spelled out in full.
            if let flow = aggregate.flows.max(by: { ($0.rateTotal, $0.bytesTotal) < ($1.rateTotal, $1.bytesTotal) }) {
                rows.append(.init(label: "Busiest", value: "\(flow.key.proto.rawValue) \(flow.key.local) → \(flow.key.remote)"))
                if let state = flow.tcpState { rows.append(.init(label: "TCP state", value: state.rawValue)) }
                if let rtt = flow.rttMS { rows.append(.init(label: "Round trip", value: String(format: "%.0f ms", rtt))) }
                if let lost = flow.retransmittedBytes, lost > 0 {
                    rows.append(.init(label: "Retransmitted", value: ByteFormat.bytes(Double(lost))))
                }
                if let interface = flow.interface { rows.append(.init(label: "Interface", value: interface)) }
            }
            return HoverInfo(
                title: "\(name) → \(address)", subtitle: "pid \(pid) · \(Self.classification(address))", rows: rows, footnote: nil)
        default:
            return nil
        }
    }

    private func processInfo(_ pid: Int32, _ aggregate: Aggregate) -> HoverInfo {
        let record = processes[pid]
        var rows: [HoverInfo.Row] = []
        if let path = record?.path { rows.append(.init(label: "Path", value: path)) }
        rows.append(.init(label: "User", value: record?.username ?? record?.uid.map { "uid \($0)" } ?? "–"))
        if let parent = record?.parentPID {
            rows.append(.init(label: "Parent", value: "\(processes[parent]?.name ?? "pid") \(parent)"))
        }
        rows.append(contentsOf: trafficRows(aggregate))
        let remotes = Set(aggregate.flows.map(\.key.remote.address))
        let local = aggregate.flows.count { $0.key.remote.address.isLoopback }
        rows.append(.init(label: "Destinations", value: "\(remotes.count { !$0.isLoopback })" + (local > 0 ? " (+\(local) loopback connections)" : "")))
        if let sockets = listeners[pid], !sockets.isEmpty {
            let ports = sockets.map { "\($0.local.port)\($0.exposed ? " (exposed)" : "")" }
            rows.append(.init(label: "Listening on", value: Self.list(Array(Set(ports)).sorted())))
        }
        return HoverInfo(
            title: record?.name ?? "pid \(pid)", subtitle: "pid \(pid)", rows: rows,
            footnote: record?.restricted == true ? "Some details need the collector" : nil)
    }

    private func trafficRows(_ aggregate: Aggregate) -> [HoverInfo.Row] {
        var rows: [HoverInfo.Row] = [
            .init(label: "Connections", value: aggregate.open == aggregate.total ? "\(aggregate.open)" : "\(aggregate.open) open, \(aggregate.total - aggregate.open) closing"),
            .init(label: "Rate", value: "↓ \(ByteFormat.rate(aggregate.rateIn))  ↑ \(ByteFormat.rate(aggregate.rateOut))"),
            .init(label: "Total", value: "↓ \(ByteFormat.bytes(Double(aggregate.bytesIn)))  ↑ \(ByteFormat.bytes(Double(aggregate.bytesOut)))"),
        ]
        let services = aggregate.flows.reduce(into: [String: ServiceBasis]()) { result, flow in
            if let service = flow.service, let basis = flow.serviceBasis { result[service] = basis }
        }
        if !services.isEmpty {
            let text = services.keys.sorted().map { "\($0) (by \(services[$0]!.rawValue))" }
            rows.append(.init(label: "Service", value: Self.list(text)))
        }
        if let oldest = aggregate.flows.filter({ $0.state != .closed }).min(by: { $0.firstSeen < $1.firstSeen }) {
            rows.append(.init(
                label: "Oldest", value: (oldest.ageExact ? "" : "≥ ") + ByteFormat.duration(oldest.age(at: snapshotTime))))
        }
        return rows
    }

    // MARK: - Helpers

    private static func clip(_ text: String, to limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }

    private static func list(_ items: [String], limit: Int = 4) -> String {
        items.count <= limit ? items.joined(separator: ", ") : items.prefix(limit).joined(separator: ", ") + " +\(items.count - limit)"
    }

    private static func classification(_ address: IPAddress) -> String {
        if address.isLoopback { return "loopback" }
        switch address {
        case .v4(let value):
            let a = value >> 24, b = (value >> 16) & 0xff
            if a == 10 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168) { return "private network" }
            if a == 169 && b == 254 { return "link-local" }
            if a == 100 && (64...127).contains(b) { return "carrier-grade NAT" }
            if a >= 224 { return "multicast" }
        case .v6(let hi, _):
            if hi >> 57 == 0x7e { return "private network" }
            if hi >> 54 == 0x3fa { return "link-local" }
            if hi >> 56 == 0xff { return "multicast" }
        }
        return "public address"
    }

    /// 0 at nothing, 1 at `10^scale`, logarithmic in between.
    private static func level(_ value: Double, scale: Double) -> Float {
        Float(min(max(log10(1 + value) / scale, 0), 1))
    }

    /// A stable number in 0 ..< 1 derived from text (FNV-1a), so placement survives restarts.
    static func unit(_ text: String, salt: UInt8) -> Float {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325 ^ UInt64(salt)
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        // Finish with a full mix so names that differ only in their last character
        // (worker-1, worker-2) still land far apart.
        hash ^= hash >> 33
        hash &*= 0xff51_afd7_ed55_8ccd
        hash ^= hash >> 33
        hash &*= 0xc4ce_b9fe_1a85_ec53
        hash ^= hash >> 33
        return Float(hash >> 40) / Float(1 << 24)
    }

    private static func addressOrder(_ a: IPAddress, _ b: IPAddress) -> Bool {
        func key(_ address: IPAddress) -> (Int, UInt64, UInt64) {
            switch address {
            case .v4(let value): (0, 0, UInt64(value))
            case .v6(let hi, let lo): (1, hi, lo)
            }
        }
        return key(a) < key(b)
    }

    /// Spaces angles evenly around the circle, in the order the names asked for.
    ///
    /// Each name hashes to a preferred angle. Keeping only their order, and rotating the
    /// evenly spaced result to sit as close to the preferences as possible, gives every
    /// node the same room while a process still lands in roughly the same direction on
    /// every launch.
    static func spread(_ wanted: [Float]) -> [Float] {
        guard wanted.count > 1 else { return wanted }
        let turn = 2 * Float.pi
        let slot = turn / Float(wanted.count)
        let order = wanted.indices.sorted { (wanted[$0], $0) < (wanted[$1], $1) }
        // Circular mean of how far each preference is from its evenly spaced slot.
        var sum = SIMD2<Float>.zero
        for (rank, original) in order.enumerated() {
            let offset = wanted[original] - Float(rank) * slot
            sum += SIMD2(cos(offset), sin(offset))
        }
        let rotation = atan2(sum.y, sum.x)
        var result = wanted
        for (rank, original) in order.enumerated() { result[original] = rotation + Float(rank) * slot }
        return result
    }
}
