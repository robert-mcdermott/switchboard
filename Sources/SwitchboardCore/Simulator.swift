import Foundation

/// Synthetic traffic, for development, demos, benchmarks, and tests that must not depend
/// on what the machine happens to be doing. Deterministic for a given scenario and seed
/// when polled at the same times.
public final class SimulatorSource: FlowSource, CaptureProvider, @unchecked Sendable {
    public enum Scenario: String, CaseIterable, Sendable {
        /// A few apps, a couple of dozen connections.
        case quiet
        /// Browser, chat, editors, containers: a few hundred connections with steady churn.
        case developer
        /// Thousands of flows, for performance work.
        case stress
        /// A quiet machine plus one process phoning home on a fixed period.
        case beacon
        /// A quiet machine plus one process sweeping ports on a single host.
        case portscan
    }

    private enum Behaviour {
        case steady
        case beacon(period: Double)
        case scan(perSecond: Double)
    }

    private struct ProcessSpec {
        var pid: Int32
        var name: String
        var behaviour: Behaviour = .steady
        /// Connections held open on average.
        var target: Int
        var meanLifetime: Double
        /// Typical bytes per second of a busy connection.
        var rate: Double
        var ports: [(proto: TransportProtocol, port: UInt16)]
        var listeners: [UInt16] = []
        var peers: [IPAddress] = []
        var nextEventAt: Double = 0
        var scanPort: UInt16 = 1
    }

    private struct LiveSocket {
        var observation: SocketObservation
        var rxRate: Double
        var txRate: Double
        var diesAt: Double
        var openedAt: Double
    }

    public let name = "sim"
    public let scenario: Scenario

    private let lock = NSLock()
    private var random: SplitMix64
    private var specs: [ProcessSpec] = []
    private var sockets: [UInt64: LiveSocket] = [:]
    private var order: [UInt64] = []
    private var nextSourceID: UInt64 = 1
    private var nextLocalPort: UInt16 = 49_152
    private var lastPoll: Double?
    private var running = false
    private let localV4 = IPAddress.v4(0x0A00_0024)  // 10.0.0.36
    private var pendingCapture: [CaptureObservation] = []
    private var named = Set<IPAddress>()

    /// What packet capture would have learned about the simulated traffic.
    public func pollCapture(now: EngineTime) -> [CaptureObservation] {
        lock.lock()
        defer { lock.unlock() }
        let drained = pendingCapture
        pendingCapture.removeAll(keepingCapacity: true)
        return drained
    }

    /// An invented name for an address, always the same one, under domains reserved for examples.
    static func hostname(for address: IPAddress) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in address.networkBytes { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        hash ^= hash >> 29
        let hosts = ["api", "cdn", "edge", "static", "media", "auth", "sync", "push", "img", "telemetry"]
        let domains = ["example.com", "example.net", "example.org", "cloud.example", "video.example", "mail.example"]
        return "\(hosts[Int(hash % 10)])-\((hash >> 8) % 90 + 10).\(domains[Int((hash >> 20) % 6)])"
    }

    public init(scenario: Scenario, seed: UInt64 = 0x5B17_C0DE, flows: Int? = nil) {
        self.scenario = scenario
        random = SplitMix64(seed: seed)
        specs = Self.makeSpecs(scenario, flows: flows, random: &random)
    }

    public func start() throws {
        lock.lock()
        running = true
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        running = false
        lock.unlock()
    }

    public var health: SourceHealth {
        lock.lock()
        defer { lock.unlock() }
        return SourceHealth(running: running, detail: "\(scenario.rawValue): \(sockets.count) sockets")
    }

