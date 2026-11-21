import Foundation
import SwitchboardCore

/// Flows from Apple's private NetworkStatistics framework, the one behind `nettop`.
///
/// Unprivileged, it reports the login user's sockets; as root, nearly all of them
/// (docs/spikes/M0-findings.md). Sockets appear and disappear as events, and counters are
/// refreshed on every `poll`.
///
/// The framework is loaded with `dlopen` and never linked, so if Apple removes or changes
/// it, `start()` throws and the rest of Switchboard carries on with another source.
public final class NStatSource: FlowSource, @unchecked Sendable {
    public let name = "nstat"

    public enum NStatError: Error, CustomStringConvertible {
        case frameworkUnavailable(String)
        case missingSymbol(String)
        case managerCreationFailed

        public var description: String {
            switch self {
            case .frameworkUnavailable(let reason): "NetworkStatistics could not be loaded: \(reason)"
            case .missingSymbol(let name): "NetworkStatistics no longer exports \(name)"
            case .managerCreationFailed: "NetworkStatistics refused to create a manager"
            }
        }
    }

    private typealias Ref = UnsafeMutableRawPointer
    private typealias SourceAddedBlock = @convention(block) (Ref?, UnsafeMutableRawPointer?) -> Void
    private typealias DictionaryBlock = @convention(block) (CFDictionary?) -> Void
    private typealias VoidBlock = @convention(block) () -> Void
    private typealias CreateFn = @convention(c) (UnsafeRawPointer?, UnsafeMutableRawPointer, SourceAddedBlock) -> Ref?
    private typealias ManagerFn = @convention(c) (Ref) -> Void
    private typealias ManagerQueryFn = @convention(c) (Ref, VoidBlock?) -> Void
    private typealias SourceSetDictionaryFn = @convention(c) (Ref, DictionaryBlock) -> Void
    private typealias SourceSetVoidFn = @convention(c) (Ref, VoidBlock) -> Void
    private typealias SourceFn = @convention(c) (Ref) -> Void

    static let frameworkPath = "/System/Library/PrivateFrameworks/NetworkStatistics.framework/NetworkStatistics"

    /// Events queued by the framework's callbacks until the engine asks for them.
    private final class Inbox: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [SourceEvent] = []
        /// For each queued event, the socket's creation time in Mach ticks (0 if unknown).
        private var startTicks: [UInt64] = []
        private(set) var live = 0
        private(set) var total = 0
        private(set) var rejected = 0
        private(set) var rejectedSample: String?

        /// A description we could not turn into an observation.
        func reject(_ dictionary: NSDictionary) {
            lock.lock()
            rejected += 1
            if rejectedSample == nil {
                rejectedSample = dictionary.allKeys.map { "\($0)" }.sorted().map { key in
                    let value = dictionary[key]
                    return value is Data ? "\(key)=<\((value as? Data)?.count ?? 0) bytes>" : "\(key)=\(value ?? "nil")"
                }.joined(separator: " ")
            }
            lock.unlock()
        }

        func push(_ event: SourceEvent, startTicks ticks: UInt64 = 0) {
            lock.lock()
            events.append(event)
            startTicks.append(ticks)
            lock.unlock()
        }

        func sourceAdded() {
            lock.lock()
            live += 1
            total += 1
            lock.unlock()
        }

        func sourceRemoved() {
            lock.lock()
            live -= 1
            lock.unlock()
        }

        /// Hands over the queue. Ages are computed here, at the moment the engine takes
        /// the events, so time spent waiting in the queue does not make sockets look younger.
        func drain(clock: MachClock) -> [SourceEvent] {
            lock.lock()
            defer { lock.unlock() }
            var drained = events
            let machNow = mach_continuous_time()
            for index in drained.indices where startTicks[index] > 0 {
                if case .seen(var observation) = drained[index] {
                    observation.ageSeconds = clock.secondsSince(startTicks[index], now: machNow)
                    drained[index] = .seen(observation)
                }
            }
            events.removeAll(keepingCapacity: true)
            startTicks.removeAll(keepingCapacity: true)
            return drained
        }

