import Foundation
import SwitchboardCore
import simd

public enum NodeID: Hashable, Sendable {
    case host
    case process(Int32)
    case endpoint(IPAddress)
    /// Several addresses in one network, drawn as a single node.
    case network(IPAddress, bits: Int)
    /// Destinations grouped by who owns their network, or by country.
    case group(GroupKind, String)
}

public enum GroupKind: String, Hashable, Sendable {
    /// Keyed by network number, as text.
    case asn
    /// Keyed by two-letter country code.
    case country
}

public enum PickTarget: Hashable, Sendable {
    case node(NodeID)
    /// Host to process, process to a destination, or process to process for local connections.
    case edge(NodeID, NodeID)

    /// The line from this Mac to a process.
    var isTrunk: Bool {
        if case .edge(.host, _) = self { return true }
        return false
    }
}

/// When destinations are merged into one node per network (docs/SPEC.md §10.1).
public enum Clustering: Sendable, Equatable {
    case off
    /// Always merge addresses that share a network.
    case subnet
    /// Merge only once there are more destinations than this.
    case automatic(threshold: Int)
    /// One node per network owner. Needs an ASN database.
    case owner
    /// One node per country. Needs a location database.
    case country
}

/// What the tooltip and inspector show for a node or edge.
public struct HoverInfo: Sendable, Equatable {
    public struct Row: Sendable, Equatable, Identifiable {
        public var label: String
        public var value: String
        public var id: String { label }

        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    public var title: String
    public var subtitle: String
    public var rows: [Row]
    public var footnote: String?

    public init(title: String, subtitle: String, rows: [Row], footnote: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.rows = rows
        self.footnote = footnote
    }
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
        /// Sideways curvature, as a fraction of the edge's length.
        var bend: Float
        /// How far the middle of the edge is drawn toward the centre, 0 to 1.
        var pull: Float = 0

        func control(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> SIMD2<Float> {
            let along = b - a
            return (a + b) * 0.5 * (1 - pull) + SIMD2(-along.y, along.x) * bend
        }
    }

    private struct EdgeKey: Hashable {
        var from: NodeID
        var to: NodeID
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
        /// Hostnames seen on these flows, how many flows carry each, and where each came from.
        var names: [String: Int] = [:]
        var nameSources: [String: NameSource] = [:]
        var flows: [Flow] = []

        var rate: Double { rateIn + rateOut }
        var bytes: UInt64 { bytesIn &+ bytesOut }
        var service: String? { services.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key }
        /// The name most of these flows go by.
        var name: String? { names.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key }

        mutating func add(_ flow: Flow, life flowLife: Double) {
            rateIn += flow.rateIn
            rateOut += flow.rateOut
            bytesIn &+= flow.bytesIn
            bytesOut &+= flow.bytesOut
            total += 1
            if flow.state != .closed { open += 1 }
            life = max(life, flowLife)
            if let service = flow.service { services[service, default: 0] += 1 }
            if let name = flow.hostname {
                names[name, default: 0] += 1
                nameSources[name] = flow.hostnameSource
            }
            flows.append(flow)
        }

        mutating func merge(_ other: Aggregate) {
            rateIn += other.rateIn
            rateOut += other.rateOut
            bytesIn &+= other.bytesIn
            bytesOut &+= other.bytesOut
            open += other.open
            total += other.total
            life = max(life, other.life)
            services.merge(other.services, uniquingKeysWith: +)
            names.merge(other.names, uniquingKeysWith: +)
            nameSources.merge(other.nameSources) { first, _ in first }
            flows.append(contentsOf: other.flows)
        }
    }

    private let lock = NSLock()
    /// Serialises rebuilds, which run outside `lock` so they never hold up a frame.
    private let buildLock = NSLock()
    private let hostLabel: String
    private var nodes: [Node] = []
    private var edges: [Edge] = []
    private var index: [NodeID: Int] = [:]
    private var settled = false
    private var arrivals: [NodeID: (bornAt: Float, lastSeen: Float)] = [:]
    private var extent: Float = 420
    /// Nodes are stored host first, then this many processes, then destinations.
    private var processCount = 0

    // Kept from the last rebuild for tooltips and the inspector.
    private var nodeAggregates: [NodeID: Aggregate] = [:]
    private var edgeAggregates: [EdgeKey: Aggregate] = [:]
    private var networkMembers: [NodeID: [IPAddress]] = [:]
    private var groupLabels: [NodeID: String] = [:]
    private var nodeForAddress: [IPAddress: NodeID] = [:]
    private var processes: [Int32: ProcessRecord] = [:]
    private var listeners: [Int32: [Listener]] = [:]
    private var snapshotTime: EngineTime = 0

