import Foundation
import SwitchboardCore
import simd

/// The arrangements other than the constellation. Each takes the same connections the
/// constellation was about to draw and returns nodes, edges and bars in its own places.
/// Nodes keep their identities, so picking, selection, tooltips and the filter all work
/// unchanged, and a change of layout is a glide rather than a cut.
extension GraphController {
    struct LayoutInput {
        var byProcess: [Int32: Aggregate]
        var byAddressEdge: [AddressEdge: Aggregate]
        var links: [EdgeKey: Aggregate]
        var nodeFor: [IPAddress: NodeID]
        var processes: [Int32: ProcessRecord]
        var listeners: [Int32: [Listener]]
        var scheme: PaletteScheme
        var previous: [NodeID: Node]
        var hostLabel: String
        var now: EngineTime
        var window: Double
        var tagColors: [String: SIMD3<Float>]
        var remotes: [NodeID: Aggregate]
        var members: [NodeID: [IPAddress]]
        var groupLabels: [NodeID: String]
        var home: GeoPoint
        var globeView: GlobeView
    }

    struct LayoutScene {
        var nodes: [Node] = []
        var edges: [Edge] = []
        var bars: [Bar] = []
        var halfSize = SIMD2<Float>(600, 400)
        var processCount = 0
        var nodeAggregates: [NodeID: Aggregate] = [:]
        var edgeAggregates: [EdgeKey: Aggregate] = [:]
        var members: [NodeID: [IPAddress]] = [:]
        var labels: [NodeID: String] = [:]
        var nodeFor: [IPAddress: NodeID] = [:]
        var globeLines: [GlobeLine] = []
        var connectionNodes: [AddressEdge: NodeID] = [:]
        /// Filter expressions that select what a node stands for, where the app cannot work it out.
        var filters: [NodeID: String] = [:]
    }

    /// At most this many processes and destinations get a node of their own in the flow
    /// layout; the smallest are drawn together.
    static let flowProcessLimit = 28
    static let flowDestinationLimit = 32
    static let laneLimit = 40
    static let barLimit = 4000

    /// The part of a hostname that someone registered: `api.eu.example.com` is `example.com`.
    /// A guess from the shape of the name, not a lookup in the public suffix list.
    static func registeredDomain(_ host: String) -> String {
        let parts = host.lowercased().split(separator: ".")
        guard parts.count > 2 else { return host.lowercased() }
        // `example.co.uk`: a two-letter country under a short second level.
        let short = parts[parts.count - 1].count == 2 && parts[parts.count - 2].count <= 3
        return parts.suffix(short ? 3 : 2).joined(separator: ".")
    }

    static func processNode(
        _ input: LayoutInput, pid: Int32, aggregate: Aggregate, anchor: SIMD2<Float>, radius: Float, bornAt: Float
    ) -> Node {
        let record = input.processes[pid]
        let id = NodeID.process(pid)
        var node = Node(
            id: id, position: input.previous[id]?.position ?? anchor, anchor: anchor, radius: radius, color: Palette.process,
            intensity: (0.42 + 0.45 * level(aggregate.rate, scale: 6.5) * Float(aggregate.life)) * Float(0.5 + 0.5 * aggregate.life),
            bornAt: bornAt, label: clip(record?.name ?? "pid \(pid)", to: 26), priority: 1e15 + aggregate.rate,
            iconPath: record?.path, labelSide: -1)
        let exposed = input.listeners[pid]?.contains { $0.exposed } ?? false
        switch record?.signing {
        case .unsigned, .invalid: node.ring = SIMD4(Palette.attention, 1)
        case .adHoc: node.ring = SIMD4(input.scheme.remoteAccess, 0.85)
        default: if exposed { node.ring = SIMD4(input.scheme.remoteAccess, 0.85) }
        }
        return node
    }

    /// Top-down positions for a column of nodes, centred on zero, each with room for its size.
    private static func stack(_ radii: [Float]) -> (positions: [Float], height: Float) {
        let slots = radii.map { max(26, 2 * $0 + 10) }
        let height = slots.reduce(0, +)
        var cursor = height / 2
        var positions: [Float] = []
        for slot in slots {
            positions.append(cursor - slot / 2)
            cursor -= slot
        }
        return (positions, height)
    }