        var counts: (live: Int, total: Int, rejected: Int, sample: String?) {
            lock.lock()
            defer { lock.unlock() }
            return (live, total, rejected, rejectedSample)
        }
    }

    private let inbox = Inbox()
    private let queue = DispatchQueue(label: "switchboard.nstat")
    private let lock = NSLock()
    private var manager: Ref?
    private var queryAllCounts: ManagerQueryFn?
    private var destroy: ManagerFn?
    private var failure: String?
    private let clock = MachClock()
    private var lastCounterQuery: EngineTime = -.infinity

    /// How often counters are refreshed, in seconds. Sockets opening and closing arrive
    /// as events regardless; this only sets how fresh the byte counts are. Asking the
    /// kernel to describe every socket is the dominant cost of this source.
    public let counterInterval: Double

    public init(counterInterval: Double = 1.0) {
        self.counterInterval = counterInterval
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard manager == nil else { return }
        do {
            try startLocked()
        } catch {
            failure = "\(error)"
            throw error
        }
    }

    private func startLocked() throws {
        guard let handle = dlopen(Self.frameworkPath, RTLD_NOW) else {
            throw NStatError.frameworkUnavailable(dlerror().map { String(cString: $0) } ?? "unknown error")
        }
        func symbol<T>(_ name: String, as type: T.Type) throws -> T {
            guard let address = dlsym(handle, name) else { throw NStatError.missingSymbol(name) }
            return unsafeBitCast(address, to: type)
        }
        let create = try symbol("NStatManagerCreate", as: CreateFn.self)
        let destroy = try symbol("NStatManagerDestroy", as: ManagerFn.self)
        let addAllTCP = try symbol("NStatManagerAddAllTCP", as: ManagerFn.self)
        let addAllUDP = try symbol("NStatManagerAddAllUDP", as: ManagerFn.self)
        let queryAllCounts = try symbol("NStatManagerQueryAllSources", as: ManagerQueryFn.self)
        let queryAllDescriptions = try symbol("NStatManagerQueryAllSourcesDescriptions", as: ManagerQueryFn.self)
        let setDescriptionBlock = try symbol("NStatSourceSetDescriptionBlock", as: SourceSetDictionaryFn.self)
        let setCountsBlock = try symbol("NStatSourceSetCountsBlock", as: SourceSetDictionaryFn.self)
        let setRemovedBlock = try symbol("NStatSourceSetRemovedBlock", as: SourceSetVoidFn.self)
        let queryDescription = try symbol("NStatSourceQueryDescription", as: SourceFn.self)

        let inbox = self.inbox
        let clock = self.clock
        let interfaces = InterfaceNames()

        let sourceAdded: SourceAddedBlock = { source, _ in
            guard let source else { return }
            let id = UInt64(UInt(bitPattern: source))
            inbox.sourceAdded()

            // Descriptions and counts carry the same keys, so one handler serves both.
            let onUpdate: DictionaryBlock = { dictionary in
                guard let dictionary = dictionary as NSDictionary? else { return }
                guard let observation = Self.observation(
                    from: dictionary, sourceID: id, clock: clock, interfaces: interfaces)
                else {
                    inbox.reject(dictionary)
                    return
                }
                let start = (dictionary["startAbsoluteTime"] as? NSNumber)?.uint64Value ?? 0
                inbox.push(.seen(observation), startTicks: start)
            }
            setDescriptionBlock(source, onUpdate)
            setCountsBlock(source, onUpdate)

            let onRemoved: VoidBlock = {
                inbox.sourceRemoved()
                inbox.push(.removed(sourceID: id))
            }
            setRemovedBlock(source, onRemoved)

            queryDescription(source)
        }

        guard let manager = create(nil, Unmanaged.passUnretained(queue).toOpaque(), sourceAdded) else {
            throw NStatError.managerCreationFailed
        }
        addAllTCP(manager)
        addAllUDP(manager)
        queryAllDescriptions(manager, nil)

        self.manager = manager
        self.queryAllCounts = queryAllCounts
        self.destroy = destroy
        failure = nil
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        if let manager, let destroy { destroy(manager) }
        manager = nil
    }

    public func poll(now: EngineTime) -> [SourceEvent] {
        lock.lock()
        let manager = self.manager
        let query = queryAllCounts
        lock.unlock()
        // Ask for fresh counters; they arrive on the queue and are collected next time.
        if let manager, let query, now - lastCounterQuery >= counterInterval - 0.01 {
            lastCounterQuery = now
            query(manager, nil)
        }
        return inbox.drain(clock: clock)
    }

    public var health: SourceHealth {
        lock.lock()
        defer { lock.unlock() }
        if let failure { return SourceHealth(running: false, detail: failure) }
        let counts = inbox.counts
        return SourceHealth(
            running: manager != nil,
            detail: "\(counts.live) sockets tracked, \(counts.total) seen" + (getuid() == 0 ? "" : " (login user only)")
                + (counts.rejected > 0 ? ", \(counts.rejected) updates unreadable" : ""))
    }

    /// One update the decoder could not use, for diagnosing a format change.
    public var rejectedSample: String? {
        inbox.counts.sample
    }

    // MARK: - Decoding

    /// Converts kernel timestamps, which count in Mach ticks, to seconds.
    ///
    /// Socket start times are on the continuous clock, the one that keeps counting while
    /// the machine sleeps. Measured against the other Mach clock they land in the future
    /// on any Mac that has slept since boot.
    struct MachClock: Sendable {
        let secondsPerTick: Double

        init() {
            var info = mach_timebase_info_data_t()
            mach_timebase_info(&info)
            secondsPerTick = Double(info.numer) / Double(info.denom) / 1e9
        }

        init(secondsPerTick: Double) { self.secondsPerTick = secondsPerTick }

        func secondsSince(_ ticks: UInt64, now: UInt64 = mach_continuous_time()) -> Double? {
            guard ticks > 0, now >= ticks else { return nil }
            return Double(now - ticks) * secondsPerTick
        }
    }

    /// Interface index to name, cached, since the same few indexes recur constantly.
    final class InterfaceNames: @unchecked Sendable {
        private let lock = NSLock()
        private var cache: [UInt32: String] = [:]

        func name(for index: UInt32) -> String? {
            guard index > 0 else { return nil }
            lock.lock()
            defer { lock.unlock() }
            if let known = cache[index] { return known }
            var buffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
            guard if_indextoname(index, &buffer) != nil else { return nil }
            let name = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            cache[index] = name
            return name
        }
    }

    /// Builds an observation from one of the framework's dictionaries. Returns `nil` for
    /// anything that is not an IPv4 or IPv6 TCP or UDP socket with a known owner.
    static func observation(
        from dictionary: NSDictionary, sourceID: UInt64, clock: MachClock, interfaces: InterfaceNames?,
        machNow: UInt64 = mach_continuous_time()
    ) -> SocketObservation? {
        let proto: TransportProtocol
        switch dictionary["provider"] as? String {
        case "TCP": proto = .tcp
        case "UDP": proto = .udp
        default: return nil
        }
        guard let local = (dictionary["localAddress"] as? Data).flatMap(endpoint(from:)),
              let pid = (dictionary["processID"] as? NSNumber)?.int32Value
        else { return nil }
        // An unconnected socket may report no remote address at all.
        let remote = (dictionary["remoteAddress"] as? Data).flatMap(endpoint(from:))
            ?? Endpoint(address: local.address.isIPv6 ? .v6(hi: 0, lo: 0) : .v4(0), port: 0)

        func unsigned(_ key: String) -> UInt64 { (dictionary[key] as? NSNumber)?.uint64Value ?? 0 }

        var observation = SocketObservation(
            sourceID: sourceID, proto: proto, local: local, remote: remote, pid: pid,
            processName: dictionary["processName"] as? String ?? "?",
            uniquePID: (dictionary["uniqueProcessID"] as? NSNumber)?.uint64Value,
            rxBytes: unsigned("rxBytes"), txBytes: unsigned("txBytes"),
            rxPackets: unsigned("rxPackets"), txPackets: unsigned("txPackets"))

        if proto == .tcp {
            observation.tcpState = (dictionary["TCPState"] as? String).flatMap(tcpState(named:))
            // Reported in seconds.
            if let rtt = (dictionary["rttAverage"] as? NSNumber)?.doubleValue, rtt > 0 {
                observation.rttMS = rtt * 1000
            }
            observation.retransmittedBytes = unsigned("txRetransmittedBytes")
        }
        if let index = (dictionary["interface"] as? NSNumber)?.uint32Value {
            observation.interface = interfaces?.name(for: index)
        }
        if let start = (dictionary["startAbsoluteTime"] as? NSNumber)?.uint64Value {
            observation.ageSeconds = clock.secondsSince(start, now: machNow)
        }
        return observation
    }

    /// `"TimeWait"`, `"FinWait1"`, `"Established"` and so on.
    static func tcpState(named name: String) -> TCPState? {
        let folded = name.lowercased().filter { $0.isLetter || $0.isNumber }
        return TCPState.allCases.first { $0.rawValue.lowercased() == folded }
    }

    /// Decodes a `sockaddr_in` or `sockaddr_in6` held in a data blob.
    static func endpoint(from data: Data) -> Endpoint? {
        data.withUnsafeBytes { bytes -> Endpoint? in
            guard bytes.count >= 16 else { return nil }
            let port = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
            func word(_ offset: Int) -> UInt64 {
                (0..<8).reduce(UInt64(0)) { $0 << 8 | UInt64(bytes[offset + $1]) }
            }
            if bytes[1] == UInt8(AF_INET) {
                return Endpoint(address: .v4(UInt32(truncatingIfNeeded: word(0))), port: port)
            }
            if bytes[1] == UInt8(AF_INET6), bytes.count >= 24 {
                return Endpoint(address: .v6(hi: word(8), lo: word(16)), port: port)
            }
            return nil
        }
    }
}
