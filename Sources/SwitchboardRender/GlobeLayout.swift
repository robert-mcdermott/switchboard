import Foundation
import SwitchboardCore
import simd

/// A line on the globe's surface: part of a parallel, a meridian, or a coast.
struct GlobeLine {
    var a: SIMD3<Float>
    var b: SIMD3<Float>
    var halfWidth: Float
    var glow: Float
    var color: SIMD3<Float>
}

/// How the globe is turned and where it sits: an orthographic view, looking at the
/// sphere from far away, as a satellite photograph does.
struct GlobeView {
    /// The longitude at the middle of the view, in radians.
    var longitude: Float = 0
    /// How far the north pole leans toward the viewer, in radians.
    var tilt: Float = 0.4
    var radius: Float = 320
    var center = SIMD2<Float>(150, 0)
    /// The longitude of home, which the view sways either side of.
    var homeLongitude: Float = 0

    /// Turns the globe to face a place, leaning its pole so the place sits a little above the middle.
    mutating func face(_ place: GeoPoint) {
        homeLongitude = Float(place.longitude) * .pi / 180
        longitude = homeLongitude
        tilt = max(-0.85, min(0.85, Float(place.latitude) * 0.6 * .pi / 180))
    }

    /// A unit vector for a latitude and longitude in degrees.
    static func point(_ latitude: Double, _ longitude: Double) -> SIMD3<Float> {
        let phi = Float(latitude) * .pi / 180, lambda = Float(longitude) * .pi / 180
        return SIMD3(cos(phi) * sin(lambda), sin(phi), cos(phi) * cos(lambda))
    }

    /// Where a point lands on screen, and how squarely it faces the viewer: 1 at the
    /// middle of the disc, 0 at its edge, negative behind.
    func project(_ v: SIMD3<Float>) -> (SIMD2<Float>, Float) {
        let c = cos(longitude), s = sin(longitude)
        let x = v.x * c - v.z * s
        let z = v.x * s + v.z * c
        let y = v.y * cos(tilt) - z * sin(tilt)
        let facing = v.y * sin(tilt) + z * cos(tilt)
        return (center + SIMD2(x, y) * radius, facing)
    }

    /// The front of every line, ready to draw, with the rim of the disc around them.
    func lines(_ lines: [GlobeLine]) -> [GraphController.Bar] {
        var bars: [GraphController.Bar] = []
        bars.reserveCapacity(lines.count / 2 + 200)
        for line in lines {
            let (pa, fa) = project(line.a), (pb, fb) = project(line.b)
            let facing = min(fa, fb)
            guard facing > 0 else { continue }
            // Lines fade toward the rim, where they bunch up.
            bars.append(GraphController.Bar(
                from: pa, to: pb, target: nil, halfWidth: line.halfWidth,
                glow: line.glow * (0.35 + 0.65 * GraphController.smoothstep(0, 0.5, facing)), color: line.color))
        }
        // The rim: a bright edge and a wider, fainter glow outside it, like air.
        let steps = 120
        for step in 0..<steps {
            let a = Float(step) / Float(steps) * 2 * .pi, b = Float(step + 1) / Float(steps) * 2 * .pi
            let pa = center + SIMD2(cos(a), sin(a)) * radius, pb = center + SIMD2(cos(b), sin(b)) * radius
            bars.append(GraphController.Bar(from: pa, to: pb, target: nil, halfWidth: 0.9, glow: 0.13, color: Palette.host * 0.8))
            let wa = center + SIMD2(cos(a), sin(a)) * (radius + 7), wb = center + SIMD2(cos(b), sin(b)) * (radius + 7)
            bars.append(GraphController.Bar(from: wa, to: wb, target: nil, halfWidth: 6, glow: 0.035, color: Palette.host))
        }
        return bars
    }