    // What to draw, and how.
    private var liveSnapshot: EngineSnapshot?
    private var liveTime: Float = 0
    /// A moment from the past being shown instead of the present.
    private var heldSnapshot: EngineSnapshot?
    private var activeFilter = FlowFilter.all
    private var focusTarget: PickTarget?
    private var clusteringMode = Clustering.automatic(threshold: 300)
    private var expanded = Set<NodeID>()
    private var scheme = PaletteScheme.standard
    private var keepEnded = false
    private var showNames = true
    private var tagColors: [String: SIMD3<Float>] = [:]
    /// Destinations the log had never seen before, and the animation time each was noticed.
    private var novel: [IPAddress: Float] = [:]
    /// How long a never-seen-before destination keeps its ring.
    public static let novelSeconds: Float = 90
    /// Connections that have ended, remembered while `keepsEnded` is on.
    private var ended: [FlowID: (flow: Flow, process: ProcessRecord?)] = [:]

    /// How bright an ended connection stays, as a fraction of a live one.
    static let endedLife = 0.22
    /// At most this many ended connections are remembered; the oldest go first.
    public static let endedLimit = 3000

    /// Closed flows linger this long before leaving the graph.
    public static let fadeSeconds = 6.0

    public init(hostLabel: String = "THIS MAC") {
        self.hostLabel = hostLabel
    }

    // MARK: - What to show

    /// The engine's current model. Ignored for display while a past moment is held, but
    /// remembered, so returning to the present is immediate.
    public func update(_ snapshot: EngineSnapshot, time: Float) {
        lock.lock()
        liveSnapshot = snapshot
        liveTime = time
        lock.unlock()
        redraw(onlyIfLive: true)
    }

    /// Shows a past moment instead of the present; `nil` returns to the present.
    public func hold(_ snapshot: EngineSnapshot?) {
        lock.withLock { heldSnapshot = snapshot }
        redraw()
    }

    /// While true the picture holds at the moment it was paused. Collection carries on.
    public var paused: Bool {
        get { lock.withLock { heldSnapshot != nil } }
        set {
            lock.withLock { heldSnapshot = newValue ? (heldSnapshot ?? liveSnapshot) : nil }
            if !newValue { redraw() }
        }
    }

    /// Only flows matching the filter are drawn. Takes effect at once, even while paused.
    public var filter: FlowFilter {
        get { lock.withLock { activeFilter } }
        set { change { activeFilter = newValue } }
    }

    public var clustering: Clustering {
        get { lock.withLock { clusteringMode } }
        set { change { clusteringMode = newValue } }
    }

    public var palette: PaletteScheme {
        get { lock.withLock { scheme } }
        set { change { scheme = newValue } }
    }

    /// When on, connections that have ended stay on the graph, subdued, instead of
    /// fading away. Remembering starts when this is turned on and is forgotten when it is
    /// turned off.
    public var keepsEnded: Bool {
        get { lock.withLock { keepEnded } }
        set {
            change {
                keepEnded = newValue
                if !newValue { ended.removeAll() }
            }
        }
    }

    /// Whether destinations are labelled with hostnames where they are known, or always
    /// with addresses.
    public var showsHostnames: Bool {
        get { lock.withLock { showNames } }
        set { change { showNames = newValue } }
    }

    /// Marks destinations as never seen before in any earlier session. They carry a
    /// bright ring for a while (docs/SPEC.md §9.4).
    public func markFirstSeen(_ addresses: [IPAddress], time: Float) {
        change {
            for address in addresses { novel[address] = time }
            if novel.count > 2000 { novel.removeAll() }
        }
    }

    /// Colours for the user's address lists; a destination on a coloured list takes its colour.
    public func setTagColors(_ colors: [String: SIMD3<Float>]) {
        change { tagColors = colors }
    }

    /// How many ended connections are being kept on screen.
    public var endedCount: Int { lock.withLock { ended.count } }

    /// Forgets the ended connections without leaving the mode.
    public func clearEnded() {
        change { ended.removeAll() }
    }

    /// Opens a network node into its individual addresses, or closes it again.
    public func toggleExpansion(of node: NodeID) {
        // An address may have come out of its owner's or its country's node rather than a network.
        let example = flows(for: .node(node)).first
        change {
            switch node {
            case .network, .group:
                expanded.insert(node)
            case .endpoint(let address):
                expanded.remove(Self.network(of: address))
                if let asn = example?.asn { expanded.remove(.group(.asn, "\(asn)")) }
                if let country = example?.country { expanded.remove(.group(.country, country)) }
            default:
                break
            }
        }
    }

    /// Focus mode: everything not connected to this target is dimmed almost to nothing.
    public var focus: PickTarget? {
        get { lock.withLock { focusTarget } }
        set { lock.withLock { focusTarget = newValue } }
    }

    private func change(_ body: () -> Void) {
        lock.withLock(body)
        redraw()
    }

    /// Rebuilds the scene from whatever should be on screen. The work happens outside
    /// `lock`: on a busy machine it takes tens of milliseconds, and a frame waiting on
    /// the lock for that long is a visible stutter.
    private func redraw(onlyIfLive: Bool = false) {
        buildLock.lock()
        defer { buildLock.unlock() }
        let (snapshot, time): (EngineSnapshot?, Float) = lock.withLock {
            if onlyIfLive, heldSnapshot != nil { return (nil, liveTime) }
            return (heldSnapshot ?? liveSnapshot, liveTime)
        }
        if let snapshot { rebuild(snapshot, time: time) }
    }

