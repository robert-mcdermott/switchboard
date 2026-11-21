import Foundation

public struct EngineConfiguration: Sendable {
    /// Half-life of the displayed rate, in seconds.
    public var rateHalfLife = 1.0
    /// A flow with no traffic for this long is idle.
    public var idleAfter = 5.0
    /// How long a closed flow stays in the model before it is purged.
    public var fadeWindow = 30.0
    /// Flows first seen this soon after start, with no age from the source, already
    /// existed; their age is a lower bound.
    public var warmup = 3.0

    public init() {}
}

/// What one tick changed.
public struct EngineDelta: Sendable, Equatable {
    public var opened: [FlowID] = []
    public var updated: [FlowID] = []
    public var closed: [FlowID] = []
    public var purged: [FlowID] = []
    public var listenersChanged = false

    public init() {}

    public var isEmpty: Bool {
        opened.isEmpty && updated.isEmpty && closed.isEmpty && purged.isEmpty && !listenersChanged
    }
}

public struct EngineSnapshot: Sendable, Codable {
    public var time: EngineTime
    /// Seconds since 1970 at `time`.
    public var wallClock: Double
    public var flows: [Flow]
    public var listeners: [Listener]
    public var processes: [ProcessRecord]
    /// The most recent DNS answers seen, oldest first.
    public var dns: [DNSRecord] = []

    public init(
        time: EngineTime, wallClock: Double, flows: [Flow], listeners: [Listener], processes: [ProcessRecord],
        dns: [DNSRecord] = []
    ) {
        self.time = time
        self.wallClock = wallClock
        self.flows = flows
        self.listeners = listeners
        self.processes = processes
        self.dns = dns
    }
}

/// Turns socket observations into flows with lifecycle, rates, and attribution.
///
/// The engine is deterministic: the same events at the same times always produce the
/// same model, which is what lets recorded traces serve as tests. It is not thread-safe;
/// one owner drives it.
public final class FlowEngine {
    public var configuration: EngineConfiguration
    private let resolver: ProcessResolver
    /// Supplies location, network owner, and tags for remote addresses, when set.
    public var enricher: (any AddressEnricher)?

    public private(set) var flows: [FlowID: Flow] = [:]
    public private(set) var listeners: [FlowID: Listener] = [:]
    public private(set) var processes: [Int32: ProcessRecord] = [:]
    /// Bumped whenever `processes` changes, so snapshots can share one sorted copy of it:
    /// it rarely changes, and a second's history then costs nothing for processes.
    private var processesVersion = 0
    private var processesShared: (version: Int, list: [ProcessRecord]) = (-1, [])
    public private(set) var now: EngineTime = 0
    /// Seconds since 1970 at engine time zero.
    public var wallClockOrigin: Double = 0

    private struct SourceKey: Hashable {
        var source: String
        var id: UInt64
    }

    private enum Entry {
        case flow(FlowID)
        case listener(FlowID)
        /// Reported by this source, but another source already owns the same flow.
        case shadow
    }

    private struct Meters {
        var rx = RateEstimator()
        var tx = RateEstimator()
    }

    private struct ListenerKey: Hashable {
        var proto: TransportProtocol
        var local: Endpoint
        var pid: Int32
    }

    private struct PortKey: Hashable {
        var proto: TransportProtocol
        var port: UInt16
        var pid: Int32
    }

    private struct OwnedKey: Hashable {
        var key: FlowKey
        var pid: Int32
    }

    private var entries: [SourceKey: Entry] = [:]
    private var meters: [FlowID: Meters] = [:]
    private var openFlowsByKey: [OwnedKey: FlowID] = [:]
    private var listenersByKey: [ListenerKey: FlowID] = [:]
    private var listeningPorts: [PortKey: Int] = [:]
    private var nextID: FlowID = 1

    // Learned from packets.
    private struct Asker: Hashable {
        var pid: Int32
        var address: IPAddress
    }

    private var namesByAddress: [IPAddress: (name: String, source: NameSource)] = [:]
    private var namesByAsker: [Asker: String] = [:]
    /// Keyed both ways round, since a packet does not say which end is ours.
    private var serverNames: [FlowKey: String] = [:]
    private var observedServices: [FlowKey: String] = [:]
    public private(set) var dnsLog: [DNSRecord] = []
    private var nextDNSRecord: UInt64 = 1
    /// Each table is emptied when it reaches this size. Crude, but it cannot grow without limit.
    private static let nameTableLimit = 20_000
    private static let dnsLogLimit = 200
    private var startedAt: EngineTime?
    private var openedThisTick = Set<FlowID>()