    /// A fixed order for edges, so the same scene is always drawn the same way.
    private static func edgeOrder(_ a: EdgeKey, _ b: EdgeKey) -> Bool {
        a.from != b.from ? remoteOrder(a.from, b.from) : remoteOrder(a.to, b.to)
    }

    /// Short text that identifies a node, for seeding an edge's pulse timing. Written out
    /// by hand: asking Swift to describe an enum is far slower, and this runs for every edge.
    private static func seed(_ id: NodeID) -> String {
        switch id {
        case .host: "host"
        case .process(let pid): "p\(pid)"
        case .endpoint(let address): address.description
        case .network(let address, let bits): "\(address)/\(bits)"
        case .group(let kind, let key): kind.rawValue + key
        case .service(let name): "s" + name
        case .marker(let number): "m\(number)"
        }
    }

    // MARK: - Flow

    static func flowScene(_ input: LayoutInput, born: (NodeID) -> Float) -> LayoutScene {
        var scene = LayoutScene()
        let columns: [Float] = [-430, -170, 110, 380]

        // Who owns the far end of each connection: the network's owner if a database
        // says, else the domain it was reached by, else its network.
        func destination(_ flow: Flow) -> (id: NodeID, label: String) {
            if let asn = flow.asn { return (.group(.asn, "\(asn)"), flow.org ?? "AS\(asn)") }
            if let host = flow.hostname {
                let domain = registeredDomain(host)
                return (.group(.domain, domain), domain)
            }
            let network = network(of: flow.key.remote.address)
            if case .network(let address, let bits) = network { return (network, "\(address)/\(bits)") }
            return (network, flow.key.remote.address.description)
        }

        // First pass: how much each process and each destination carries.
        var perProcess: [Int32: UInt64] = [:]
        var perDestination: [NodeID: UInt64] = [:]
        var total: UInt64 = 0
        for aggregate in input.byAddressEdge.values {
            for flow in aggregate.flows {
                perProcess[flow.pid, default: 0] &+= flow.bytesTotal
                perDestination[destination(flow).id, default: 0] &+= flow.bytesTotal
                total &+= flow.bytesTotal
            }
        }
        let keptProcesses = perProcess.keys.sorted { (perProcess[$0]!, $1) > (perProcess[$1]!, $0) }.prefix(flowProcessLimit)
        let keptSet = Set(keptProcesses)
        let orderedDestinations = perDestination.keys.sorted { a, b in
            perDestination[a]! != perDestination[b]! ? perDestination[a]! > perDestination[b]! : remoteOrder(a, b)
        }
        let keptDestinations = Set(orderedDestinations.prefix(flowDestinationLimit))
        let otherProcesses = NodeID.group(.rest, "processes"), otherDestinations = NodeID.group(.rest, "destinations")

        // Second pass: the three sets of nodes and the two sets of ribbons between them.
        var near: [NodeID: Aggregate] = [:]
        var services: [String: Aggregate] = [:]
        var far: [NodeID: Aggregate] = [:]
        var left: [EdgeKey: Aggregate] = [:]
        var right: [EdgeKey: Aggregate] = [:]
        var members: [NodeID: Set<IPAddress>] = [:]
        for aggregate in input.byAddressEdge.values {
            for flow in aggregate.flows {
                let life = flow.state == .closed ? aggregate.life : 1
                let from: NodeID = keptSet.contains(flow.pid) ? .process(flow.pid) : otherProcesses
                let service = flow.service ?? "Other"
                var (to, label) = destination(flow)
                if !keptDestinations.contains(to) { (to, label) = (otherDestinations, "other destinations") }
                scene.labels[to] = label
                scene.nodeFor[flow.key.remote.address] = to
                members[to, default: []].insert(flow.key.remote.address)
                near[from, default: Aggregate()].add(flow, life: life)
                services[service, default: Aggregate()].add(flow, life: life)
                far[to, default: Aggregate()].add(flow, life: life)
                left[EdgeKey(from: from, to: .service(service)), default: Aggregate()].add(flow, life: life)
                right[EdgeKey(from: .service(service), to: to), default: Aggregate()].add(flow, life: life)
            }
        }
        scene.labels[otherProcesses] = "other processes"
        for (id, addresses) in members {
            scene.members[id] = addresses.sorted { a, b in a.networkBytes.lexicographicallyPrecedes(b.networkBytes) }
        }

        let whole = Double(max(total, 1))
        func share(_ aggregate: Aggregate) -> Float { Float(Double(aggregate.bytes) / whole) }
        func radius(_ aggregate: Aggregate) -> Float { 4 + 15 * share(aggregate).squareRoot() }
        func bySize(_ a: (key: NodeID, value: Aggregate), _ b: (key: NodeID, value: Aggregate)) -> Bool {
            // What was folded together always goes last, however large it is.
            let restA: Bool, restB: Bool
            if case .group(.rest, _) = a.key { restA = true } else { restA = false }
            if case .group(.rest, _) = b.key { restB = true } else { restB = false }
            if restA != restB { return restB }
            return a.value.bytes != b.value.bytes ? a.value.bytes > b.value.bytes : remoteOrder(a.key, b.key)
        }

        scene.nodes.append(Node(
            id: .host, position: input.previous[.host]?.position ?? .zero, anchor: SIMD2(columns[0], 0), radius: 13,
            color: input.scheme.host, intensity: 1, bornAt: -100, label: input.hostLabel, priority: .infinity, labelSide: 0))

        var tallest: Float = 0
        let nearOrdered = near.sorted(by: bySize)
        let nearStack = stack(nearOrdered.map { radius($0.value) })
        tallest = max(tallest, nearStack.height)
        for (offset, entry) in nearOrdered.enumerated() {
            let anchor = SIMD2(columns[1], nearStack.positions[offset])
            if case .process(let pid) = entry.key {
                scene.nodes.append(processNode(
                    input, pid: pid, aggregate: entry.value, anchor: anchor, radius: radius(entry.value), bornAt: born(entry.key)))
                scene.processCount += 1
            } else {
                scene.nodes.append(Node(
                    id: entry.key, position: input.previous[entry.key]?.position ?? anchor, anchor: anchor,
                    radius: radius(entry.value), color: Palette.process, intensity: 0.4, bornAt: born(entry.key),
                    label: "\(perProcess.count - keptSet.count) other processes", priority: 1e14, labelSide: -1))
            }
        }

        let serviceOrdered = services.sorted { ($0.value.bytes, $1.key) > ($1.value.bytes, $0.key) }
        let serviceStack = stack(serviceOrdered.map { radius($0.value) + 4 })
        tallest = max(tallest, serviceStack.height)
        for (offset, entry) in serviceOrdered.enumerated() {
            let id = NodeID.service(entry.key)
            let anchor = SIMD2(columns[2], serviceStack.positions[offset])
            scene.nodes.append(Node(
                id: id, position: input.previous[id]?.position ?? SIMD2(anchor.x, 0), anchor: anchor, radius: radius(entry.value),
                color: input.scheme.color(forService: entry.key),
                intensity: 0.45 + 0.5 * level(entry.value.rate, scale: 6.5), bornAt: born(id), label: entry.key,
                priority: 1e12 + Double(entry.value.bytes), labelSide: 1))
            scene.nodeAggregates[id] = entry.value
        }

        let farOrdered = far.sorted(by: bySize)
        let farStack = stack(farOrdered.map { radius($0.value) })
        tallest = max(tallest, farStack.height)
        for (offset, entry) in farOrdered.enumerated() {
            let anchor = SIMD2(columns[3], farStack.positions[offset])
            let tagged = entry.value.flows.first?.tags.compactMap { input.tagColors[$0] }.first
            let count = scene.members[entry.key]?.count ?? 1
            let text = clip(scene.labels[entry.key] ?? "", to: 34) + (count > 1 ? " ×\(count)" : "")
            scene.nodes.append(Node(
                id: entry.key, position: input.previous[entry.key]?.position ?? SIMD2(anchor.x * 0.6, anchor.y), anchor: anchor,
                radius: radius(entry.value), color: tagged ?? input.scheme.color(forService: entry.value.service),
                intensity: (0.35 + 0.6 * level(entry.value.rate, scale: 6.5)) * Float(max(entry.value.life, 0.2)),
                bornAt: born(entry.key), label: text, priority: 2 + Double(entry.value.bytes), labelSide: 1))
            scene.nodeAggregates[entry.key] = entry.value
        }
        if let rest = near[otherProcesses] { scene.nodeAggregates[otherProcesses] = rest }

        var lookup: [NodeID: Int] = [:]
        for (offset, node) in scene.nodes.enumerated() { lookup[node.id] = offset }
        func ribbon(_ from: NodeID, _ to: NodeID, _ aggregate: Aggregate, color: SIMD3<Float>, trunk: Bool) {
            guard let a = lookup[from], let b = lookup[to] else { return }
            var edge = edge(
                from: a, to: b, target: .edge(from, to), aggregate: aggregate, color: color, seed: seed(from) + " " + seed(to), bend: 0,
                outbound: aggregate.rateOut >= aggregate.rateIn, trunk: trunk)
            // Width is the share of everything on screen that this ribbon carries.
            edge.halfWidth = 0.6 + 15 * pow(share(aggregate), 0.75)
            edge.glow = max(edge.glow * 0.6, 0.04 + 0.1 * share(aggregate).squareRoot())
            // A wide ribbon says enough by its width; its pulses are kept faint.
            edge.pulse *= 0.55 / (1 + edge.halfWidth / 5)
            edge.density = 1
            scene.edges.append(edge)
        }
        for entry in nearOrdered { ribbon(.host, entry.key, entry.value, color: input.scheme.trunk, trunk: true) }
        for key in left.keys.sorted(by: edgeOrder) {
            guard case .service(let service) = key.to else { continue }
            ribbon(key.from, key.to, left[key]!, color: input.scheme.color(forService: service), trunk: false)
        }
        for key in right.keys.sorted(by: edgeOrder) {
            guard case .service(let service) = key.from else { continue }
            ribbon(key.from, key.to, right[key]!, color: input.scheme.color(forService: service), trunk: false)
        }
        scene.edgeAggregates = left.merging(right) { first, _ in first }
        // With few rows the columns are spread to use the height a window has.
        let halfWidth: Float = 660
        let wanted = halfWidth * 0.56 - 70
        let stretch = min(2.4, max(1, wanted * 2 / max(tallest, 1)))
        for offset in scene.nodes.indices.dropFirst() {
            scene.nodes[offset].anchor.y *= stretch
            if input.previous[scene.nodes[offset].id] == nil { scene.nodes[offset].position.y *= stretch }
        }
        scene.halfSize = SIMD2(halfWidth, max(wanted + 70, tallest * stretch / 2 + 70))
        return scene
    }