    /// Parallels and meridians every 30°, and the outline of the land, cut into short
    /// pieces so they curve as the globe turns.
    static func surface(scheme: PaletteScheme) -> [GlobeLine] {
        var lines: [GlobeLine] = []
        func add(_ points: [(Double, Double)], halfWidth: Float, glow: Float, color: SIMD3<Float>) {
            for (first, second) in zip(points, points.dropFirst()) {
                let a = point(first.0, first.1), b = point(second.0, second.1)
                let angle = acos(min(max(simd_dot(a, b), -1), 1))
                // No piece longer than 3°.
                let pieces = max(1, Int((angle / (3 * .pi / 180)).rounded(.up)))
                var previous = a
                for piece in 1...pieces {
                    let next = slerp(a, b, Float(piece) / Float(pieces), angle: angle)
                    lines.append(GlobeLine(a: previous, b: next, halfWidth: halfWidth, glow: glow, color: color))
                    previous = next
                }
            }
        }
        let grid = Palette.trunk
        for latitude in stride(from: -60.0, through: 60.0, by: 30) {
            add(stride(from: -180.0, through: 180.0, by: 6).map { (latitude, $0) }, halfWidth: 0.4, glow: latitude == 0 ? 0.05 : 0.03, color: grid)
        }
        for longitude in stride(from: -180.0, to: 180.0, by: 30) {
            add(stride(from: -84.0, through: 84.0, by: 6).map { ($0, longitude) }, halfWidth: 0.4, glow: 0.03, color: grid)
        }
        let land = scheme.host * 0.55 + Palette.secondaryText * 0.45
        for ring in WorldOutline.rings {
            add(ring.map { (Double($0.0), Double($0.1)) }, halfWidth: 0.8, glow: 0.16, color: land)
        }
        return lines
    }

    private static func slerp(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float, angle: Float) -> SIMD3<Float> {
        guard angle > 1e-4 else { return a }
        return (a * sin((1 - t) * angle) + b * sin(t * angle)) / sin(angle)
    }
}