    public init(configuration: EngineConfiguration = EngineConfiguration(), resolver: ProcessResolver = PassthroughProcessResolver()) {
        self.configuration = configuration
        self.resolver = resolver
    }

    // MARK: - Ingest

    /// Applies one source's events, then advances every flow's lifecycle to `now`.
    @discardableResult
    public func ingest(_ events: [SourceEvent], from source: String, at now: EngineTime) -> EngineDelta {
        self.now = now
        if startedAt == nil { startedAt = now }
        var delta = EngineDelta()
        var touched = Set<FlowID>()
        let previouslyNew = openedThisTick
        openedThisTick.removeAll(keepingCapacity: true)

        for event in events {
            switch event {
            case .seen(let observation):
                apply(observation, source: source, delta: &delta, touched: &touched)
            case .removed(let id):
                remove(SourceKey(source: source, id: id), delta: &delta)
            }
        }

        sweep(delta: &delta, touched: &touched, previouslyNew: previouslyNew)
        delta.updated = touched.subtracting(delta.opened).subtracting(delta.closed).sorted()
        return delta
    }

    private func apply(_ observation: SocketObservation, source: String, delta: inout EngineDelta, touched: inout Set<FlowID>) {
        let sourceKey = SourceKey(source: source, id: observation.sourceID)
        let kind = classify(observation)

        // A socket can change what it is: a UDP socket connects, a listener's slot is reused.
        if let existing = entries[sourceKey] {
            switch (existing, kind) {
            case (.flow(let id), .flow):
                if let flow = flows[id], flow.key == key(of: observation), flow.pid == observation.pid {
                    if update(id, with: observation) {
                        touched.insert(id)
                        return
                    }
                    // Counter went backwards: the source reused the identity for a new socket.
                }
                remove(sourceKey, delta: &delta)
            case (.listener(let id), .listener):
                if var listener = listeners[id], listener.local == observation.local, listener.pid == observation.pid {
                    listener.bytesIn = observation.rxBytes
                    listener.bytesOut = observation.txBytes
                    if let age = observation.ageSeconds { listener.firstSeen = now - age }
                    listeners[id] = listener
                    return
                }
                remove(sourceKey, delta: &delta)
            case (.shadow, _):
                // Re-evaluate below: the owning source may have let go.
                entries[sourceKey] = nil
            default:
                remove(sourceKey, delta: &delta)
            }
        }

        switch kind {
        case .flow:
            open(observation, sourceKey: sourceKey, delta: &delta)
        case .listener:
            listen(observation, sourceKey: sourceKey, delta: &delta)
        case .ignored:
            break
        }
    }

    private enum Kind { case flow, listener, ignored }

    private func classify(_ observation: SocketObservation) -> Kind {
        switch observation.proto {
        case .tcp:
            if observation.tcpState == .listen { return .listener }
            // Bound but neither listening nor connected: not yet anything worth showing.
            return observation.remote.isWildcard ? .ignored : .flow
        case .udp:
            return observation.remote.isWildcard ? .listener : .flow
        }
    }

    private func key(of observation: SocketObservation) -> FlowKey {
        FlowKey(proto: observation.proto, local: observation.local, remote: observation.remote)
    }

