import Foundation
import SwitchboardCore
import simd

/// A straight line in the cyberspace layout's world: part of the floor's grid, a tower,
/// or the pad at a tower's foot. Projected onto the screen every frame.
struct SpaceLine {
    var a: SIMD3<Float>
    var b: SIMD3<Float>
    var halfWidth: Float
    var glow: Float
    var color: SIMD3<Float>
    var target: PickTarget?
    var pulse: Float = 0
    var speed: Float = 0.3
    var phase: Float = 0
}

/// The address space laid out as a floor (docs/SPEC.md §10.2).
///
/// Each family has a square. Addresses run along a Hilbert curve, which keeps neighbouring
/// addresses neighbours on the floor, so every prefix is a compact block: an IPv4 /8 is one
/// cell of a 16 × 16 grid and a /16 one cell of a 256 × 256 grid. A company's networks form
/// districts, and the same address is always in the same place. IPv6's square holds the
/// global unicast space, 2000::/3. Link-local, unique-local and loopback IPv6 addresses
/// have no place on either and stand on this Mac's own pad, in the gap between the squares.
enum AddressFloor {
    /// The side of each square, in world units.
    static let side: Float = 2400
    /// The gap between the squares, where this Mac stands.
    static let gap: Float = 360
    static let v4Center = SIMD2<Float>(-(side + gap) / 2, 0)
    static let v6Center = SIMD2<Float>((side + gap) / 2, 0)

    enum Square: Equatable { case v4, v6, local }

    /// The cell of a 2^order × 2^order square that the Hilbert curve visits `index`-th.
    static func hilbert(_ index: UInt64, order: Int) -> (x: UInt32, y: UInt32) {
        var x: UInt64 = 0, y: UInt64 = 0, t = index, s: UInt64 = 1
        let n = UInt64(1) << UInt64(order)
        while s < n {
            let rx = 1 & (t / 2)
            let ry = 1 & (t ^ rx)
            if ry == 0 {
                if rx == 1 {
                    x = s - 1 - x
                    y = s - 1 - y
                }
                swap(&x, &y)
            }
            x += s * rx
            y += s * ry
            t /= 4
            s *= 2
        }
        return (UInt32(x), UInt32(y))
    }

    /// The 32 bits that place an address on its square, and which square.
    static func index(_ address: IPAddress) -> (UInt64, Square) {
        switch address {
        case .v4(let value):
            return (UInt64(value), .v4)
        case .v6(let hi, let lo):
            // An IPv4-mapped address is an IPv4 address.
            if hi == 0, lo >> 32 == 0xFFFF { return (lo & 0xFFFF_FFFF, .v4) }
            // Global unicast fills the IPv6 square: the 32 bits after the leading 001.
            if hi >> 61 == 1 { return ((hi >> 29) & 0xFFFF_FFFF, .v6) }
            return (0, .local)
        }
    }

    /// Where an address lies, as (x, z) on the floor in world units, and on which square.
    static func place(_ address: IPAddress) -> (point: SIMD2<Float>, square: Square) {
        let (index, square) = index(address)
        switch square {
        case .v4: return (cell(index, center: v4Center), .v4)
        case .v6: return (cell(index, center: v6Center), .v6)
        case .local:
            // Spread along the gap, at a place fixed by the address.
            let seed = address.description
            let along = (GraphController.unit(seed, salt: 0x91) - 0.5) * side * 0.6
            let across = (GraphController.unit(seed, salt: 0x92) - 0.5) * gap * 0.5
            return (SIMD2(across, along), .local)
        }
    }

    /// The middle of the cell holding `index` on a square centred at `center`.
    static func cell(_ index: UInt64, center: SIMD2<Float>) -> SIMD2<Float> {
        let (x, y) = hilbert(index, order: 16)
        return center + (SIMD2(Float(x), Float(y)) + 0.5) / 65536 * side - side / 2
    }

