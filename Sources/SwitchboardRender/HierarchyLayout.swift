import Foundation
import SwitchboardCore
import simd

extension GraphController {
    /// How many rows the hierarchy may have before it starts folding things together.
    static let hierarchyLeafBudget = 64
    static let hierarchyProcessLimit = 36
    static let hierarchyAddressesPerDomain = 4

    /// What a connection's far end is called in the hierarchy: the domain it was reached
    /// by, or failing that, the network or the kind of address.
    static func hierarchyDomain(_ flow: Flow) -> (name: String, filter: String) {
        if let host = flow.hostname {
            let domain = registeredDomain(host)
            return (domain, "(host=\"\(domain)\" OR host=\"*.\(domain)\")")
        }
        let address = flow.key.remote.address
        let kind = AddressClass(address)
        guard kind == .public else { return (kind.label, "class=\(kind.rawValue.lowercased())") }
        if case .network(let network, let bits) = network(of: address) { return ("\(network)/\(bits)", "remote:\(network)/\(bits)") }
        return (address.description, "remote=\(address)")
    }

    /// Account → process → domain → address, as a tree read left to right. What does not
    /// fit in the rows available is folded into "more" nodes, smallest first.
    static func hierarchyScene(_ input: LayoutInput, born: (NodeID) -> Float) -> LayoutScene {
        var scene = LayoutScene()

        struct Domain {
            var name: String
            var filter: String
            var aggregate = Aggregate()
            var addresses: [IPAddress: Aggregate] = [:]
            var shown = 0
        }
        struct Branch {
            var aggregate = Aggregate()
            var domains: [String: Domain] = [:]
            var order: [String] = []
            var domainsShown = 0
        }
        var branches: [Int32: Branch] = [:]
        for (key, aggregate) in input.byAddressEdge {
            for flow in aggregate.flows {
                let life = flow.state == .closed ? aggregate.life : 1
                let (name, filter) = hierarchyDomain(flow)
                branches[key.pid, default: Branch()].aggregate.add(flow, life: life)
                branches[key.pid]!.domains[name, default: Domain(name: name, filter: filter)].aggregate.add(flow, life: life)
                branches[key.pid]!.domains[name]!.addresses[key.address, default: Aggregate()].add(flow, life: life)
            }
        }
        func user(_ pid: Int32) -> String {
            let record = input.processes[pid]
            return record?.username ?? record?.uid.map { "uid \($0)" } ?? "unknown account"
        }

        // Which processes get a branch of their own.
        // Each kept process needs at least two rows (its largest domain and a "more"), and
        // each account with folded processes one, so the limit gives way to the budget.
        let accounts = Set(branches.keys.map(user)).count
        let limit = min(hierarchyProcessLimit, max(1, (hierarchyLeafBudget - accounts) / 2))
        let kept = Set(branches.keys.sorted { (branches[$0]!.aggregate.bytes, $1) > (branches[$1]!.aggregate.bytes, $0) }
            .prefix(limit))
        var foldedProcesses: [String: [Int32]] = [:]
        for pid in branches.keys where !kept.contains(pid) { foldedProcesses[user(pid), default: []].append(pid) }

        // Every kept process shows its largest domain; then domains are added, largest
        // first, while there are rows to spare. A process with domains left over has a
        // "more" row, which counts too.
        for pid in kept {
            let order = branches[pid]!.domains.keys.sorted { a, b in
                let x = branches[pid]!.domains[a]!.aggregate.bytes, y = branches[pid]!.domains[b]!.aggregate.bytes
                return x != y ? x > y : a < b
            }
            branches[pid]!.order = order
            branches[pid]!.domainsShown = 1
        }
        func rows() -> Int {
            var count = foldedProcesses.count
            for pid in kept {
                let branch = branches[pid]!
                for name in branch.order.prefix(branch.domainsShown) {
                    let domain = branch.domains[name]!
                    count += max(1, domain.shown + (domain.addresses.count > domain.shown && domain.shown > 0 ? 1 : 0))
                }
                if branch.order.count > branch.domainsShown { count += 1 }
            }
            return count
        }
        var candidates: [(pid: Int32, rank: Int, bytes: UInt64)] = []
        for pid in kept {
            for (rank, name) in branches[pid]!.order.enumerated().dropFirst() {
                candidates.append((pid, rank, branches[pid]!.domains[name]!.aggregate.bytes))
            }
        }
        candidates.sort { ($0.bytes, $1.pid, $1.rank) > ($1.bytes, $0.pid, $0.rank) }
        for candidate in candidates where branches[candidate.pid]!.domainsShown == candidate.rank {
            branches[candidate.pid]!.domainsShown += 1
            if rows() > hierarchyLeafBudget {
                branches[candidate.pid]!.domainsShown -= 1
                break
            }
        }
        // Then shown domains open into their addresses, largest domains first.
        var opening: [(pid: Int32, name: String, bytes: UInt64)] = []
        for pid in kept {
            let branch = branches[pid]!
            for name in branch.order.prefix(branch.domainsShown) { opening.append((pid, name, branch.domains[name]!.aggregate.bytes)) }
        }
        opening.sort { ($0.bytes, $1.pid, $1.name) > ($1.bytes, $0.pid, $0.name) }
        for entry in opening {
            let count = branches[entry.pid]!.domains[entry.name]!.addresses.count
            branches[entry.pid]!.domains[entry.name]!.shown = min(count, hierarchyAddressesPerDomain)
            if rows() > hierarchyLeafBudget { branches[entry.pid]!.domains[entry.name]!.shown = 0 }
        }

        // Lay the tree out: leaves top to bottom, each parent level with its children.
        let columns: [Float] = [-540, -300, 0, 320]
        let spacing: Float = 21
        let total = rows()
        var cursor = Float(total - 1) / 2 * spacing
        var drawn: [(id: NodeID, parent: NodeID?, column: Int, y: Float, aggregate: Aggregate, label: String, filter: String?)] = []
        func leaf() -> Float {
            defer { cursor -= spacing }
            return cursor
        }
        func path(_ parts: String...) -> NodeID { .group(.path, parts.joined(separator: "|")) }
        func addresses(_ list: [IPAddress]) -> [IPAddress] { list.sorted { $0.networkBytes.lexicographicallyPrecedes($1.networkBytes) } }

        let users = Set(kept.map(user)).union(foldedProcesses.keys).sorted { $0.lowercased() < $1.lowercased() }
        for account in users {
            let userID = NodeID.group(.user, account)
            var userAggregate = Aggregate()
            var children: [Float] = []
            let mine = kept.filter { user($0) == account }.sorted { a, b in
                let x = input.processes[a]?.name.lowercased() ?? "", y = input.processes[b]?.name.lowercased() ?? ""
                return (x, a) < (y, b)
            }
            for pid in mine {
                let branch = branches[pid]!
                userAggregate.merge(branch.aggregate)
                var processChildren: [Float] = []
                for name in branch.order.prefix(branch.domainsShown) {
                    let domain = branch.domains[name]!
                    let domainID = path("\(pid)", name)
                    var domainY: Float
                    if domain.shown > 0 {
                        let order = domain.addresses.keys.sorted { a, b in
                            let x = domain.addresses[a]!.bytes, y = domain.addresses[b]!.bytes
                            return x != y ? x > y : a.networkBytes.lexicographicallyPrecedes(b.networkBytes)
                        }
                        var ys: [Float] = []
                        for address in order.prefix(domain.shown) {
                            let id = path("\(pid)", name, address.description)
                            let y = leaf()
                            ys.append(y)
                            let aggregate = domain.addresses[address]!
                            drawn.append((id, domainID, 3, y, aggregate, address.description, "pid=\(pid) remote=\(address)"))
                            scene.members[id] = [address]
                            scene.connectionNodes[AddressEdge(pid: pid, address: address)] = id
                        }
                        let rest = order.dropFirst(domain.shown)
                        if !rest.isEmpty {
                            let id = path("\(pid)", name, "+")
                            let y = leaf()
                            ys.append(y)
                            var aggregate = Aggregate()
                            for address in rest {
                                aggregate.merge(domain.addresses[address]!)
                                scene.connectionNodes[AddressEdge(pid: pid, address: address)] = id
                            }
                            drawn.append((id, domainID, 3, y, aggregate, "\(rest.count) more", nil))
                            scene.members[id] = addresses(Array(rest))
                        }
                        domainY = (ys.first! + ys.last!) / 2
                    } else {
                        domainY = leaf()
                        for address in domain.addresses.keys { scene.connectionNodes[AddressEdge(pid: pid, address: address)] = domainID }
                    }
                    processChildren.append(domainY)
                    let label = domain.addresses.count > 1 && domain.shown == 0 ? "\(name) ×\(domain.addresses.count)" : name
                    drawn.append((domainID, .process(pid), 2, domainY, domain.aggregate, label, "pid=\(pid) \(domain.filter)"))
                    scene.members[domainID] = addresses(Array(domain.addresses.keys))
                }
                let restNames = branch.order.dropFirst(branch.domainsShown)
                if !restNames.isEmpty {
                    let id = path("\(pid)", "+")
                    let y = leaf()
                    processChildren.append(y)
                    var aggregate = Aggregate()
                    var members: [IPAddress] = []
                    for name in restNames {
                        let domain = branch.domains[name]!
                        aggregate.merge(domain.aggregate)
                        members.append(contentsOf: domain.addresses.keys)
                        for address in domain.addresses.keys { scene.connectionNodes[AddressEdge(pid: pid, address: address)] = id }
                    }
                    drawn.append((id, .process(pid), 2, y, aggregate, "\(restNames.count) more domains", nil))
                    scene.members[id] = addresses(members)
                }
                let processY = (processChildren.first! + processChildren.last!) / 2
                children.append(processY)
                drawn.append((.process(pid), userID, 1, processY, branch.aggregate, "", "pid=\(pid)"))
            }
            if let folded = foldedProcesses[account] {
                let id = path(account, "+")
                let y = leaf()
                children.append(y)
                var aggregate = Aggregate()
                for pid in folded {
                    aggregate.merge(branches[pid]!.aggregate)
                    for key in input.byAddressEdge.keys where key.pid == pid { scene.connectionNodes[key] = id }
                }
                userAggregate.merge(aggregate)
                drawn.append((id, userID, 1, y, aggregate, "\(folded.count) other processes", nil))
            }
            let userY = (children.first! + children.last!) / 2
            drawn.append((userID, nil, 0, userY, userAggregate, account, "user=\"\(account)\""))
        }

        // Nodes, in column order so processes are counted where the renderer expects them.
        scene.nodes.append(Node(
            id: .host, position: input.previous[.host]?.position ?? SIMD2(columns[0] - 230, 0), anchor: SIMD2(columns[0] - 230, 0),
            radius: 9, color: input.scheme.host, intensity: 1, bornAt: -100, label: input.hostLabel, priority: .infinity, labelSide: 0))
        for column in [1, 0, 2, 3] {
            for entry in drawn where entry.column == column {
                let anchor = SIMD2(columns[column], entry.y)
                let start = input.previous[entry.id]?.position ?? SIMD2(columns[max(column - 1, 0)], entry.y)
                if case .process(let pid) = entry.id {
                    scene.nodes.append(processNode(
                        input, pid: pid, aggregate: entry.aggregate, anchor: anchor,
                        radius: 4 + 4 * level(Double(entry.aggregate.bytes), scale: 9), bornAt: born(entry.id)))
                    scene.nodes[scene.nodes.count - 1].position = start
                    scene.processCount += 1
                } else {
                    // Accounts are labelled on the left, where nothing else is; the rest on the right.
                    let leftLabel = column == 0
                    scene.nodes.append(Node(
                        id: entry.id, position: start, anchor: anchor,
                        radius: column == 0 ? 7 : 2.5 + 4 * level(Double(entry.aggregate.bytes), scale: 9),
                        color: column == 0 ? input.scheme.process : input.scheme.color(forService: entry.aggregate.service),
                        intensity: (0.35 + 0.6 * level(entry.aggregate.rate, scale: 6.5)) * Float(max(entry.aggregate.life, 0.2)),
                        bornAt: born(entry.id), label: clip(entry.label, to: 34),
                        priority: column == 0 ? 1e13 : 2 + Double(entry.aggregate.bytes), labelSide: leftLabel ? -1 : 1))
                    scene.nodeAggregates[entry.id] = entry.aggregate
                    scene.labels[entry.id] = entry.label
                }
                if let filter = entry.filter { scene.filters[entry.id] = filter }
            }
        }
        // Users come first in the list, but processes must follow the host directly.
        var lookup: [NodeID: Int] = [:]
        for (offset, node) in scene.nodes.enumerated() { lookup[node.id] = offset }
        for entry in drawn {
            guard let parent = entry.parent, let from = lookup[parent], let to = lookup[entry.id] else { continue }
            let trunk = entry.column == 1
            var edge = edge(
                from: from, to: to, target: .edge(parent, entry.id), aggregate: entry.aggregate,
                color: trunk ? input.scheme.trunk : input.scheme.color(forService: entry.aggregate.service),
                seed: "\(parent) \(entry.id)", bend: 0, outbound: entry.aggregate.rateOut >= entry.aggregate.rateIn, trunk: trunk)
            edge.halfWidth = min(edge.halfWidth, 3)
            // A tree is read for its shape; its pulses are kept quiet so the labels stay legible.
            edge.pulse *= 0.45
            edge.glow *= 0.75
            edge.density = 1
            scene.edges.append(edge)
            scene.edgeAggregates[EdgeKey(from: parent, to: entry.id)] = entry.aggregate
        }
        for entry in drawn where entry.column == 0 {
            guard let to = lookup[entry.id] else { continue }
            scene.edges.append(edge(
                from: 0, to: to, target: .node(entry.id), aggregate: entry.aggregate, color: input.scheme.trunk,
                seed: "host \(entry.id)", bend: 0, outbound: entry.aggregate.rateOut >= entry.aggregate.rateIn, trunk: true))
        }
        scene.halfSize = SIMD2(800, max(260, Float(total) * spacing / 2 + 50))
        return scene
    }
}