    private func open(_ observation: SocketObservation, sourceKey: SourceKey, delta: inout EngineDelta) {
        let flowKey = key(of: observation)
        let owned = OwnedKey(key: flowKey, pid: observation.pid)
        if openFlowsByKey[owned] != nil {
            entries[sourceKey] = .shadow
            return
        }

        let id = nextID
        nextID += 1
        ensureProcess(observation)

        let firstSeen: EngineTime
        let ageExact: Bool
        if let age = observation.ageSeconds {
            firstSeen = now - age
            ageExact = true
        } else {
            firstSeen = now
            ageExact = now - (startedAt ?? now) > configuration.warmup
        }

        var service: String?
        var basis: ServiceBasis?
        if let hint = observation.serviceHint {
            service = hint
            basis = .heuristic
        } else if let named = ServiceTable.service(for: flowKey) {
            service = named
            basis = .port
        }
        if let seen = observedServices[flowKey] { (service, basis) = Self.merge(observed: seen, with: service) }
        let named = name(for: flowKey, pid: observation.pid)

        // A connection we watched open is active by nature. One that predates us is
        // idle until its counters prove otherwise.
        let longStanding = (observation.ageSeconds ?? 0) > configuration.idleAfter || !ageExact
        let lastActive = longStanding ? now - configuration.idleAfter - 1 : now

        let inbound = listeningPorts[PortKey(proto: observation.proto, port: observation.local.port, pid: observation.pid)] != nil
        var flow = Flow(
            id: id, key: flowKey, pid: observation.pid, direction: inbound ? .inbound : .outbound,
            interface: observation.interface, state: .new, tcpState: observation.tcpState,
            firstSeen: firstSeen, lastSeen: now, lastActive: lastActive, closedAt: nil, ageExact: ageExact,
            bytesIn: observation.rxBytes, bytesOut: observation.txBytes,
            packetsIn: observation.rxPackets, packetsOut: observation.txPackets, rateIn: 0, rateOut: 0,
            rttMS: observation.rttMS, retransmittedBytes: observation.retransmittedBytes,
            service: service, serviceBasis: basis, hostname: named?.name, hostnameSource: named?.source,
            attribution: sourceKey.source)
        if let enricher { Self.apply(enricher.facts(for: flowKey.remote.address), to: &flow) }
        if flow.tcpState?.isClosing == true { flow.state = .closing }

        var meter = Meters()
        meter.rx.update(count: observation.rxBytes, at: now, halfLife: configuration.rateHalfLife)
        meter.tx.update(count: observation.txBytes, at: now, halfLife: configuration.rateHalfLife)

        flows[id] = flow
        meters[id] = meter
        entries[sourceKey] = .flow(id)
        openFlowsByKey[owned] = id
        openedThisTick.insert(id)
        delta.opened.append(id)
    }

    /// Returns false if the counters went backwards, meaning this is a different socket.
    private func update(_ id: FlowID, with observation: SocketObservation) -> Bool {
        guard var flow = flows[id], var meter = meters[id] else { return false }
        let rx = meter.rx.update(count: observation.rxBytes, at: now, halfLife: configuration.rateHalfLife)
        let tx = meter.tx.update(count: observation.txBytes, at: now, halfLife: configuration.rateHalfLife)
        if rx == .reset || tx == .reset { return false }

        var moved = false
        if case .advanced(let bytes) = rx, bytes > 0 { moved = true }
        if case .advanced(let bytes) = tx, bytes > 0 { moved = true }
        if moved { flow.lastActive = now }

        flow.bytesIn = observation.rxBytes
        flow.bytesOut = observation.txBytes
        flow.packetsIn = observation.rxPackets
        flow.packetsOut = observation.txPackets
        flow.rateIn = meter.rx.rate
        flow.rateOut = meter.tx.rate
        flow.tcpState = observation.tcpState
        flow.lastSeen = now
        // A source may only learn a socket's true age after first reporting it.
        if !flow.ageExact, let age = observation.ageSeconds {
            flow.firstSeen = now - age
            flow.ageExact = true
        }
        if let interface = observation.interface { flow.interface = interface }
        if let rtt = observation.rttMS { flow.rttMS = rtt }
        if let retransmitted = observation.retransmittedBytes { flow.retransmittedBytes = retransmitted }

        flows[id] = flow
        meters[id] = meter
        return true
    }

    private func listen(_ observation: SocketObservation, sourceKey: SourceKey, delta: inout EngineDelta) {
        let listenerKey = ListenerKey(proto: observation.proto, local: observation.local, pid: observation.pid)
        if listenersByKey[listenerKey] != nil {
            entries[sourceKey] = .shadow
            return
        }
        let id = nextID
        nextID += 1
        ensureProcess(observation)
        listeners[id] = Listener(
            id: id, proto: observation.proto, local: observation.local, pid: observation.pid,
            bytesIn: observation.rxBytes, bytesOut: observation.txBytes,
            firstSeen: observation.ageSeconds.map { now - $0 } ?? now)
        listenersByKey[listenerKey] = id
        listeningPorts[PortKey(proto: observation.proto, port: observation.local.port, pid: observation.pid), default: 0] += 1
        entries[sourceKey] = .listener(id)
        delta.listenersChanged = true
    }

