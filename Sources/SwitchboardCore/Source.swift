/// One socket as a source sees it at one moment. Sources report facts; the engine decides
/// what they mean.
public struct SocketObservation: Sendable, Codable, Equatable {
    /// Identity of the socket within its source, stable for the socket's lifetime.
    public var sourceID: UInt64
    public var proto: TransportProtocol
    public var local: Endpoint
    public var remote: Endpoint
    public var pid: Int32
    public var processName: String
    public var uniquePID: UInt64?
    /// Cumulative since the socket opened.
    public var rxBytes: UInt64
    public var txBytes: UInt64
    public var rxPackets: UInt64
    public var txPackets: UInt64
    public var tcpState: TCPState?
    public var interface: String?
    public var rttMS: Double?
    public var retransmittedBytes: UInt64?
    /// How long ago the socket was created, when the source knows.
    public var ageSeconds: Double?
    /// A label the source itself supplies, such as `nettop` marking a flow as QUIC.
    public var serviceHint: String?

    public init(
        sourceID: UInt64, proto: TransportProtocol, local: Endpoint, remote: Endpoint, pid: Int32,
        processName: String, uniquePID: UInt64? = nil, rxBytes: UInt64 = 0, txBytes: UInt64 = 0,
        rxPackets: UInt64 = 0, txPackets: UInt64 = 0, tcpState: TCPState? = nil, interface: String? = nil,
        rttMS: Double? = nil, retransmittedBytes: UInt64? = nil, ageSeconds: Double? = nil,
        serviceHint: String? = nil
    ) {
        self.sourceID = sourceID
        self.proto = proto
        self.local = local
        self.remote = remote
        self.pid = pid
        self.processName = processName
        self.uniquePID = uniquePID
        self.rxBytes = rxBytes
        self.txBytes = txBytes
        self.rxPackets = rxPackets
        self.txPackets = txPackets
        self.tcpState = tcpState
        self.interface = interface
        self.rttMS = rttMS
        self.retransmittedBytes = retransmittedBytes
        self.ageSeconds = ageSeconds
        self.serviceHint = serviceHint
    }
}

public enum SourceEvent: Sendable, Codable, Equatable {
    /// The socket exists and currently looks like this.
    case seen(SocketObservation)
    /// The socket is gone.
    case removed(sourceID: UInt64)
}

public struct SourceHealth: Sendable, Codable, Equatable {
    public var running: Bool
    public var detail: String

    public init(running: Bool, detail: String) {
        self.running = running
        self.detail = detail
    }
}

/// Something that reports sockets: NetworkStatistics, `nettop`, the simulator, a recorded trace.
///
/// The engine calls `poll` on its own tick. A source that learns things asynchronously
/// queues them and hands them over here.
public protocol FlowSource: AnyObject, Sendable {
    /// Short name recorded on every flow this source attributes.
    var name: String { get }
    func start() throws
    func stop()
    /// Everything learned since the previous call. `now` is the engine's clock.
    func poll(now: EngineTime) -> [SourceEvent]
    var health: SourceHealth { get }
}

/// Fills in what a source cannot know about a process: path, parent, owner.
public protocol ProcessResolver: Sendable {
    func resolve(pid: Int32, name: String, uniqueID: UInt64?) -> ProcessRecord
}

/// Uses only what the source said.
public struct PassthroughProcessResolver: ProcessResolver {
    public init() {}
    public func resolve(pid: Int32, name: String, uniqueID: UInt64?) -> ProcessRecord {
        ProcessRecord(pid: pid, uniqueID: uniqueID, name: name)
    }
}