    /// The middle of the /8 block (IPv4) or /11 block (IPv6) holding `index`: one cell of
    /// the square's 16 × 16 grid.
    static func block(_ index: UInt64, center: SIMD2<Float>) -> SIMD2<Float> {
        let (x, y) = hilbert(index >> 24, order: 4)
        return center + (SIMD2(Float(x), Float(y)) + 0.5) / 16 * side - side / 2
    }

    /// The name of the block an address is in, for the floor's labels.
    static func blockName(_ address: IPAddress) -> String? {
        switch index(address) {
        case (let index, .v4): return "\(index >> 24)/8"
        case (_, .v6):
            guard case .v6(let hi, _) = address else { return nil }
            return String(format: "%x::/11", UInt16(truncatingIfNeeded: hi >> 48) & 0xFFE0)
        default: return nil
        }
    }

    /// The floor's own lines: each square's edge and 16 × 16 block grid, and a fainter grid
    /// running out to the horizon around them. Long lines are cut into pieces so the fog can
    /// fade them along their length.
    static func lines(scheme: PaletteScheme) -> [SpaceLine] {
        var lines: [SpaceLine] = []
        func add(_ a: SIMD3<Float>, _ b: SIMD3<Float>, halfWidth: Float, glow: Float, color: SIMD3<Float>) {
            let pieces = max(1, Int((simd_distance(a, b) / 600).rounded(.up)))
            for piece in 0..<pieces {
                let t0 = Float(piece) / Float(pieces), t1 = Float(piece + 1) / Float(pieces)
                lines.append(SpaceLine(
                    a: simd_mix(a, b, SIMD3(repeating: t0)), b: simd_mix(a, b, SIMD3(repeating: t1)),
                    halfWidth: halfWidth, glow: glow, color: color))
            }
        }
        let half = side / 2
        for center in [v4Center, v6Center] {
            for step in 0...16 {
                let offset = -half + Float(step) * side / 16
                let edge = step == 0 || step == 16
                let color = edge ? scheme.host * 0.7 : scheme.trunk
                let glow: Float = edge ? 0.16 : 0.07
                let width: Float = edge ? 1.5 : 0.8
                add(SIMD3(center.x + offset, 0, center.y - half), SIMD3(center.x + offset, 0, center.y + half),
                    halfWidth: width, glow: glow, color: color)
                add(SIMD3(center.x - half, 0, center.y + offset), SIMD3(center.x + half, 0, center.y + offset),
                    halfWidth: width, glow: glow, color: color)
            }
        }
        // The horizon grid stays off the squares, so their grids read cleanly.
        let reach: Float = 7200, spacing: Float = 600
        let squaresX = v6Center.x + half, squaresZ = half
        let faint = scheme.trunk * 0.8
        for step in stride(from: -reach, through: reach, by: spacing) {
            if abs(step) > squaresZ + 1 {
                add(SIMD3(-reach, 0, step), SIMD3(reach, 0, step), halfWidth: 0.6, glow: 0.05, color: faint)
            }
            if abs(step) > squaresX + 1 {
                add(SIMD3(step, 0, -reach), SIMD3(step, 0, reach), halfWidth: 0.6, glow: 0.05, color: faint)
            }
        }
        return lines
    }
}

/// The camera of the cyberspace layout: it looks at `target` from `distance` away, turned
/// `yaw` about the vertical and raised `pitch` above the floor. Perspective, so nearer is
/// bigger, and what is behind it is not drawn.
struct SpaceCamera: Equatable, Sendable {
    var target = SpaceCamera.homeTarget
    var yaw = SpaceCamera.homeYaw
    var pitch: Float = SpaceCamera.homePitch
    var distance: Float = SpaceCamera.homeDistance

    static let homeTarget = SIMD3<Float>(0, 60, 200)
    static let homeYaw: Float = 0.3
    static let homeDistance: Float = 3500
    static let homePitch: Float = 0.52
    /// Half the height of the picture in the units handed to the renderer.
    static let halfHeight: Float = 600
    /// The vertical field of view, in radians.
    static let fieldOfView: Float = 0.95
    static let focal = halfHeight / tan(fieldOfView / 2)
    /// Nothing nearer than this is drawn.
    static let near: Float = 30
    /// Things fade out between these depths.
    static let fogStart: Float = 3000
    static let fogEnd: Float = 11_000
    /// The depth at which things are drawn at their own size.
    static let referenceDepth: Float = homeDistance