extension GraphController {
    /// Destinations sit where a database says they are; this Mac sits at home; processes
    /// stand in a column beside the globe, and lighting one lights its arcs.
    static func globeScene(_ input: LayoutInput, born: (NodeID) -> Float) -> LayoutScene {
        var scene = LayoutScene()
        let view = input.globeView
        let home = GlobeView.point(input.home.latitude, input.home.longitude)
        let unplaced = NodeID.group(.rest, "unlocated")

        var hostNode = Node(
            id: .host, position: input.previous[.host]?.position ?? view.project(home).0, anchor: view.project(home).0,
            radius: 7, color: input.scheme.host, intensity: 1, bornAt: -100, label: input.hostLabel, priority: .infinity,
            labelSide: 0)
        hostNode.globe = home
        scene.nodes.append(hostNode)

        // The busiest processes, in a column on the left, as a legend to light arcs from.
        let ranked = input.byProcess.keys.sorted { a, b in
            let x = input.byProcess[a]!, y = input.byProcess[b]!
            return (x.bytes, b) > (y.bytes, a)
        }.prefix(laneLimit)
        func name(_ pid: Int32) -> String { (input.processes[pid]?.name ?? "pid \(pid)").lowercased() }
        let pids = ranked.sorted { (name($0), $0) < (name($1), $1) }
        let spacing = min(24, 2 * view.radius / Float(max(pids.count, 1)))
        let top = Float(pids.count - 1) / 2 * spacing
        let column = view.center.x - view.radius - 190
        for (row, pid) in pids.enumerated() {
            let aggregate = input.byProcess[pid]!
            scene.nodes.append(processNode(
                input, pid: pid, aggregate: aggregate, anchor: SIMD2(column, top - Float(row) * spacing),
                radius: 4 + 3 * level(Double(aggregate.bytes), scale: 9), bornAt: born(.process(pid))))
        }
        scene.processCount = pids.count

        // Each destination where it is. Addresses on this side of the router are at home;
        // those no database knows share one node below the globe.
        var placed: [NodeID: SIMD3<Float>] = [:]
        var unplacedAggregate = Aggregate()
        var unplacedMembers: [IPAddress] = []
        for (id, aggregate) in input.remotes {
            let located = aggregate.flows.first { $0.latitude != nil && $0.longitude != nil }
            let address = aggregate.flows.first?.key.remote.address
            let seed = "\(id)"
            if let located, let latitude = located.latitude, let longitude = located.longitude {
                // Spread a little, so a city's many addresses are a cluster rather than one dot.
                placed[id] = GlobeView.point(
                    latitude + Double(unit(seed, salt: 0x61) - 0.5) * 3, longitude + Double(unit(seed, salt: 0x62) - 0.5) * 3)
            } else if let address, AddressClass(address) != .public {
                placed[id] = GlobeView.point(
                    input.home.latitude + Double(unit(seed, salt: 0x63) - 0.5) * 5,
                    input.home.longitude + Double(unit(seed, salt: 0x64) - 0.5) * 5)
            } else {
                unplacedAggregate.merge(aggregate)
                unplacedMembers.append(contentsOf: input.members[id] ?? aggregate.flows.map(\.key.remote.address))
                for flow in aggregate.flows { scene.nodeFor[flow.key.remote.address] = unplaced }
            }
        }
        for (id, aggregate) in input.remotes where placed[id] != nil {
            for flow in aggregate.flows { scene.nodeFor[flow.key.remote.address] = id }
        }

        for id in placed.keys.sorted(by: remoteOrder) {
            let aggregate = input.remotes[id]!
            let point = placed[id]!
            let (position, _) = view.project(point)
            let size = input.members[id]?.count ?? 1
            let tagged = aggregate.flows.first?.tags.compactMap { input.tagColors[$0] }.first
            let text: String
            switch id {
            case .network(let address, let bits): text = "\(address)/\(bits)"
            case .endpoint(let address): text = aggregate.name.map { clip($0, to: 32) } ?? address.description
            case .group: text = input.groupLabels[id] ?? ""
            default: text = ""
            }
            var node = Node(
                id: id, position: input.previous[id]?.position ?? position, anchor: position,
                radius: 2.2 + 4 * level(Double(aggregate.bytes), scale: 9) + (size > 1 ? 1.5 : 0),
                color: tagged ?? input.scheme.color(forService: aggregate.service),
                intensity: (0.35 + 0.65 * level(aggregate.rate, scale: 6.5)) * Float(max(aggregate.life, 0.15)),
                bornAt: born(id), label: size > 1 ? "\(clip(text, to: 30)) ×\(size)" : text,
                priority: aggregate.rate + Double(aggregate.bytes) * 1e-9)
            node.globe = point
            scene.nodes.append(node)
        }
        if unplacedAggregate.total > 0 {
            let anchor = view.center + SIMD2(0, -view.radius - 46)
            scene.nodes.append(Node(
                id: unplaced, position: input.previous[unplaced]?.position ?? anchor, anchor: anchor,
                radius: 3 + 4 * level(Double(unplacedAggregate.bytes), scale: 9), color: Palette.secondaryText,
                intensity: 0.5, bornAt: born(unplaced), label: "no location ×\(Set(unplacedMembers).count)", priority: 1e10,
                labelSide: 1))
            scene.nodeAggregates[unplaced] = unplacedAggregate
            scene.members[unplaced] = Array(Set(unplacedMembers)).sorted { $0.networkBytes.lexicographicallyPrecedes($1.networkBytes) }
            scene.labels[unplaced] = "places unknown"
        }

        // One arc per process and destination, from this Mac, over the surface.
        var lookup: [NodeID: Int] = [:]
        for (offset, node) in scene.nodes.enumerated() { lookup[node.id] = offset }
        var links: [EdgeKey: Aggregate] = [:]
        for (key, aggregate) in input.links {
            guard case .process = key.from else { continue }
            let to = placed[key.to] != nil ? key.to : unplaced
            links[EdgeKey(from: key.from, to: to), default: Aggregate()].merge(aggregate)
        }
        // Places unknown get no arcs: a line from home to nowhere would cross the whole globe.
        for key in links.keys.sorted(by: { a, b in a.from != b.from ? remoteOrder(a.from, b.from) : remoteOrder(a.to, b.to) })
        where key.to != unplaced {
            guard let aggregate = links[key], let remote = lookup[key.to], case .process(let pid) = key.from else { continue }
            var edge = edge(
                from: 0, to: remote, target: .edge(key.from, key.to), aggregate: aggregate,
                color: input.scheme.color(forService: aggregate.service), seed: "\(pid) \(key.to)", bend: 0,
                outbound: aggregate.rateOut >= aggregate.rateIn, trunk: false)
            // Longer arcs rise higher; each process's arc to a place rises a little differently,
            // so several processes talking to one place fan out instead of lying on each other.
            if let point = placed[key.to] {
                let angle = acos(min(max(simd_dot(home, point), -1), 1))
                edge.lift = (0.04 + 0.32 * angle / .pi) * (0.8 + 0.4 * unit("\(pid)", salt: 0x65))
            }
            edge.halfWidth *= 0.8
            scene.edges.append(edge)
        }
        scene.edgeAggregates = links
        scene.globeLines = GlobeView.surface(scheme: input.scheme)
        scene.halfSize = SIMD2(view.center.x + view.radius + 210 - 20, view.radius + 70)
        return scene
    }
}
