/// Where a hostname came from (docs/SPEC.md §6.6).
public enum NameSource: String, Sendable, Codable {
    /// A DNS answer seen on the wire.
    case dns
    /// The server name in a TLS handshake.
    case sni
    /// A reverse lookup.
    case ptr
}

/// Something learned from looking at packets rather than at sockets.
///
/// The two endpoints of a connection are given in the order the packet had them. Which is
/// local and which is remote is for the engine to work out, since it knows the sockets.
public enum CaptureObservation: Sendable, Equatable, Codable {
    /// A DNS answer: `name` resolves to these addresses. `pid` is the process that asked, when known.
    case resolved(name: String, addresses: [IPAddress], pid: Int32?)
    /// The server name a TLS client sent on the connection between these endpoints.
    case serverName(proto: TransportProtocol, from: Endpoint, to: Endpoint, name: String)
    /// The name a reverse lookup gave for an address.
    case reverse(address: IPAddress, name: String)
    /// What the traffic between these endpoints was seen to be: `TLS`, `QUIC`, `DNS`.
    case service(proto: TransportProtocol, from: Endpoint, to: Endpoint, service: String)
}

/// Something that reports capture observations: packet capture in the collector, the
/// collector's client in the app, or the simulator.
public protocol CaptureProvider: AnyObject, Sendable {
    func pollCapture(now: EngineTime) -> [CaptureObservation]
}

/// One DNS answer, for the DNS Activity panel.
public struct DNSRecord: Sendable, Codable, Identifiable, Equatable {
    public var id: UInt64
    public var time: EngineTime
    public var name: String
    public var addresses: [IPAddress]
    /// The process that asked, when known.
    public var pid: Int32?
}