    struct Basis {
        var eye: SIMD3<Float>
        var right: SIMD3<Float>
        var up: SIMD3<Float>
        var forward: SIMD3<Float>
    }

    var eye: SIMD3<Float> {
        target + SIMD3(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw)) * distance
    }

    func basis() -> Basis {
        let eye = self.eye
        let forward = simd_normalize(target - eye)
        let right = simd_normalize(simd_cross(forward, SIMD3(0, 1, 0)))
        return Basis(eye: eye, right: right, up: simd_cross(right, forward), forward: forward)
    }

    /// A point in the camera's own frame: across, up, and depth ahead.
    static func view(_ point: SIMD3<Float>, _ basis: Basis) -> SIMD3<Float> {
        let v = point - basis.eye
        return SIMD3(simd_dot(v, basis.right), simd_dot(v, basis.up), simd_dot(v, basis.forward))
    }

    static func screen(_ viewed: SIMD3<Float>) -> SIMD2<Float> {
        SIMD2(viewed.x, viewed.y) / viewed.z * focal
    }

    /// Where a point lands on the picture, and how far ahead of the camera it is; `nil`
    /// behind the camera.
    static func project(_ point: SIMD3<Float>, _ basis: Basis) -> (point: SIMD2<Float>, depth: Float)? {
        let viewed = view(point, basis)
        guard viewed.z > near else { return nil }
        return (screen(viewed), viewed.z)
    }

    /// A segment on the picture, cut where it passes behind the camera, and the depth of its middle.
    static func project(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ basis: Basis) -> (SIMD2<Float>, SIMD2<Float>, Float)? {
        var va = view(a, basis), vb = view(b, basis)
        if va.z <= near && vb.z <= near { return nil }
        if va.z < near { va += (vb - va) * ((near - va.z) / (vb.z - va.z)) }
        if vb.z < near { vb += (va - vb) * ((near - vb.z) / (va.z - vb.z)) }
        return (screen(va), screen(vb), (va.z + vb.z) / 2)
    }

    /// 1 near, falling to 0 in the distance.
    static func fog(_ depth: Float) -> Float {
        1 - GraphController.smoothstep(fogStart, fogEnd, depth)
    }

    /// How much bigger than its own size a thing at `depth` is drawn.
    static func size(_ depth: Float) -> Float {
        min(max(referenceDepth / depth, 0.3), 3)
    }

    /// Turns by an angle in radians: across orbits round the target, up and down tilts.
    mutating func orbit(by angle: SIMD2<Float>) {
        // Drag right and the world follows the pointer: the camera goes the other way.
        yaw -= angle.x
        pitch = min(max(pitch - angle.y, 0.06), 1.5)
        if yaw > .pi { yaw -= 2 * .pi }
        if yaw < -.pi { yaw += 2 * .pi }
    }

    /// Moves the target across the floor: x to the right, z ahead, as the camera faces.
    mutating func fly(_ direction: SIMD3<Float>, by amount: Float) {
        let ahead = SIMD3<Float>(-sin(yaw), 0, -cos(yaw)), right = SIMD3<Float>(cos(yaw), 0, -sin(yaw))
        target += (right * direction.x + ahead * direction.z + SIMD3(0, direction.y, 0)) * amount
        target.y = min(max(target.y, 0), 2000)
        // Not so far out that the floor is lost.
        let limit: Float = 6000
        target.x = min(max(target.x, -limit), limit)
        target.z = min(max(target.z, -limit), limit)
    }
}

extension GraphController {
    /// How high this Mac floats, and its processes around it.
    static let hostHeight: Float = 760
    static let processHeight: Float = 640