    private func remove(_ sourceKey: SourceKey, delta: inout EngineDelta) {
        guard let entry = entries.removeValue(forKey: sourceKey) else { return }
        switch entry {
        case .flow(let id):
            guard var flow = flows[id], flow.state != .closed else { return }
            flow.state = .closed
            flow.closedAt = now
            flow.rateIn = 0
            flow.rateOut = 0
            flows[id] = flow
            meters[id] = nil
            openFlowsByKey[OwnedKey(key: flow.key, pid: flow.pid)] = nil
            delta.closed.append(id)
        case .listener(let id):
            guard let listener = listeners.removeValue(forKey: id) else { return }
            listenersByKey[ListenerKey(proto: listener.proto, local: listener.local, pid: listener.pid)] = nil
            let port = PortKey(proto: listener.proto, port: listener.local.port, pid: listener.pid)
            if let count = listeningPorts[port] { listeningPorts[port] = count > 1 ? count - 1 : nil }
            delta.listenersChanged = true
        case .shadow:
            break
        }
    }

    private func ensureProcess(_ observation: SocketObservation) {
        if let known = processes[observation.pid],
           observation.uniquePID == nil || known.uniqueID == nil || known.uniqueID == observation.uniquePID
        {
            return
        }
        processes[observation.pid] = resolver.resolve(
            pid: observation.pid, name: observation.processName, uniqueID: observation.uniquePID)
        processesVersion &+= 1
    }

    // MARK: - Enrichment

    private static func apply(_ facts: AddressFacts, to flow: inout Flow) {
        flow.country = facts.country
        flow.city = facts.city
        flow.asn = facts.asn
        flow.org = facts.org
        flow.tags = facts.tags
        flow.latitude = facts.latitude
        flow.longitude = facts.longitude
    }

    /// Looks every connection up again, after a database or the tag lists have changed.
    public func refreshEnrichment() {
        for id in flows.keys {
            guard var flow = flows[id] else { continue }
            // With no enricher, what an earlier one said is taken away again.
            Self.apply(enricher?.facts(for: flow.key.remote.address) ?? AddressFacts(), to: &flow)
            flows[id] = flow
        }
    }

    /// Records the result of checking a process's code signature.
    public func setSigning(pid: Int32, status: SigningStatus, teamID: String?) {
        guard let known = processes[pid], known.signing != status || known.teamID != teamID else { return }
        processes[pid]?.signing = status
        processes[pid]?.teamID = teamID
        processesVersion &+= 1
    }

    // MARK: - Names and services from packets

    /// Applies what packet capture learned: hostnames from DNS and TLS, and what the
    /// traffic on a connection was seen to be.
    public func observe(_ observations: [CaptureObservation], at now: EngineTime) {
        for observation in observations {
            switch observation {
            case .resolved(let name, let addresses, let pid):
                guard !name.isEmpty, !addresses.isEmpty else { continue }
                if namesByAddress.count >= Self.nameTableLimit { namesByAddress.removeAll() }
                if namesByAsker.count >= Self.nameTableLimit { namesByAsker.removeAll() }
                for address in addresses {
                    // A name from a TLS handshake is specific to its connection; a DNS
                    // answer is the better general name for the address.
                    namesByAddress[address] = (name, .dns)
                    if let pid { namesByAsker[Asker(pid: pid, address: address)] = name }
                }
                dnsLog.append(DNSRecord(id: nextDNSRecord, time: now, name: name, addresses: addresses, pid: pid))
                nextDNSRecord += 1
                if dnsLog.count > Self.dnsLogLimit { dnsLog.removeFirst(dnsLog.count - Self.dnsLogLimit) }
                // Connections already open to these addresses, and not yet named, take the name.
                let resolved = Set(addresses)
                for (id, flow) in flows where flow.hostnameSource != .sni && resolved.contains(flow.key.remote.address) {
                    if pid == nil || pid == flow.pid || flow.hostname == nil {
                        flows[id]?.hostname = name
                        flows[id]?.hostnameSource = .dns
                    }
                }

            case .serverName(let proto, let from, let to, let name):
                guard !name.isEmpty else { continue }
                if serverNames.count >= Self.nameTableLimit { serverNames.removeAll() }
                let forward = FlowKey(proto: proto, local: from, remote: to)
                let backward = FlowKey(proto: proto, local: to, remote: from)
                serverNames[forward] = name
                serverNames[backward] = name
                for (id, flow) in flows where flow.key == forward || flow.key == backward {
                    flows[id]?.hostname = name
                    flows[id]?.hostnameSource = .sni
                    // With nothing better known, the name also stands for the address.
                    if namesByAddress[flow.key.remote.address] == nil {
                        namesByAddress[flow.key.remote.address] = (name, .sni)
                    }
                }

            case .reverse(let address, let name):
                // A reverse lookup is the weakest kind of name: it only fills a gap.
                guard !name.isEmpty, namesByAddress[address] == nil else { continue }
                if namesByAddress.count >= Self.nameTableLimit { namesByAddress.removeAll() }
                namesByAddress[address] = (name, .ptr)
                for (id, flow) in flows where flow.hostname == nil && flow.key.remote.address == address {
                    flows[id]?.hostname = name
                    flows[id]?.hostnameSource = .ptr
                }

            case .service(let proto, let from, let to, let service):
                if observedServices.count >= Self.nameTableLimit { observedServices.removeAll() }
                let forward = FlowKey(proto: proto, local: from, remote: to)
                let backward = FlowKey(proto: proto, local: to, remote: from)
                observedServices[forward] = service
                observedServices[backward] = service
                for (id, flow) in flows where flow.key == forward || flow.key == backward {
                    let merged = Self.merge(observed: service, with: flow.service)
                    flows[id]?.service = merged.0
                    flows[id]?.serviceBasis = merged.1
                }
            }
        }
    }