    public func poll(now: EngineTime) -> [SourceEvent] {
        lock.lock()
        defer { lock.unlock() }
        var events: [SourceEvent] = []

        guard let last = lastPoll else {
            // First poll: the machine was already busy before we looked.
            lastPoll = now
            for index in specs.indices {
                for port in specs[index].listeners { openListener(index, port: port, now: now) }
                guard case .steady = specs[index].behaviour else {
                    specs[index].nextEventAt = now + 1
                    continue
                }
                for _ in 0..<specs[index].target {
                    let age = random.double() * specs[index].meanLifetime
                    open(index, now: now, age: age)
                }
            }
            for id in order { if let socket = sockets[id] { events.append(.seen(socket.observation)) } }
            return events
        }

        let elapsed = max(0, now - last)
        lastPoll = now

        // Close what has run its course.
        var survivors: [UInt64] = []
        survivors.reserveCapacity(order.count)
        for id in order {
            guard let socket = sockets[id] else { continue }
            if socket.diesAt <= now {
                sockets[id] = nil
                events.append(.removed(sourceID: id))
            } else {
                survivors.append(id)
            }
        }
        order = survivors

        // Open new connections.
        for index in specs.indices {
            switch specs[index].behaviour {
            case .steady:
                let expected = Double(specs[index].target) / specs[index].meanLifetime * elapsed
                var count = Int(expected)
                if random.double() < expected - Double(count) { count += 1 }
                for _ in 0..<count { open(index, now: now, age: 0) }
            case .beacon(let period):
                while specs[index].nextEventAt <= now {
                    open(index, now: now, age: 0)
                    specs[index].nextEventAt += period
                }
            case .scan(let perSecond):
                while specs[index].nextEventAt <= now {
                    open(index, now: now, age: 0)
                    specs[index].nextEventAt += 1 / perSecond
                }
            }
        }

        // Move bytes.
        for id in order {
            guard var socket = sockets[id] else { continue }
            if socket.observation.tcpState != .listen, elapsed > 0 {
                // Traffic comes in bursts: most ticks carry little, a few carry a lot.
                let burst = random.double() < 0.35 ? random.double() * 2.4 : random.double() * 0.15
                let rx = UInt64(socket.rxRate * elapsed * burst)
                let tx = UInt64(socket.txRate * elapsed * burst)
                socket.observation.rxBytes += rx
                socket.observation.txBytes += tx
                socket.observation.rxPackets += rx / 1200 + (rx > 0 ? 1 : 0)
                socket.observation.txPackets += tx / 1200 + (tx > 0 ? 1 : 0)
            }
            socket.observation.ageSeconds = now - socket.openedAt
            sockets[id] = socket
            events.append(.seen(socket.observation))
        }
        return events
    }

    // MARK: - Internals

    private func allocate(_ observation: SocketObservation, rx: Double, tx: Double, diesAt: Double, openedAt: Double) {
        sockets[observation.sourceID] = LiveSocket(
            observation: observation, rxRate: rx, txRate: tx, diesAt: diesAt, openedAt: openedAt)
        order.append(observation.sourceID)
    }

    private func takeID() -> UInt64 {
        defer { nextSourceID += 1 }
        return nextSourceID
    }

    private func takePort() -> UInt16 {
        defer { nextLocalPort = nextLocalPort == 65_535 ? 49_152 : nextLocalPort + 1 }
        return nextLocalPort
    }

    private func openListener(_ index: Int, port: UInt16, now: Double) {
        let spec = specs[index]
        let observation = SocketObservation(
            sourceID: takeID(), proto: .tcp, local: Endpoint(address: .v4(0), port: port),
            remote: Endpoint(address: .v4(0), port: 0), pid: spec.pid, processName: spec.name,
            uniquePID: UInt64(spec.pid) + 1_000_000, tcpState: .listen, ageSeconds: 3600)
        allocate(observation, rx: 0, tx: 0, diesAt: .infinity, openedAt: now - 3600)
    }