    /// This Mac floats over the gap between the squares with its processes in a ring round
    /// it; each destination is a tower standing on its address, as tall as the bytes it has
    /// carried and as bright as its rate; beams arc from each process to its towers.
    static func cyberspaceScene(_ input: LayoutInput, born: (NodeID) -> Float) -> LayoutScene {
        var scene = LayoutScene()
        let basis = input.spaceCamera.basis()
        func projected(_ point: SIMD3<Float>) -> SIMD2<Float> { SpaceCamera.project(point, basis)?.point ?? .zero }

        let hostPoint = SIMD3<Float>(0, hostHeight, 0)
        var host = Node(
            id: .host, position: input.previous[.host]?.position ?? projected(hostPoint), anchor: projected(hostPoint),
            radius: 11, color: input.scheme.host, intensity: 1, bornAt: -100, label: input.hostLabel, priority: .infinity,
            labelSide: 0)
        host.space = hostPoint
        host.baseRadius = 11
        scene.nodes.append(host)

        // Processes on a ring, each at an angle fixed by its name.
        func name(_ pid: Int32) -> String { input.processes[pid]?.name ?? "pid \(pid)" }
        let pids = input.byProcess.keys.sorted { (name($0), $0) < (name($1), $1) }
        let ring = max(560, Float(pids.count) * 90 / (2 * .pi))
        let angles = spread(pids.map { unit(name($0), salt: 0x5A) * 2 * .pi })
        for (offset, pid) in pids.enumerated() {
            let point = SIMD3(cos(angles[offset]) * ring, processHeight, sin(angles[offset]) * ring)
            let aggregate = input.byProcess[pid]!
            let radius = 5 + 3 * level(Double(aggregate.bytes), scale: 9)
            var node = processNode(
                input, pid: pid, aggregate: aggregate, anchor: projected(point), radius: radius, bornAt: born(.process(pid)))
            node.space = point
            node.baseRadius = radius
            scene.nodes.append(node)
        }
        scene.processCount = pids.count

        // A tower for each destination, standing on its address.
        var lines = AddressFloor.lines(scheme: input.scheme)
        // A pillar of light under this Mac, and its processes' ring traced on the floor.
        lines.append(SpaceLine(
            a: SIMD3(0, 0, 0), b: hostPoint, halfWidth: 1.6, glow: 0.12, color: input.scheme.host, target: nil, pulse: 0.5,
            speed: 0.25))
        let segments = 72
        for segment in 0..<segments {
            let a = Float(segment) / Float(segments) * 2 * .pi, b = Float(segment + 1) / Float(segments) * 2 * .pi
            lines.append(SpaceLine(
                a: SIMD3(cos(a) * ring, 0, sin(a) * ring), b: SIMD3(cos(b) * ring, 0, sin(b) * ring), halfWidth: 1,
                glow: 0.07, color: input.scheme.host * 0.8, target: nil))
        }
        var blocks: [String: (point: SIMD2<Float>, towers: Int)] = [:]
        var localTowers = 0
        // Where each tower stands, first, so crowding can be counted.
        var standing: [(id: NodeID, address: IPAddress, base: SIMD2<Float>, square: AddressFloor.Square)] = []
        var crowding: [SIMD2<Int32>: Int] = [:]
        func patch(_ point: SIMD2<Float>) -> SIMD2<Int32> { SIMD2(Int32((point.x / 30).rounded(.down)), Int32((point.y / 30).rounded(.down))) }
        for id in input.remotes.keys.sorted(by: remoteOrder) {
            let aggregate = input.remotes[id]!
            let address: IPAddress
            switch id {
            case .endpoint(let one), .network(let one, _): address = one
            default:
                // A group stands where its busiest member is.
                guard let busiest = aggregate.flows.max(by: { $0.bytesTotal < $1.bytesTotal }) else { continue }
                address = busiest.key.remote.address
            }
            let seed = "\(id)"
            let (floor, square) = AddressFloor.place(address)
            // Within a few units, so towers in one /24 stand side by side, still inside their /16.
            let angle = unit(seed, salt: 0x71) * 2 * .pi, nudge = 4 * unit(seed, salt: 0x72)
            let base = floor + SIMD2(cos(angle), sin(angle)) * nudge
            standing.append((id, address, base, square))
            crowding[patch(base), default: 0] += 1
        }
        for (id, address, base, square) in standing {
            let aggregate = input.remotes[id]!
            let seed = "\(id)"
            // Many towers on one patch of floor would add up to a white column: each is
            // thinner and fainter the more it shares its patch with.
            let crowd = min(1, pow(4 / Float(crowding[patch(base)] ?? 1), 0.7))
            let bytes = level(Double(aggregate.bytes), scale: 9), rate = level(aggregate.rate, scale: 6.5)
            let life = Float(max(aggregate.life, 0.15))
            let top = SIMD3(base.x, 50 + 720 * bytes, base.y)
            let size = input.members[id]?.count ?? 1
            let tagged = aggregate.flows.first?.tags.compactMap { input.tagColors[$0] }.first
            let color = tagged ?? input.scheme.color(forService: aggregate.service)
            let text: String
            switch id {
            case .network(let network, let bits): text = "\(network)/\(bits)"
            case .endpoint(let one): text = aggregate.name.map { clip($0, to: 32) } ?? one.description
            case .group: text = input.groupLabels[id] ?? ""
            default: text = ""
            }
            let radius = (3.5 + 4.5 * bytes + (size > 1 ? 1.5 : 0)) * (0.45 + 0.55 * crowd)
            var node = Node(
                id: id, position: input.previous[id]?.position ?? projected(top), anchor: projected(top), radius: radius,
                // The ring that marks a new node is drawn at full strength however faint the
                // node, and hundreds arriving in one block add up to a white column; on a
                // crowded patch, towers arrive without it.
                color: color, intensity: (0.4 + 0.6 * rate) * life * crowd, bornAt: crowd < 0.5 ? -100 : born(id),
                label: size > 1 ? "\(clip(text, to: 30)) ×\(size)" : text, priority: aggregate.rate + Double(aggregate.bytes) * 1e-9,
                labelSide: 1)
            node.space = top
            node.baseRadius = radius
            if case .endpoint(let one) = id, input.novel.contains(one) {
                node.ring = SIMD4(0.85, 1, 1, 1)
                node.intensity = max(node.intensity, 0.9)
            }
            scene.nodes.append(node)
            for flow in aggregate.flows { scene.nodeFor[flow.key.remote.address] = id }

            // The tower, with pulses climbing it as fast as its traffic, and a pad at its foot.
            let target = PickTarget.node(id)
            lines.append(SpaceLine(
                a: SIMD3(base.x, 0, base.y), b: top, halfWidth: (1.2 + 2.4 * bytes) * (0.5 + 0.5 * crowd),
                glow: (0.05 + 0.24 * rate) * life * crowd, color: color, target: target,
                pulse: rate > 0.02 ? (0.35 + 0.8 * rate) * life * crowd : 0, speed: 0.15 + 0.8 * rate,
                phase: unit(seed, salt: 0x73)))
            let pad: Float = 7 + 6 * bytes
            lines.append(SpaceLine(
                a: SIMD3(base.x - pad, 0, base.y), b: SIMD3(base.x + pad, 0, base.y), halfWidth: 0.8, glow: 0.06 * life * crowd,
                color: color, target: nil))
            lines.append(SpaceLine(
                a: SIMD3(base.x, 0, base.y - pad), b: SIMD3(base.x, 0, base.y + pad), halfWidth: 0.8, glow: 0.06 * life * crowd,
                color: color, target: nil))

            if square == .local {
                localTowers += 1
            } else if let block = AddressFloor.blockName(address) {
                let (index, _) = AddressFloor.index(address)
                let point = AddressFloor.block(index, center: square == .v4 ? AddressFloor.v4Center : AddressFloor.v6Center)
                blocks[block, default: (point, 0)].towers += 1
            }
        }

        // The floor's labels: each square, each block that has a tower in it, and this Mac's pad.
        func marker(_ number: Int, _ label: String, at point: SIMD3<Float>, priority: Double) {
            var node = Node(
                id: .marker(number), position: projected(point), anchor: projected(point), radius: 1.5,
                color: input.scheme.secondaryText, intensity: 0.25, bornAt: -100, label: label, priority: priority, labelSide: 0)
            node.space = point
            node.baseRadius = 1.5
            scene.nodes.append(node)
        }
        let half = AddressFloor.side / 2
        marker(20_000, "IPv4 · 0.0.0.0/0", at: SIMD3(AddressFloor.v4Center.x, 0, half + 70), priority: 1e11)
        marker(20_001, "IPv6 · 2000::/3", at: SIMD3(AddressFloor.v6Center.x, 0, half + 70), priority: 1e11)
        if localTowers > 0 { marker(20_002, "link-local · unique-local", at: SIMD3(0, 0, half * 0.35), priority: 1e10) }
        for (number, name) in blocks.keys.sorted().enumerated() {
            let block = blocks[name]!
            marker(10_000 + number, name, at: SIMD3(block.point.x, 0, block.point.y), priority: 1e8 + Double(block.towers))
        }

        var lookup: [NodeID: Int] = [:]
        for (offset, node) in scene.nodes.enumerated() { lookup[node.id] = offset }

        // Trunks from this Mac down to each process.
        for pid in pids {
            guard let to = lookup[.process(pid)], let aggregate = input.byProcess[pid] else { continue }
            var trunk = edge(
                from: 0, to: to, target: .edge(.host, .process(pid)), aggregate: aggregate, color: input.scheme.trunk,
                seed: "trunk \(pid)", bend: 0, outbound: aggregate.rateOut >= aggregate.rateIn, trunk: true)
            trunk.baseHalfWidth = trunk.halfWidth
            scene.edges.append(trunk)
        }
        // A beam from each process to each tower it talks to, arcing up and over.
        let links = input.links.filter { key, _ in
            if case .process = key.from, lookup[key.to] != nil { return true }
            return false
        }
        // Beams all cross the same space above the floor, and their light adds up: past a few
        // hundred they would fill it with white. So each is fainter the more there are, and
        // beyond `barLimit` only the busiest are drawn. Every tower stays.
        var keys = links.keys.sorted(by: { a, b in a.from != b.from ? remoteOrder(a.from, b.from) : remoteOrder(a.to, b.to) })
        if keys.count > barLimit {
            let busiest = Set(keys.sorted { (links[$0]!.rate, links[$0]!.bytes) > (links[$1]!.rate, links[$1]!.bytes) }.prefix(barLimit))
            keys = keys.filter { busiest.contains($0) }
        }
        let crowd = min(1, pow(150 / Float(max(keys.count, 1)), 0.7))
        for key in keys {
            guard let aggregate = links[key], let from = lookup[key.from], let to = lookup[key.to],
                  case .process(let pid) = key.from else { continue }
            var beam = edge(
                from: from, to: to, target: .edge(key.from, key.to), aggregate: aggregate,
                color: input.scheme.color(forService: aggregate.service), seed: "\(pid) \(key.to)", bend: 0,
                outbound: aggregate.rateOut >= aggregate.rateIn, trunk: false, dimming: crowd)
            beam.pulse *= crowd
            beam.lift = 0.07 + 0.06 * unit("\(pid)", salt: 0x74)
            beam.halfWidth *= 0.85 * (0.6 + 0.4 * crowd)
            beam.baseHalfWidth = beam.halfWidth
            scene.edges.append(beam)
        }
        scene.edgeAggregates = links
        scene.spaceLines = lines
        // Hundreds of towers in a few blocks, under full bloom, glow into white: less, the more there are.
        scene.bloomScale = min(1, max(0.45, pow(600 / Float(max(standing.count, 1)), 0.5)))
        scene.halfSize = SIMD2(SpaceCamera.halfHeight, SpaceCamera.halfHeight)
        return scene
    }
}