    /// The best name for a connection: its own TLS server name, then what this process
    /// was told by DNS, then what anyone was told.
    private func name(for key: FlowKey, pid: Int32) -> (name: String, source: NameSource)? {
        if let name = serverNames[key] { return (name, .sni) }
        if let name = namesByAsker[Asker(pid: pid, address: key.remote.address)] { return (name, .dns) }
        return namesByAddress[key.remote.address]
    }

    /// Seeing TLS on a connection confirms a port-based guess such as HTTPS without
    /// replacing its more specific name; anything else observed replaces a guess.
    private static func merge(observed: String, with current: String?) -> (String?, ServiceBasis?) {
        let overTLS: Set<String> = ["HTTPS", "HTTPS-alt", "IMAPS", "SMTPS", "POP3S", "LDAPS", "MQTT-TLS", "APNs", "FCM", "DNS-over-TLS"]
        if observed == "TLS", let current, overTLS.contains(current) { return (current, .observed) }
        return (observed, .observed)
    }

    // MARK: - Lifecycle

    private func sweep(delta: inout EngineDelta, touched: inout Set<FlowID>, previouslyNew: Set<FlowID>) {
        var purged: [FlowID] = []
        for (id, flow) in flows {
            if flow.state == .closed {
                if let closedAt = flow.closedAt, now - closedAt > configuration.fadeWindow { purged.append(id) }
                continue
            }
            let state: FlowState
            if flow.tcpState?.isClosing == true {
                state = .closing
            } else if openedThisTick.contains(id) {
                state = .new
            } else if now - flow.lastActive <= configuration.idleAfter {
                state = .active
            } else {
                state = .idle
            }
            if state != flow.state {
                flows[id]?.state = state
                touched.insert(id)
            } else if previouslyNew.contains(id) {
                touched.insert(id)
            }
        }
        for id in purged { flows[id] = nil }
        delta.purged = purged.sorted()

        if !purged.isEmpty || delta.listenersChanged {
            var referenced = Set(flows.values.map(\.pid))
            referenced.formUnion(listeners.values.map(\.pid))
            let kept = processes.filter { referenced.contains($0.key) }
            if kept.count != processes.count {
                processes = kept
                processesVersion &+= 1
            }
        }
    }

    // MARK: - Reading

    public func snapshot() -> EngineSnapshot {
        if processesShared.version != processesVersion {
            processesShared = (processesVersion, processes.values.sorted { $0.pid < $1.pid })
        }
        return EngineSnapshot(
            time: now,
            wallClock: wallClockOrigin + now,
            flows: flows.values.sorted { $0.id < $1.id },
            listeners: listeners.values.sorted { $0.id < $1.id },
            processes: processesShared.list,
            dns: dnsLog)
    }
}