    private func open(_ index: Int, now: Double, age: Double) {
        var spec = specs[index]
        defer { specs[index] = spec }

        var service = spec.ports[random.below(spec.ports.count)]
        var peer = spec.peers[random.below(spec.peers.count)]
        var lifetime = -log(max(random.double(), 1e-9)) * spec.meanLifetime
        // A few connections carry most of the traffic.
        var scale = pow(random.double(), 4)

        switch spec.behaviour {
        case .steady:
            break
        case .beacon:
            peer = spec.peers[0]
            lifetime = 1.5
            scale = 0.02
        case .scan:
            peer = spec.peers[0]
            service = (.tcp, spec.scanPort)
            spec.scanPort = spec.scanPort == 1024 ? 1 : spec.scanPort + 1
            lifetime = 0.3
            scale = 0
        }

        let observation = SocketObservation(
            sourceID: takeID(), proto: service.proto,
            local: Endpoint(address: peer.isIPv6 ? .v6(hi: 0x2601_0602_8182_9b00, lo: 0x24) : localV4, port: takePort()),
            remote: Endpoint(address: peer, port: service.port), pid: spec.pid, processName: spec.name,
            uniquePID: UInt64(spec.pid) + 1_000_000,
            rxBytes: UInt64(spec.rate * scale * age * 0.4), txBytes: UInt64(spec.rate * scale * age * 0.05),
            tcpState: service.proto == .tcp ? .established : nil, interface: "en0",
            rttMS: service.proto == .tcp ? 8 + random.double() * 60 : nil, retransmittedBytes: 0,
            ageSeconds: age)
        allocate(
            observation, rx: spec.rate * scale, tx: spec.rate * scale * 0.12,
            diesAt: now + max(lifetime - age, 0.2), openedAt: now - age)

        // A port scan resolves nothing and completes no handshakes.
        if case .scan = spec.behaviour { return }
        let name = Self.hostname(for: peer)
        if named.insert(peer).inserted {
            pendingCapture.append(.resolved(name: name, addresses: [peer], pid: spec.pid))
        }
        if service.port == 443 {
            if service.proto == .tcp {
                pendingCapture.append(.serverName(proto: .tcp, from: observation.local, to: observation.remote, name: name))
                pendingCapture.append(.service(proto: .tcp, from: observation.local, to: observation.remote, service: "TLS"))
            } else {
                pendingCapture.append(.service(proto: .udp, from: observation.local, to: observation.remote, service: "QUIC"))
            }
        }
    }

