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
        /// The sockets each subscription currently knows, by published ID. A socket is
        /// reported gone only when no subscription still holds it.
        private var liveIDs: [Int: Set<UInt64>] = [:]
        private var retired = Set<Int>()
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

        /// A subscription has described a socket for the first time.
        func noteLive(_ id: UInt64, generation: Int) {
            lock.lock()
            defer { lock.unlock() }
            guard !retired.contains(generation) else { return }
            if !liveIDs.values.contains(where: { $0.contains(id) }) { total += 1 }
            liveIDs[generation, default: []].insert(id)
        }

        /// A subscription says a socket is gone. True if no subscription still holds it,
        /// so it really has closed and can be reported removed.
        func noteGone(_ id: UInt64, generation: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !retired.contains(generation) else { return false }
            liveIDs[generation]?.remove(id)
            return !liveIDs.values.contains { $0.contains(id) }
        }

        func isRetired(_ generation: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return retired.contains(generation)
        }

        /// Stops listening to an old subscription. Returns the sockets only it knew, which
        /// the newer one has not reported in its time: closed meanwhile, so to be removed.
        func retire(_ generation: Int) -> [UInt64] {
            lock.lock()
            defer { lock.unlock() }
            retired.insert(generation)
            let held = liveIDs.removeValue(forKey: generation) ?? []
            let elsewhere = liveIDs.values.reduce(into: Set<UInt64>()) { $0.formUnion($1) }
            return held.subtracting(elsewhere).sorted()
        }

        var live: Int {
            lock.lock()
            defer { lock.unlock() }
            return liveIDs.values.reduce(into: Set<UInt64>()) { $0.formUnion($1) }.count
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
            let live = self.live
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
    /// Which subscription `manager` is. A renewal starts the next one beside it.
    private var generation = 0
    /// The subscription being replaced, kept until the new one has described everything.
    private var outgoing: (manager: Ref, generation: Int, retireAt: EngineTime)?
    private var renewRequested = false
    private var lastRenewal: EngineTime?
    private var functions: Functions?
    /// How many times the subscription has been renewed.
    public private(set) var renewals = 0
    /// Renews the subscription this often, in seconds, where nothing else can tell when it
    /// has gone stale; `nil` for never. The collector renews on evidence instead.
    public var renewEvery: Double?
    /// A line about coverage from whoever can measure it, shown with this source's health.
    public var coverageNote: String? {
        get { lock.withLock { note } }
        set { lock.withLock { note = newValue } }
    }
    private var note: String?

    /// How long an outgoing subscription is kept beside its replacement.
    static let handover: Double = 3

    private struct Functions {
        var create: CreateFn
        var destroy: ManagerFn
        var addAllTCP: ManagerFn
        var addAllUDP: ManagerFn
        var queryAllCounts: ManagerQueryFn
        var queryAllDescriptions: ManagerQueryFn
        var setDescriptionBlock: SourceSetDictionaryFn
        var setCountsBlock: SourceSetDictionaryFn
        var setRemovedBlock: SourceSetVoidFn
        var queryDescription: SourceFn
    }

    /// The socket's ID in a subscription's callbacks: set by its first description, then fixed.
    private final class SourceBox: @unchecked Sendable {
        var id: UInt64?
    }
    private let clock = MachClock()
    private var lastCounterQuery: EngineTime = -.infinity

    private var interval: Double

    /// How often counters are refreshed, in seconds. Sockets opening and closing arrive
    /// as events regardless; this only sets how fresh the byte counts are. Asking the
    /// kernel to describe every socket is the dominant cost of this source, so the app
    /// raises the rate while its window is in front and lowers it otherwise.
    public var counterInterval: Double {
        get {
            lock.lock()
            defer { lock.unlock() }
            return interval
        }
        set {
            lock.lock()
            interval = max(newValue, 0.1)
            lock.unlock()
        }
    }

    public init(counterInterval: Double = 1.0) {
        interval = counterInterval
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
        let functions = Functions(
            create: try symbol("NStatManagerCreate", as: CreateFn.self),
            destroy: try symbol("NStatManagerDestroy", as: ManagerFn.self),
            addAllTCP: try symbol("NStatManagerAddAllTCP", as: ManagerFn.self),
            addAllUDP: try symbol("NStatManagerAddAllUDP", as: ManagerFn.self),
            queryAllCounts: try symbol("NStatManagerQueryAllSources", as: ManagerQueryFn.self),
            queryAllDescriptions: try symbol("NStatManagerQueryAllSourcesDescriptions", as: ManagerQueryFn.self),
            setDescriptionBlock: try symbol("NStatSourceSetDescriptionBlock", as: SourceSetDictionaryFn.self),
            setCountsBlock: try symbol("NStatSourceSetCountsBlock", as: SourceSetDictionaryFn.self),
            setRemovedBlock: try symbol("NStatSourceSetRemovedBlock", as: SourceSetVoidFn.self),
            queryDescription: try symbol("NStatSourceQueryDescription", as: SourceFn.self))
        self.functions = functions
        manager = try subscribe(functions, generation: generation)
        queryAllCounts = functions.queryAllCounts
        destroy = functions.destroy
        failure = nil
    }

    /// Opens a subscription to every TCP and UDP socket. Its callbacks publish each socket
    /// under an ID made from the socket itself, so a later subscription reporting the same
    /// socket continues it rather than starting a new one.
    private func subscribe(_ functions: Functions, generation: Int) throws -> Ref {
        let inbox = self.inbox
        let clock = self.clock
        let interfaces = InterfaceNames()

        let sourceAdded: SourceAddedBlock = { source, _ in
            guard let source else { return }
            let box = SourceBox()
            let pointer = UInt64(UInt(bitPattern: source))

            // Descriptions and counts carry the same keys, so one handler serves both.
            let onUpdate: DictionaryBlock = { dictionary in
                guard let dictionary = dictionary as NSDictionary? else { return }
                guard !inbox.isRetired(generation) else { return }
                guard var observation = Self.observation(
                    from: dictionary, sourceID: 0, clock: clock, interfaces: interfaces)
                else {
                    inbox.reject(dictionary)
                    return
                }
                let start = (dictionary["startAbsoluteTime"] as? NSNumber)?.uint64Value ?? 0
                if box.id == nil {
                    box.id = start > 0
                        ? Self.stableID(proto: observation.proto, pid: observation.pid, localPort: observation.local.port, startTicks: start)
                        : pointer ^ (UInt64(generation) << 56)
                    inbox.noteLive(box.id!, generation: generation)
                }
                observation.sourceID = box.id!
                inbox.push(.seen(observation), startTicks: start)
            }
            functions.setDescriptionBlock(source, onUpdate)
            functions.setCountsBlock(source, onUpdate)

            let onRemoved: VoidBlock = {
                // A socket never described was never published.
                guard let id = box.id else { return }
                if inbox.noteGone(id, generation: generation) { inbox.push(.removed(sourceID: id)) }
            }
            functions.setRemovedBlock(source, onRemoved)

            functions.queryDescription(source)
        }

        guard let manager = functions.create(nil, Unmanaged.passUnretained(queue).toOpaque(), sourceAdded) else {
            throw NStatError.managerCreationFailed
        }
        functions.addAllTCP(manager)
        functions.addAllUDP(manager)
        functions.queryAllDescriptions(manager, nil)
        return manager
    }

    /// An ID for a socket from what does not change over its life: protocol, owner, local
    /// port, and the moment the kernel created it.
    static func stableID(proto: TransportProtocol, pid: Int32, localPort: UInt16, startTicks: UInt64) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ value: UInt64, bytes: Int) {
            for shift in stride(from: 0, to: bytes * 8, by: 8) { hash = (hash ^ ((value >> UInt64(shift)) & 0xFF)) &* 0x100_0000_01b3 }
        }
        mix(proto == .tcp ? 6 : 17, bytes: 1)
        mix(UInt64(UInt32(bitPattern: pid)), bytes: 4)
        mix(UInt64(localPort), bytes: 2)
        mix(startTicks, bytes: 8)
        return hash == 0 ? 1 : hash
    }

    /// Asks for a fresh subscription. NetworkStatistics can stop telling a long-lived
    /// subscriber about new sockets; a new subscription sees them again
    /// (docs/spikes/M8-findings.md). The switch is seamless: sockets keep their IDs.
    public func renew() {
        lock.withLock { renewRequested = true }
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        if let manager, let destroy { destroy(manager) }
        if let outgoing, let destroy { destroy(outgoing.manager) }
        manager = nil
        outgoing = nil
    }

    public func poll(now: EngineTime) -> [SourceEvent] {
        var orphans: [UInt64] = []
        lock.lock()
        if lastRenewal == nil { lastRenewal = now }
        if let every = renewEvery, now - (lastRenewal ?? now) >= every { renewRequested = true }
        // Start a renewal: the new subscription runs beside the old for a few seconds.
        if renewRequested, outgoing == nil, let functions, let current = manager {
            renewRequested = false
            let next = generation + 1
            if let fresh = try? subscribe(functions, generation: next) {
                outgoing = (current, generation, now + Self.handover)
                manager = fresh
                generation = next
                renewals += 1
                lastRenewal = now
            }
        }
        // Finish one: whatever only the old subscription knew has closed meanwhile.
        if let old = outgoing, now >= old.retireAt {
            orphans = inbox.retire(old.generation)
            destroy?(old.manager)
            outgoing = nil
        }
        let managers = [manager, outgoing?.manager].compactMap { $0 }
        let query = queryAllCounts
        let counterInterval = interval
        lock.unlock()
        for id in orphans { inbox.push(.removed(sourceID: id)) }
        // Ask for fresh counters; they arrive on the queue and are collected next time.
        if let query, now - lastCounterQuery >= counterInterval - 0.01 {
            lastCounterQuery = now
            for manager in managers { query(manager, nil) }
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
                + (counts.rejected > 0 ? ", \(counts.rejected) updates unreadable" : "")
                + (renewals > 0 ? ", renewed \(renewals) time\(renewals == 1 ? "" : "s")" : "")
                + (note.map { "; \($0)" } ?? ""))
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
