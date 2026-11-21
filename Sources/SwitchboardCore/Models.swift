/// Seconds on the engine's own monotonic timeline. The origin is arbitrary; only
/// differences mean anything. Wall-clock times are derived through `FlowEngine.wallClock`.
public typealias EngineTime = Double

public struct Endpoint: Hashable, Sendable, Codable, CustomStringConvertible {
    public var address: IPAddress
    public var port: UInt16

    public init(address: IPAddress, port: UInt16) {
        self.address = address
        self.port = port
    }

    /// No address and no port: the far side of a listening or unconnected socket.
    public var isWildcard: Bool { address.isUnspecified && port == 0 }

    public var description: String {
        address.isIPv6 ? "[\(address)]:\(port)" : "\(address):\(port)"
    }
}

/// The 5-tuple that identifies a flow.
public struct FlowKey: Hashable, Sendable, Codable {
    public var proto: TransportProtocol
    public var local: Endpoint
    public var remote: Endpoint

    public init(proto: TransportProtocol, local: Endpoint, remote: Endpoint) {
        self.proto = proto
        self.local = local
        self.remote = remote
    }
}

public enum TCPState: String, Sendable, Codable, CaseIterable {
    case closed, listen, synSent, synReceived, established, closeWait
    case finWait1, closing, lastAck, finWait2, timeWait

    /// The connection is on its way down.
    public var isClosing: Bool {
        switch self {
        case .closed, .closeWait, .finWait1, .closing, .lastAck, .finWait2, .timeWait: true
        case .listen, .synSent, .synReceived, .established: false
        }
    }
}

public enum FlowState: String, Sendable, Codable {
    /// First seen within the last tick.
    case new
    /// Bytes moved recently.
    case active
    /// Open, but quiet.
    case idle
    /// TCP teardown in progress.
    case closing
    /// Gone from the source. Kept for a fade window, then purged.
    case closed
}

public enum FlowDirection: String, Sendable, Codable {
    case outbound, inbound, unknown
}

/// How sure we are of a service label (docs/SPEC.md §6.5).
public enum ServiceBasis: String, Sendable, Codable {
    case port, heuristic, observed
}

public typealias FlowID = UInt64

public struct Flow: Sendable, Codable, Identifiable {
    public var id: FlowID
    public var key: FlowKey
    public var pid: Int32
    public var direction: FlowDirection
    public var interface: String?
    public var state: FlowState
    public var tcpState: TCPState?

    public var firstSeen: EngineTime
    public var lastSeen: EngineTime
    /// When bytes last moved.
    public var lastActive: EngineTime
    public var closedAt: EngineTime?
    /// `firstSeen` is when the connection really opened, not merely when we first noticed it.
    public var ageExact: Bool

    public var bytesIn: UInt64
    public var bytesOut: UInt64
    public var packetsIn: UInt64
    public var packetsOut: UInt64
    /// Smoothed bytes per second.
    public var rateIn: Double
    public var rateOut: Double

    public var rttMS: Double?
    public var retransmittedBytes: UInt64?

    public var service: String?
    public var serviceBasis: ServiceBasis?
    public var hostname: String?
    public var hostnameSource: NameSource?
    /// Which source this flow's attribution came from.
    public var attribution: String

    // Where the remote address is and whose it is, when a database says.
    public var country: String?
    public var city: String?
    public var asn: UInt32?
    public var org: String?
    /// Where the remote address is on the globe, in degrees, when a database says.
    public var latitude: Double?
    public var longitude: Double?
    /// The user's lists the remote address is on.
    public var tags: [String]

    public init(
        id: FlowID, key: FlowKey, pid: Int32, direction: FlowDirection, interface: String?, state: FlowState,
        tcpState: TCPState?, firstSeen: EngineTime, lastSeen: EngineTime, lastActive: EngineTime, closedAt: EngineTime?,
        ageExact: Bool, bytesIn: UInt64, bytesOut: UInt64, packetsIn: UInt64, packetsOut: UInt64, rateIn: Double,
        rateOut: Double, rttMS: Double?, retransmittedBytes: UInt64?, service: String?, serviceBasis: ServiceBasis?,
        hostname: String?, hostnameSource: NameSource? = nil, attribution: String, country: String? = nil,
        city: String? = nil, asn: UInt32? = nil, org: String? = nil, tags: [String] = [], latitude: Double? = nil,
        longitude: Double? = nil
    ) {
        self.id = id
        self.key = key
        self.pid = pid
        self.direction = direction
        self.interface = interface
        self.state = state
        self.tcpState = tcpState
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.lastActive = lastActive
        self.closedAt = closedAt
        self.ageExact = ageExact
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.packetsIn = packetsIn
        self.packetsOut = packetsOut
        self.rateIn = rateIn
        self.rateOut = rateOut
        self.rttMS = rttMS
        self.retransmittedBytes = retransmittedBytes
        self.service = service
        self.serviceBasis = serviceBasis
        self.hostname = hostname
        self.hostnameSource = hostnameSource
        self.attribution = attribution
        self.country = country
        self.city = city
        self.asn = asn
        self.org = org
        self.tags = tags
        self.latitude = latitude
        self.longitude = longitude
    }

    public var bytesTotal: UInt64 { bytesIn &+ bytesOut }
    public var rateTotal: Double { rateIn + rateOut }

    public func age(at now: EngineTime) -> Double { max(0, (closedAt ?? now) - firstSeen) }
}

/// A socket waiting for traffic rather than carrying a connection: a TCP listener, or a
/// UDP socket with no fixed peer.
public struct Listener: Sendable, Codable, Identifiable, Hashable {
    public var id: FlowID
    public var proto: TransportProtocol
    public var local: Endpoint
    public var pid: Int32
    public var bytesIn: UInt64
    public var bytesOut: UInt64
    public var firstSeen: EngineTime

    /// Reachable from other machines: bound to something other than loopback.
    public var exposed: Bool { !local.address.isLoopback }
}

public enum SigningStatus: String, Sendable, Codable {
    case apple, developerID, adHoc, unsigned, invalid, unknown
}

public struct ProcessRecord: Sendable, Codable, Identifiable, Hashable {
    public var pid: Int32
    /// Kernel-unique id, so a reused pid is never mistaken for the earlier process.
    public var uniqueID: UInt64?
    public var name: String
    public var path: String?
    public var parentPID: Int32?
    public var uid: UInt32?
    public var username: String?
    /// Seconds since 1970.
    public var startTime: Double?
    public var signing: SigningStatus
    /// The developer team that signed it, for Developer ID signatures.
    public var teamID: String?
    /// Details beyond name and path were not readable without more privilege.
    public var restricted: Bool

    public var id: Int32 { pid }

    public init(
        pid: Int32, uniqueID: UInt64? = nil, name: String, path: String? = nil, parentPID: Int32? = nil,
        uid: UInt32? = nil, username: String? = nil, startTime: Double? = nil,
        signing: SigningStatus = .unknown, restricted: Bool = false
    ) {
        self.pid = pid
        self.uniqueID = uniqueID
        self.name = name
        self.path = path
        self.parentPID = parentPID
        self.uid = uid
        self.username = username
        self.startTime = startTime
        self.signing = signing
        self.restricted = restricted
    }
}

extension Flow {
    /// Never leaves this Mac: the far end is a loopback address, or this Mac's own address
    /// (a program connecting to a server on the same machine by its network address).
    /// Development tools and containers open hundreds of these a minute.
    public var staysOnThisMac: Bool {
        key.remote.address.isLoopback || key.remote.address == key.local.address
    }
}