    private static func makeSpecs(_ scenario: Scenario, flows: Int?, random: inout SplitMix64) -> [ProcessSpec] {
        let web: [(TransportProtocol, UInt16)] = [(.tcp, 443), (.tcp, 443), (.tcp, 443), (.udp, 443), (.tcp, 80)]
        let api: [(TransportProtocol, UInt16)] = [(.tcp, 443)]

        func peers(_ count: Int, random: inout SplitMix64) -> [IPAddress] {
            (0..<count).map { _ in
                if random.double() < 0.2 {
                    return .v6(hi: 0x2600_1f14_0000_0000 | (random.next() & 0xffff_ffff), lo: random.next())
                }
                // Stay clear of private, loopback, and multicast space.
                let first = UInt32([13, 17, 23, 34, 52, 54, 104, 140, 142, 151, 172, 185, 199, 204][random.below(14)])
                return .v4(first << 24 | UInt32(random.next() & 0x00ff_ffff))
            }
        }

        var base: [ProcessSpec] = [
            ProcessSpec(pid: 501, name: "Safari", target: 10, meanLifetime: 40, rate: 400_000, ports: web),
            ProcessSpec(pid: 612, name: "Mail", target: 3, meanLifetime: 300, rate: 20_000, ports: [(.tcp, 993), (.tcp, 587)]),
            ProcessSpec(pid: 733, name: "cloudd", target: 4, meanLifetime: 120, rate: 60_000, ports: api),
            ProcessSpec(pid: 840, name: "Music", target: 2, meanLifetime: 200, rate: 300_000, ports: api),
            ProcessSpec(pid: 955, name: "mDNSResponder", target: 3, meanLifetime: 4, rate: 800, ports: [(.udp, 53)]),
            ProcessSpec(pid: 1021, name: "apsd", target: 1, meanLifetime: 3600, rate: 300, ports: [(.tcp, 5223)]),
        ]

        switch scenario {
        case .quiet:
            break
        case .developer, .stress:
            base += [
                ProcessSpec(pid: 2010, name: "Brave Browser Helper", target: 60, meanLifetime: 35, rate: 900_000, ports: web),
                ProcessSpec(pid: 2144, name: "Slack Helper", target: 12, meanLifetime: 240, rate: 40_000, ports: api),
                ProcessSpec(pid: 2290, name: "Cursor Helper", target: 18, meanLifetime: 90, rate: 120_000, ports: api, listeners: [8021]),
                ProcessSpec(pid: 2371, name: "node", target: 14, meanLifetime: 20, rate: 200_000, ports: [(.tcp, 443), (.tcp, 5432), (.tcp, 6379)], listeners: [3000, 5173]),
                ProcessSpec(pid: 2455, name: "com.docker.backend", target: 20, meanLifetime: 60, rate: 1_500_000, ports: api, listeners: [2375]),
                ProcessSpec(pid: 2530, name: "git-remote-https", target: 2, meanLifetime: 8, rate: 4_000_000, ports: api),
                ProcessSpec(pid: 2608, name: "ssh", target: 2, meanLifetime: 1800, rate: 3_000, ports: [(.tcp, 22)]),
                ProcessSpec(pid: 2717, name: "Dropbox", target: 8, meanLifetime: 400, rate: 250_000, ports: api, listeners: [17500]),
                ProcessSpec(pid: 2802, name: "zoom.us", target: 6, meanLifetime: 900, rate: 1_200_000, ports: [(.udp, 8801), (.tcp, 443)]),
                ProcessSpec(pid: 2915, name: "postgres", target: 0, meanLifetime: 60, rate: 0, ports: api, listeners: [5432]),
                ProcessSpec(pid: 3033, name: "Spotify Helper", target: 6, meanLifetime: 180, rate: 320_000, ports: api),
                ProcessSpec(pid: 3120, name: "tailscaled", target: 4, meanLifetime: 600, rate: 30_000, ports: [(.udp, 41641)]),
            ]
        case .beacon:
            base.append(ProcessSpec(
                pid: 4444, name: "updater-helper", behaviour: .beacon(period: 30), target: 0, meanLifetime: 2,
                rate: 12_000, ports: api))
        case .portscan:
            base.append(ProcessSpec(
                pid: 5555, name: "nmap", behaviour: .scan(perSecond: 60), target: 0, meanLifetime: 0.3,
                rate: 0, ports: [(.tcp, 1)]))
        }

        if scenario == .stress {
            // Pad with anonymous workers until the requested flow count is reached.
            let wanted = flows ?? 5000
            let have = base.reduce(0) { $0 + $1.target }
            let workers = 60
            let each = max(1, (wanted - have) / workers)
            for index in 0..<workers {
                base.append(ProcessSpec(
                    pid: Int32(6000 + index), name: "worker-\(index)", target: each, meanLifetime: 45,
                    rate: 150_000, ports: web))
            }
        } else if let flows {
            // Scale the scenario to the requested size.
            let have = max(1, base.reduce(0) { $0 + $1.target })
            for index in base.indices { base[index].target = base[index].target * flows / have }
        }

        for index in base.indices {
            let count: Int
            switch base[index].behaviour {
            // A very large run gets more distinct destinations per process, to fill the
            // graph with thousands of nodes; ordinary runs are unchanged.
            case .steady: count = max(2, min((flows ?? 0) >= 8000 ? 90 : 40, base[index].target / 2 + 2))
            case .beacon, .scan: count = 1
            }
            base[index].peers = peers(count, random: &random)
        }
        return base
    }
}