    // MARK: - Lanes

    static func lanesScene(_ input: LayoutInput, born: (NodeID) -> Float) -> LayoutScene {
        var scene = LayoutScene()
        let leftEdge: Float = -400, rightEdge: Float = 580, spacing: Float = 30
        let window = max(input.window, 1)
        let start = input.now - window
        func x(_ time: EngineTime) -> Float {
            leftEdge + Float(min(max((time - start) / window, 0), 1)) * (rightEdge - leftEdge)
        }

        // The busiest processes get lanes; names decide the order, so a lane stays put.
        let chosen = input.byProcess.keys.sorted { a, b in
            let x = input.byProcess[a]!, y = input.byProcess[b]!
            return (x.open, x.bytes, b) > (y.open, y.bytes, a)
        }.prefix(laneLimit)
        func name(_ pid: Int32) -> String { (input.processes[pid]?.name ?? "pid \(pid)").lowercased() }
        let pids = chosen.sorted { (name($0), $0) < (name($1), $1) }
        let top = Float(pids.count - 1) / 2 * spacing
        let bottom = -top

        scene.nodes.append(Node(
            id: .host, position: input.previous[.host]?.position ?? .zero, anchor: SIMD2(leftEdge - 26, top + 48), radius: 5,
            color: input.scheme.host, intensity: 1, bornAt: -100, label: input.hostLabel, priority: .infinity, labelSide: 1))

        var budget = barLimit
        for (row, pid) in pids.enumerated() {
            let aggregate = input.byProcess[pid]!
            let y = top - Float(row) * spacing
            scene.nodes.append(processNode(
                input, pid: pid, aggregate: aggregate, anchor: SIMD2(leftEdge - 26, y), radius: 7, bornAt: born(.process(pid))))
            // A faint rule along the lane.
            scene.bars.append(Bar(from: SIMD2(leftEdge, y), to: SIMD2(rightEdge, y), target: nil, halfWidth: 0.35, glow: 0.012, color: Palette.trunk))

            // A lane with hundreds of bars gets dimmer ones, so it reads as texture, not as a white block.
            let crowd = Float(aggregate.flows.count { ($0.closedAt ?? input.now) >= start })
            let dimming = min(1, pow(6 / max(crowd, 1), 0.7))
            for flow in aggregate.flows.sorted(by: { $0.id < $1.id }) {
                let ended = flow.closedAt
                let last = ended ?? input.now
                guard last >= start, budget > 0 else { continue }
                budget -= 1
                let remote = flow.key.remote
                let far = "\(remote.address):\(remote.port)"
                let offset = (unit(far, salt: 0x1A) - 0.5) * (spacing - 12)
                var from = SIMD2(x(flow.firstSeen), y + offset), to = SIMD2(x(last), y + offset)
                // Something that came and went in a moment is still worth a mark.
                if to.x - from.x < 3 { from.x = to.x - 3 }
                let rate = level(flow.rateTotal, scale: 6.5)
                let size = level(Double(flow.bytesTotal), scale: 9)
                let target: PickTarget = remote.address.isLoopback
                    ? .node(.process(pid)) : .edge(.process(pid), input.nodeFor[remote.address] ?? .endpoint(remote.address))
                // Pulses run the way most of the bytes are going: outward is left to right.
                let outbound = flow.rateOut >= flow.rateIn
                scene.bars.append(Bar(
                    from: outbound ? from : to, to: outbound ? to : from, target: target, pid: pid, halfWidth: 1.0 + 1.8 * size,
                    glow: (0.12 + 0.13 * rate + 0.06 * size) * (ended == nil ? 1 : 0.4) * dimming,
                    pulse: ended == nil && rate > 0.02 ? (0.2 + 0.5 * rate) * max(dimming, 0.35) : 0, speed: 0.16 + 0.85 * rate,
                    color: input.scheme.color(forService: flow.service), phase: unit(far, salt: 0xD4)))
            }
        }
        scene.processCount = pids.count

        // The time axis: a rule and a label at each round interval back from now.
        let steps: [Double] = [5, 10, 30, 60, 120, 300, 600, 1800, 3600, 7200]
        let step = steps.first { window / $0 <= 8 } ?? 7200
        var mark = 0
        while Double(mark) * step <= window {
            let back = Double(mark) * step
            let position = x(input.now - back)
            let text: String
            if mark == 0 {
                text = "now"
            } else if back < 60 {
                text = "−\(Int(back))s"
            } else if back < 3600 {
                text = "−\(Int(back / 60))m"
            } else {
                text = String(format: "−%.0fh", back / 3600)
            }
            let id = NodeID.marker(mark)
            let anchor = SIMD2(position, bottom - 30)
            scene.nodes.append(Node(
                id: id, position: anchor, anchor: anchor, radius: 0.6, color: Palette.secondaryText, intensity: 0.3, bornAt: -100,
                label: text, priority: 1e11 - Double(mark), labelSide: 0))
            scene.bars.append(Bar(
                from: SIMD2(position, top + 16), to: SIMD2(position, bottom - 22), target: nil, halfWidth: 0.4,
                glow: mark == 0 ? 0.07 : 0.022, color: mark == 0 ? input.scheme.host : Palette.trunk))
            mark += 1
        }

        // A connection's bar answers to the same edge the constellation would draw.
        scene.edgeAggregates = input.links
        scene.halfSize = SIMD2(640, max(220, top + 100))
        return scene
    }
}