    /// The network a destination is grouped into: /24 for IPv4, /48 for IPv6.
    static func network(of address: IPAddress) -> NodeID {
        switch address {
        case .v4(let value): .network(.v4(value & 0xffff_ff00), bits: 24)
        case .v6(let hi, _): .network(.v6(hi: hi & 0xffff_ffff_ffff_0000, lo: 0), bits: 48)
        }
    }

    // MARK: - Building the scene

    private struct AddressEdge: Hashable {
        var pid: Int32
        var address: IPAddress
    }

    private struct PeerEdge: Hashable {
        var from: Int32
        var to: Int32
    }

    private struct PortKey: Hashable {
        var proto: TransportProtocol
        var port: UInt16
    }

    private func rebuild(_ snapshot: EngineSnapshot, time: Float) {
        var processes = Dictionary(uniqueKeysWithValues: snapshot.processes.map { ($0.pid, $0) })
        let listeners = Dictionary(grouping: snapshot.listeners, by: \.pid)

        // Take what is needed from shared state, then let go of the lock for the heavy part.
        lock.lock()
        let filter = activeFilter
        let clusteringMode = self.clusteringMode
        let expanded = self.expanded
        let scheme = self.scheme
        var arrivals = self.arrivals
        let keepEnded = self.keepEnded
        let showNames = self.showNames
        let tagColors = self.tagColors
        let novel = self.novel.filter { time - $0.value < Self.novelSeconds }
        var ended = self.ended
        let previous = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        lock.unlock()

        // Who is listening on each local port, to pair up connections within this Mac.
        var listening: [PortKey: Int32] = [:]
        for listener in snapshot.listeners {
            let key = PortKey(proto: listener.proto, port: listener.local.port)
            if let current = listening[key], current <= listener.pid { continue }
            listening[key] = listener.pid
        }

        var byProcess: [Int32: Aggregate] = [:]
        var byAddress: [IPAddress: Aggregate] = [:]
        var byAddressEdge: [AddressEdge: Aggregate] = [:]
        var byPeer: [PeerEdge: Aggregate] = [:]
        // With "keep ended" on, closed connections are remembered as they go by, and the
        // ones the engine has since forgotten are drawn from that memory.
        var shown = snapshot.flows
        if keepEnded {
            var present = Set<FlowID>()
            present.reserveCapacity(snapshot.flows.count)
            for flow in snapshot.flows {
                present.insert(flow.id)
                if flow.state == .closed { ended[flow.id] = (flow, processes[flow.pid]) }
            }
            if ended.count > Self.endedLimit {
                let oldest = ended.values.sorted { ($0.flow.closedAt ?? 0, $0.flow.id) < ($1.flow.closedAt ?? 0, $1.flow.id) }
                for entry in oldest.prefix(ended.count - Self.endedLimit) { ended[entry.flow.id] = nil }
            }
            for entry in ended.values.sorted(by: { $0.flow.id < $1.flow.id }) where !present.contains(entry.flow.id) {
                // Looking at the past, something that had not ended yet is not shown as ended.
                guard (entry.flow.closedAt ?? 0) <= snapshot.time else { continue }
                shown.append(entry.flow)
                if processes[entry.flow.pid] == nil, let process = entry.process { processes[entry.flow.pid] = process }
            }
        }

        for flow in shown {
            if !filter.isEmpty, !filter.matches(flow, process: processes[flow.pid], now: snapshot.time) { continue }
            var life = 1.0
            if flow.state == .closed {
                life = 1 - (snapshot.time - (flow.closedAt ?? snapshot.time)) / Self.fadeSeconds
                if keepEnded {
                    // Subdued, but it stays.
                    life = max(life, Self.endedLife)
                } else if life <= 0 {
                    continue
                }
            }
            byProcess[flow.pid, default: Aggregate()].add(flow, life: life)

            let remote = flow.key.remote
            if remote.address.isLoopback {
                // This Mac talking to itself. If we can tell which process is listening on
                // the far port, draw a line between the two processes; either way there is
                // no "127.0.0.1" node, which would pull lines from all over the graph.
                if let peer = listening[PortKey(proto: flow.key.proto, port: remote.port)], peer != flow.pid {
                    byPeer[PeerEdge(from: flow.pid, to: peer), default: Aggregate()].add(flow, life: life)
                }
                continue
            }
            byAddress[remote.address, default: Aggregate()].add(flow, life: life)
            byAddressEdge[AddressEdge(pid: flow.pid, address: remote.address), default: Aggregate()].add(flow, life: life)
        }

        // Clustering: addresses sharing a network become one node.
        let clusteringActive: Bool
        switch clusteringMode {
        case .off: clusteringActive = false
        case .subnet: clusteringActive = true
        case .automatic(let threshold): clusteringActive = byAddress.count > threshold
        case .owner, .country: clusteringActive = false
        }
        var nodeFor: [IPAddress: NodeID] = [:]
        var members: [NodeID: [IPAddress]] = [:]
        var groupLabels: [NodeID: String] = [:]
        if clusteringMode == .owner || clusteringMode == .country {
            // Every destination the database knows about joins its owner's or country's
            // node; the rest stay as they are.
            for (address, aggregate) in byAddress {
                guard let flow = aggregate.flows.first else { continue }
                let id: NodeID
                if clusteringMode == .owner {
                    guard let asn = flow.asn else { continue }
                    id = .group(.asn, "\(asn)")
                    groupLabels[id] = flow.org.map { "\($0) (AS\(asn))" } ?? "AS\(asn)"
                } else {
                    guard let country = flow.country else { continue }
                    id = .group(.country, country)
                    groupLabels[id] = Locale.current.localizedString(forRegionCode: country).map { "\($0) (\(country))" } ?? country
                }
                guard !expanded.contains(id) else { continue }
                nodeFor[address] = id
                members[id, default: []].append(address)
            }
            for id in members.keys { members[id]?.sort(by: Self.addressOrder) }
        }
        if clusteringActive {
            for (network, addresses) in Dictionary(grouping: byAddress.keys, by: Self.network(of:))
            where addresses.count >= 2 && !expanded.contains(network) {
                for address in addresses { nodeFor[address] = network }
                members[network] = addresses.sorted(by: Self.addressOrder)
            }
        }

        var remotes: [NodeID: Aggregate] = [:]
        for (address, aggregate) in byAddress {
            remotes[nodeFor[address] ?? .endpoint(address), default: Aggregate()].merge(aggregate)
        }
        var links: [EdgeKey: Aggregate] = [:]
        for (key, aggregate) in byAddressEdge {
            let to = nodeFor[key.address] ?? .endpoint(key.address)
            links[EdgeKey(from: .process(key.pid), to: to), default: Aggregate()].merge(aggregate)
        }
        // A local connection is drawn only when both of its processes are in view.
        var peers: [EdgeKey: Aggregate] = [:]
        for (key, aggregate) in byPeer where byProcess[key.to] != nil {
            peers[EdgeKey(from: .process(key.from), to: .process(key.to))] = aggregate
        }

        // When did each node first appear? Remembered for a minute after it leaves, so a
        // process that reconnects every few seconds is not announced as new each time.
        func born(_ id: NodeID) -> Float {
            let at = arrivals[id]?.bornAt ?? time
            arrivals[id] = (at, time)
            return at
        }

        var built: [Node] = []
        built.reserveCapacity(byProcess.count + remotes.count + 1)

        // This Mac, at the centre.
        built.append(Node(
            id: .host, position: .zero, anchor: .zero, radius: 15, color: scheme.host, intensity: 1,
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
                // A process whose connections have all ended is dimmer than one that is merely quiet.
                color: Palette.process,
                intensity: (0.34 + 0.5 * Self.level(aggregate.rate, scale: 6.5) * Float(aggregate.life)) * Float(0.45 + 0.55 * aggregate.life),
                bornAt: born(id), label: Self.clip(record?.name ?? "pid \(pid)", to: 22),
                priority: 1e15 + aggregate.rate, iconPath: record?.path)
            // The ring is the trust signal (docs/SPEC.md §9.4): red for a program that is
            // unsigned or whose signature does not verify, amber for one signed by nobody
            // in particular or listening where other machines can reach it.
            switch record?.signing {
            case .unsigned, .invalid: node.ring = SIMD4(Palette.attention, 1)
            case .adHoc: node.ring = SIMD4(scheme.remoteAccess, 0.85)
            default: if exposed { node.ring = SIMD4(scheme.remoteAccess, 0.85) }
            }
            built.append(node)
        }

        // Destinations beyond the ring, each in the sector of the process that uses it most.
        var owner: [NodeID: (pid: Int32, bytes: UInt64)] = [:]
        var destinationCount: [Int32: Int] = [:]
        for (key, aggregate) in links {
            guard case .process(let pid) = key.from else { continue }
            destinationCount[pid, default: 0] += 1
            if let current = owner[key.to], (current.bytes, -Int64(current.pid)) >= (aggregate.bytes, -Int64(pid)) { continue }
            owner[key.to] = (pid, aggregate.bytes)
        }
        var owned: [Int32: Int] = [:]
        for entry in owner.values { owned[entry.pid, default: 0] += 1 }

        var farthest = ringRadius
        for id in remotes.keys.sorted(by: Self.remoteOrder) {
            let aggregate = remotes[id]!
            guard let ownerPID = owner[id]?.pid else { continue }
            let count = Float(owned[ownerPID] ?? 1)
            let size = members[id]?.count ?? 1
            let text: String
            switch id {
            case .network(let address, let bits): text = "\(address)/\(bits)"
            case .endpoint(let address): text = address.description
            case .group: text = groupLabels[id] ?? ""
            default: text = ""
            }
            let fan = min(1.5, sector * 0.85 + 0.05 * count.squareRoot())
            let angle = (processAngle[ownerPID] ?? 0) + (Self.unit(text, salt: 0xA1) - 0.5) * fan
            let radius = ringRadius + 170 + Self.unit(text, salt: 0xB2) * (130 + 30 * count.squareRoot())
            farthest = max(farthest, radius)
            let anchor = SIMD2(cos(angle), sin(angle)) * radius
            let start = previous[.process(ownerPID)]?.position ?? SIMD2(cos(angle), sin(angle)) * ringRadius
            // A destination on one of the user's coloured lists takes that colour.
            let tagged = aggregate.flows.first?.tags.compactMap { tagColors[$0] }.first
            let color = tagged ?? scheme.color(forService: aggregate.service)
            let isGroup: Bool
            if case .group = id { isGroup = true } else { isGroup = false }
            var node = Node(
                id: id, position: previous[id]?.position ?? start, anchor: anchor,
                radius: 2.6 + 6 * Self.level(Double(aggregate.bytes), scale: 9) + (size > 1 ? 2 + min(4, log2(Float(size))) : 0),
                color: color,
                intensity: (0.3 + 0.7 * Self.level(aggregate.rate, scale: 6.5)) * Float(max(aggregate.life, 0.15)),
                // Placement is seeded from the address, so naming a node never moves it.
                bornAt: born(id),
                label: isGroup ? "\(Self.clip(text, to: 34)) ×\(size)" : (size > 1 ? "\(text) ×\(size)" : (showNames ? aggregate.name.map { Self.clip($0, to: 36) } : nil) ?? text),
                priority: aggregate.rate + Double(aggregate.bytes) * 1e-9)
            // A ring marks a node that stands for several addresses.
            if size > 1 || isGroup { node.ring = SIMD4(color, 0.55) }
            // A brighter one marks a destination this Mac has never talked to before.
            if case .endpoint(let address) = id, novel[address] != nil {
                node.ring = SIMD4(0.85, 1, 1, 1)
                node.intensity = max(node.intensity, 0.9)
                node.priority += 1e9
            }
            built.append(node)
        }

        var lookup: [NodeID: Int] = [:]
        lookup.reserveCapacity(built.count)
        for (offset, node) in built.enumerated() { lookup[node.id] = offset }

        var drawn: [Edge] = []
        drawn.reserveCapacity(links.count + pids.count + peers.count)
        for pid in pids {
            guard let to = lookup[.process(pid)], let aggregate = byProcess[pid] else { continue }
            drawn.append(Self.edge(
                from: 0, to: to, target: .edge(.host, .process(pid)), aggregate: aggregate, color: scheme.trunk,
                seed: "trunk \(pid)", bend: 0, outbound: aggregate.rateOut >= aggregate.rateIn, trunk: true))
        }
        let orderedLinks = links.keys.sorted { a, b in
            a.from != b.from ? Self.remoteOrder(a.from, b.from) : Self.remoteOrder(a.to, b.to)
        }
        for key in orderedLinks {
            guard let aggregate = links[key], let process = lookup[key.from], let remote = lookup[key.to],
                  case .process(let pid) = key.from
            else { continue }
            // The seed fixes each edge's curve and pulse timing; it is spelled the same way
            // for a plain address as it always has been, so existing pictures do not shift.
            let far: String
            switch key.to {
            case .endpoint(let address): far = address.description
            case .network(let address, let bits): far = "\(address)/\(bits)"
            case .group(let kind, let key): far = "\(kind.rawValue) \(key)"
            default: far = ""
            }
            let seed = "\(pid) \(far)"
            // A process with many destinations gets dimmer edges, so a fan of hundreds
            // reads as a texture rather than burning out to white.
            let crowd = Float(destinationCount[pid] ?? 1)
            drawn.append(Self.edge(
                from: process, to: remote, target: .edge(key.from, key.to), aggregate: aggregate,
                color: scheme.color(forService: aggregate.service), seed: seed,
                bend: (Self.unit(seed, salt: 0xC3) - 0.5) * 0.26, outbound: aggregate.rateOut >= aggregate.rateIn, trunk: false,
                dimming: min(1, pow(10 / max(crowd, 1), 0.6))))
        }
        // Local connections curve through the middle of the ring, from client to server.
        for key in peers.keys.sorted(by: { a, b in a.from != b.from ? Self.remoteOrder(a.from, b.from) : Self.remoteOrder(a.to, b.to) }) {
            guard let aggregate = peers[key], let from = lookup[key.from], let to = lookup[key.to] else { continue }
            var edge = Self.edge(
                from: from, to: to, target: .edge(key.from, key.to), aggregate: aggregate, color: scheme.local,
                seed: "\(key.from) \(key.to)", bend: 0, outbound: true, trunk: false)
            edge.pull = 0.55
            drawn.append(edge)
        }

        var aggregates = remotes
        for (pid, aggregate) in byProcess { aggregates[.process(pid)] = aggregate }
        let allEdges = links.merging(peers) { first, _ in first }
        let remembered = arrivals.filter { time - $0.value.lastSeen < 60 }

        lock.lock()
        defer { lock.unlock() }
        // The layout kept running while this was worked out; keep where nodes have got to.
        let current = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.position) })
        for offset in built.indices {
            if let position = current[built[offset].id] { built[offset].position = position }
        }
        self.processes = processes
        self.listeners = listeners
        snapshotTime = snapshot.time
        nodeAggregates = aggregates
        edgeAggregates = allEdges
        networkMembers = members
        self.groupLabels = groupLabels
        nodeForAddress = nodeFor
        processCount = pids.count
        self.arrivals = remembered
        self.novel = self.novel.filter { time - $0.value < Self.novelSeconds }
        // Unless the mode was switched off while this was being worked out.
        if self.keepEnded { self.ended = ended }
        nodes = built
        edges = drawn
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

    /// A stable order for nodes: processes by pid, destinations by address, a single
    /// address before the network that contains it.
    private static func remoteOrder(_ a: NodeID, _ b: NodeID) -> Bool {
        func key(_ id: NodeID) -> (Int, Int, UInt64, UInt64, Int) {
            switch id {
            case .host: return (0, 0, 0, 0, 0)
            case .process(let pid): return (1, 0, 0, UInt64(UInt32(bitPattern: pid)), 0)
            case .group(let kind, let key):
                // After every address, in a fixed order of their own.
                var hash: UInt64 = 0xcbf2_9ce4_8422_2325
                for byte in "\(kind.rawValue) \(key)".utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
                return (3, 0, 0, hash, 0)
            case .endpoint(let address), .network(let address, _):
                let isNetwork: Int
                if case .network = id { isNetwork = 1 } else { isNetwork = 0 }
                switch address {
                case .v4(let value): return (2, 0, 0, UInt64(value), isNetwork)
                case .v6(let hi, let lo): return (2, 1, hi, lo, isNetwork)
                }
            }
        }
        return key(a) < key(b)
    }

    // MARK: - Layout

    /// One relaxation step: every node drifts to its anchor while overlapping nodes push apart.
    public func step() {
        lock.lock()
        defer { lock.unlock() }
        guard !settled, nodes.count > 1 else { return }

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

    /// The current picture. `labelBudget` is how many destinations may carry a label;
    /// `highlights` are lit and their neighbours with them.
    public func frame(labelBudget: Int, highlights: Set<PickTarget> = []) -> RenderFrame {
        lock.lock()
        defer { lock.unlock() }
        var frame = RenderFrame()
        frame.extent = extent
        frame.nodes.reserveCapacity(nodes.count)
        frame.edges.reserveCapacity(edges.count)

        var highlightedNodes = Set<NodeID>()
        for case .node(let id) in highlights { highlightedNodes.insert(id) }

        // In focus mode, work out which nodes belong to the focused neighbourhood.
        var inFocus: Set<Int>?
        if let focusTarget {
            var members = Set<Int>()
            for edge in edges where Self.touches(edge, focusTarget, nodes) {
                members.insert(edge.from)
                members.insert(edge.to)
            }
            if case .node(let id) = focusTarget, let offset = index[id] { members.insert(offset) }
            // A focus that no longer exists dims nothing.
            if !members.isEmpty { inFocus = members }
        }

        for (offset, node) in nodes.enumerated() {
            var ring = node.ring
            var intensity = node.intensity
            if let inFocus, !inFocus.contains(offset) { intensity *= 0.18 }
            if highlightedNodes.contains(node.id) {
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
            var glow = edge.glow
            var pulse = edge.pulse
            var halfWidth = edge.halfWidth
            if let focusTarget, inFocus != nil, !Self.touches(edge, focusTarget, nodes) {
                glow *= 0.1
                pulse = 0
            }
            if !highlights.isEmpty {
                if highlights.contains(where: { Self.touches(edge, $0, nodes) }) {
                    glow = glow * 1.8 + 0.22
                    halfWidth += 0.6
                } else {
                    glow *= 0.45
                }
            }
            frame.edges.append(EdgeInstance(
                p0: a, p1: b, control: edge.control(a, b), halfWidth: halfWidth, phase: edge.phase,
                color: SIMD4(edge.color, 1), speed: edge.speed, density: edge.density, glow: glow, pulse: pulse))
        }

        // The host and every process are named; destinations compete for the remaining labels.
        if !nodes.isEmpty { frame.labels.append(LabelRequest(text: nodes[0].label, node: 0, kind: 0)) }
        let named = (1..<min(processCount + 1, nodes.count)).sorted { nodes[$0].priority > nodes[$1].priority }
        for offset in named.prefix(160) where inFocus?.contains(offset) ?? true {
            frame.labels.append(LabelRequest(text: nodes[offset].label, node: offset, kind: 1))
        }
        let destinations = nodes.indices.dropFirst(processCount + 1)
        var chosen = destinations.filter { nodes[$0].priority > 1 && (inFocus?.contains($0) ?? true) }
            .sorted { nodes[$0].priority > nodes[$1].priority }.prefix(labelBudget).map { $0 }
        for highlight in highlights {
            let far: NodeID?
            switch highlight {
            case .node(let id): far = id
            case .edge(_, let to): far = to
            }
            if let far, let offset = index[far], offset > processCount, !chosen.contains(offset) { chosen.append(offset) }
        }
        for offset in chosen {
            frame.labels.append(LabelRequest(text: nodes[offset].label, node: offset, kind: 2))
        }
        return frame
    }

    private static func touches(_ edge: Edge, _ target: PickTarget, _ nodes: [Node]) -> Bool {
        switch target {
        case .node(.host): edge.target.isTrunk
        case .node(let id): nodes[edge.from].id == id || nodes[edge.to].id == id
        case .edge: edge.target == target
        }
    }

    // MARK: - Looking things up

    /// The flows behind a node or edge, for the inspector.
    public func flows(for target: PickTarget) -> [Flow] {
        lock.lock()
        defer { lock.unlock() }
        return aggregate(for: target)?.flows ?? []
    }

    private func aggregate(for target: PickTarget) -> Aggregate? {
        switch target {
        case .node(.host):
            var all = Aggregate()
            for (id, aggregate) in nodeAggregates { if case .process = id { all.merge(aggregate) } }
            return all
        case .node(let id): return nodeAggregates[id]
        case .edge(.host, let process): return nodeAggregates[process]
        case .edge(let from, let to): return edgeAggregates[EdgeKey(from: from, to: to)]
        }
    }

    public func process(_ pid: Int32) -> ProcessRecord? {
        lock.withLock { processes[pid] }
    }

    /// The node or edge that currently represents a connection, allowing for clustering
    /// and for local connections drawn between processes.
    public func target(pid: Int32, remote: Endpoint, proto: TransportProtocol) -> PickTarget {
        lock.lock()
        defer { lock.unlock() }
        if remote.address.isLoopback {
            let peer = edgeAggregates.keys.first { key in
                guard key.from == .process(pid), case .process = key.to else { return false }
                return edgeAggregates[key]?.flows.contains { $0.key.remote == remote && $0.key.proto == proto } ?? false
            }
            return peer.map { .edge($0.from, $0.to) } ?? .node(.process(pid))
        }
        return .edge(.process(pid), nodeForAddress[remote.address] ?? .endpoint(remote.address))
    }

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
            let control = edge.control(a, b)
            var nearest = Float.infinity
            var previous = a
            for step in 1...12 {
                let t = SIMD2<Float>(repeating: Float(step) / 12)
                let next = simd_mix(simd_mix(a, control, t), simd_mix(control, b, t), t)
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
        guard let aggregate = aggregate(for: target) else { return nil }
        func name(_ pid: Int32) -> String { processes[pid]?.name ?? "pid \(pid)" }

        switch target {
        case .node(.host):
            let exposed = listeners.values.joined().filter(\.exposed).count
            let destinations = nodeAggregates.keys.count { if case .process = $0 { false } else { true } }
            return HoverInfo(
                title: hostLabel, subtitle: "\(processCount) processes on the network",
                rows: [
                    .init(label: "Connections", value: "\(aggregate.open)"),
                    .init(label: "Destinations", value: "\(destinations)"),
                    .init(label: "Rate", value: "↓ \(ByteFormat.rate(aggregate.rateIn))  ↑ \(ByteFormat.rate(aggregate.rateOut))"),
                    .init(label: "Listening", value: "\(listeners.values.joined().count) sockets, \(exposed) exposed"),
                ])

        case .node(.process(let pid)), .edge(.host, .process(let pid)):
            return processInfo(pid, aggregate)

        case .node(.endpoint(let address)):
            let users = Set(aggregate.flows.map(\.pid)).sorted().map(name)
            var rows = trafficRows(aggregate)
            rows.insert(.init(label: "Used by", value: Self.list(users)), at: 0)
            rows.insert(contentsOf: nameRows(aggregate) + Self.placeRows(aggregate), at: 0)
            return HoverInfo(
                title: aggregate.name ?? address.description,
                subtitle: aggregate.name == nil ? Self.classification(address) : "\(address) · \(Self.classification(address))",
                rows: rows, footnote: nil)

        case .node(.network(let address, let bits)):
            let addresses = networkMembers[.network(address, bits: bits)] ?? []
            let users = Set(aggregate.flows.map(\.pid)).sorted().map(name)
            var rows = trafficRows(aggregate)
            rows.insert(.init(label: "Used by", value: Self.list(users)), at: 0)
            rows.insert(.init(label: "Addresses", value: Self.list(addresses.map(\.description), limit: 3)), at: 1)
            rows.insert(contentsOf: nameRows(aggregate), at: 2)
            return HoverInfo(
                title: "\(address)/\(bits)", subtitle: "\(addresses.count) addresses in one network · \(Self.classification(address))",
                rows: rows, footnote: "Right-click to expand into separate addresses")

        case .node(.group(let kind, let key)):
            let id = NodeID.group(kind, key)
            let addresses = networkMembers[id] ?? []
            let users = Set(aggregate.flows.map(\.pid)).sorted().map(name)
            var rows = trafficRows(aggregate)
            rows.insert(.init(label: "Used by", value: Self.list(users)), at: 0)
            rows.insert(.init(label: "Addresses", value: Self.list(addresses.map(\.description), limit: 3)), at: 1)
            rows.insert(contentsOf: nameRows(aggregate), at: 2)
            return HoverInfo(
                title: groupLabels[id] ?? key,
                subtitle: "\(addresses.count) addresses · grouped by \(kind == .asn ? "network owner" : "country")",
                rows: rows, footnote: "Right-click to expand into separate addresses")

        case .edge(.process(let from), .process(let to)):
            var rows = trafficRows(aggregate)
            let ports = Set(aggregate.flows.map(\.key.remote.port)).sorted().map(String.init)
            rows.insert(.init(label: "Local port", value: Self.list(ports)), at: 0)
            return HoverInfo(
                title: "\(name(from)) → \(name(to))", subtitle: "pid \(from) to pid \(to) · within this Mac", rows: rows, footnote: nil)

        case .edge(.process(let pid), let remote):
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
            let far: String, kind: String
            switch remote {
            case .network(let address, let bits):
                far = "\(address)/\(bits)"
                kind = Self.classification(address)
            case .group(let groupKind, let key):
                far = groupLabels[.group(groupKind, key)] ?? key
                kind = groupKind == .asn ? "network owner" : "country"
            case .endpoint(let address):
                far = aggregate.name ?? address.description
                kind = aggregate.name == nil ? Self.classification(address) : "\(address) · \(Self.classification(address))"
            default:
                far = "?"
                kind = ""
            }
            rows.insert(contentsOf: nameRows(aggregate) + Self.placeRows(aggregate), at: 0)
            return HoverInfo(title: "\(name(pid)) → \(far)", subtitle: "pid \(pid) · \(kind)", rows: rows, footnote: nil)

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
        if let record {
            let signed: String
            switch record.signing {
            case .apple: signed = "Apple"
            case .developerID: signed = "an identified developer" + (record.teamID.map { " (team \($0))" } ?? "")
            case .adHoc: signed = "ad hoc — signed, but by no one in particular"
            case .unsigned: signed = "UNSIGNED"
            case .invalid: signed = "INVALID — the signature does not verify"
            case .unknown: signed = "not checked yet"
            }
            rows.append(.init(label: "Signed by", value: signed))
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

    /// Hostnames, each with where it came from: a name is a claim, and its source is how far to trust it.
    private func nameRows(_ aggregate: Aggregate) -> [HoverInfo.Row] {
        guard !aggregate.names.isEmpty else { return [] }
        let ordered = aggregate.names.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map { name, _ in
            "\(name) (\(Self.sourceLabel(aggregate.nameSources[name])))"
        }
        return [.init(label: ordered.count == 1 ? "Hostname" : "Hostnames", value: Self.list(ordered, limit: 3))]
    }

    private static func sourceLabel(_ source: NameSource?) -> String {
        switch source {
        case .dns: "from DNS"
        case .sni: "from TLS"
        case .ptr: "reverse lookup"
        case nil: "source unknown"
        }
    }

    /// Where a destination is and whose network it is on, when a database says.
    private static func placeRows(_ aggregate: Aggregate) -> [HoverInfo.Row] {
        guard let flow = aggregate.flows.first else { return [] }
        var rows: [HoverInfo.Row] = []
        if let country = flow.country {
            let name = Locale.current.localizedString(forRegionCode: country) ?? country
            rows.append(.init(label: "Location", value: flow.city.map { "\($0), \(name)" } ?? name))
        }
        if let asn = flow.asn { rows.append(.init(label: "Network", value: flow.org.map { "\($0) (AS\(asn))" } ?? "AS\(asn)")) }
        if !flow.tags.isEmpty { rows.append(.init(label: "On your lists", value: list(flow.tags))) }
        return rows
    }

    private func trafficRows(_ aggregate: Aggregate) -> [HoverInfo.Row] {
        var rows: [HoverInfo.Row] = [
            .init(label: "Connections", value: aggregate.open == aggregate.total ? "\(aggregate.open)" : "\(aggregate.open) open, \(aggregate.total - aggregate.open) ended"),
            .init(label: "Rate", value: "↓ \(ByteFormat.rate(aggregate.rateIn))  ↑ \(ByteFormat.rate(aggregate.rateOut))"),
            .init(label: "Total", value: "↓ \(ByteFormat.bytes(Double(aggregate.bytesIn)))  ↑ \(ByteFormat.bytes(Double(aggregate.bytesOut)))"),
        ]
        let services = aggregate.flows.reduce(into: [String: ServiceBasis]()) { result, flow in
            if let service = flow.service, let basis = flow.serviceBasis { result[service] = basis }
        }
        if !services.isEmpty {
            // How the label was arrived at: assumed from the port, inferred, or seen on the wire.
            let text = services.keys.sorted().map { name -> String in
                switch services[name]! {
                case .port: "\(name) (by port)"
                case .heuristic: "\(name) (inferred)"
                case .observed: "\(name) (seen)"
                }
            }
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
        AddressClass(address).label
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
