import Foundation

/// The protocol between the root collector and its clients.
///
/// Hand-written and dependency-free on purpose: the collector runs as root, and nothing
/// that runs as root links third-party code (docs/SPEC.md §5.2).
///
/// A frame is a 4-byte little-endian length, then one type byte, then the payload.
/// Integers are LEB128 varints, signed ones zig-zag encoded; strings are a varint length
/// and UTF-8. Every read is bounds-checked and every count is checked against the bytes
/// actually present, so a hostile or corrupt peer can make a decode fail but cannot make
/// it crash or allocate without limit.
public enum Wire {
    public static let protocolVersion: UInt16 = 1
    /// Largest frame either side will accept.
    public static let maximumFrame = 16 * 1024 * 1024
    static let maximumString = 8192

    public enum WireError: Error, Equatable, CustomStringConvertible {
        case truncated
        case malformed(String)
        case tooLarge(Int)

        public var description: String {
            switch self {
            case .truncated: "message ended early"
            case .malformed(let what): "malformed message: \(what)"
            case .tooLarge(let size): "frame of \(size) bytes exceeds the limit"
            }
        }
    }

    public enum Message: Equatable, Sendable {
        /// Client to collector, first thing sent.
        case hello(protocolVersion: UInt16, client: String)
        /// Collector to client: who it is and which sources it runs, in priority order.
        case welcome(protocolVersion: UInt16, version: String, uid: UInt32, sources: [String])
        /// The collector will not serve this client.
        case refused(reason: String)
        /// What one source learned. `source` indexes the list in `welcome`.
        case events(source: UInt8, [SourceEvent])
        case process(ProcessRecord)
        /// One line per source, plus how many times this client fell behind and was resynchronised.
        case health(sources: [String], resyncs: UInt32)
        /// The complete current state follows. Sent on connecting, and again if the client
        /// fell so far behind that its backlog was dropped.
        case reset
        /// What packet capture learned: hostnames and observed services.
        case capture([CaptureObservation])
        /// A message type this build does not know. Skipped, so a newer collector can add
        /// messages without breaking an older client.
        case unknown(type: UInt8)
    }

    // MARK: - Framing

    /// The message as a complete frame, ready to write to a socket.
    public static func frame(_ message: Message) -> [UInt8] {
        var writer = Writer()
        switch message {
        case .hello(let version, let client):
            writer.byte(1)
            writer.u16(version)
            writer.string(client)
        case .welcome(let version, let build, let uid, let sources):
            writer.byte(2)
            writer.u16(version)
            writer.string(build)
            writer.varint(UInt64(uid))
            writer.varint(UInt64(sources.count))
            sources.forEach { writer.string($0) }
        case .refused(let reason):
            writer.byte(3)
            writer.string(reason)
        case .events(let source, let events):
            writer.byte(4)
            writer.byte(source)
            writer.varint(UInt64(events.count))
            events.forEach { writer.event($0) }
        case .process(let record):
            writer.byte(5)
            writer.process(record)
        case .health(let sources, let resyncs):
            writer.byte(6)
            writer.varint(UInt64(sources.count))
            sources.forEach { writer.string($0) }
            writer.varint(UInt64(resyncs))
        case .reset:
            writer.byte(7)
        case .capture(let observations):
            writer.byte(8)
            writer.varint(UInt64(observations.count))
            observations.forEach { writer.capture($0) }
        case .unknown(let type):
            writer.byte(type)
        }
        let body = writer.bytes
        var framed: [UInt8] = []
        framed.reserveCapacity(body.count + 4)
        let length = UInt32(body.count)
        for shift in stride(from: 0, to: 32, by: 8) { framed.append(UInt8(truncatingIfNeeded: length >> UInt32(shift))) }
        framed.append(contentsOf: body)
        return framed
    }

    /// Decodes the body of one frame (everything after the length).
    public static func decode(_ body: some Collection<UInt8>) throws(WireError) -> Message {
        var reader = Reader(Array(body))
        let message: Message
        switch try reader.byte() {
        case 1:
            message = .hello(protocolVersion: try reader.u16(), client: try reader.string())
        case 2:
            let version = try reader.u16()
            let build = try reader.string()
            let uid = try reader.uint32()
            let count = try reader.count(minimumBytesEach: 1)
            var sources: [String] = []
            for _ in 0..<count { sources.append(try reader.string()) }
            message = .welcome(protocolVersion: version, version: build, uid: uid, sources: sources)
        case 3:
            message = .refused(reason: try reader.string())
        case 4:
            let source = try reader.byte()
            let count = try reader.count(minimumBytesEach: 2)
            var events: [SourceEvent] = []
            events.reserveCapacity(count)
            for _ in 0..<count { events.append(try reader.event()) }
            message = .events(source: source, events)
        case 5:
            message = .process(try reader.process())
        case 6:
            let count = try reader.count(minimumBytesEach: 1)
            var sources: [String] = []
            for _ in 0..<count { sources.append(try reader.string()) }
            message = .health(sources: sources, resyncs: try reader.uint32())
        case 7:
            message = .reset
        case 8:
            let count = try reader.count(minimumBytesEach: 3)
            var observations: [CaptureObservation] = []
            observations.reserveCapacity(count)
            for _ in 0..<count { observations.append(try reader.capture()) }
            message = .capture(observations)
        case let other:
            // Framing has already delimited it, so it can be stepped over safely.
            return .unknown(type: other)
        }
        guard reader.isAtEnd else { throw .malformed("\(reader.remaining) bytes left over") }
        return message
    }

    /// Pulls complete frames out of a byte stream as it arrives.
    public struct FrameBuffer: Sendable {
        private var pending: [UInt8] = []

        public init() {}

        public mutating func append(_ bytes: some Collection<UInt8>) {
            pending.append(contentsOf: bytes)
        }

        /// The next complete frame's body, or `nil` if more bytes are needed.
        public mutating func next() throws(WireError) -> [UInt8]? {
            guard pending.count >= 4 else { return nil }
            let length = Int(pending[0]) | Int(pending[1]) << 8 | Int(pending[2]) << 16 | Int(pending[3]) << 24
            guard length <= Wire.maximumFrame else { throw .tooLarge(length) }
            guard length >= 1 else { throw .malformed("empty frame") }
            guard pending.count >= 4 + length else { return nil }
            let body = Array(pending[4..<(4 + length)])
            pending.removeFirst(4 + length)
            return body
        }
    }

    // MARK: - Writing

    struct Writer {
        var bytes: [UInt8] = []

        mutating func byte(_ value: UInt8) { bytes.append(value) }

        mutating func u16(_ value: UInt16) {
            bytes.append(UInt8(truncatingIfNeeded: value))
            bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        }

        mutating func varint(_ value: UInt64) {
            var rest = value
            while rest >= 0x80 {
                bytes.append(UInt8(truncatingIfNeeded: rest) | 0x80)
                rest >>= 7
            }
            bytes.append(UInt8(rest))
        }

        mutating func signed(_ value: Int32) {
            varint(UInt64(UInt32(bitPattern: (value << 1) ^ (value >> 31))))
        }

        mutating func double(_ value: Double) {
            let bits = value.bitPattern
            for shift in stride(from: 0, to: 64, by: 8) { bytes.append(UInt8(truncatingIfNeeded: bits >> UInt64(shift))) }
        }

        mutating func string(_ value: String) {
            // Over-long text is cut rather than refused: a process name is not worth a lost frame.
            let utf8 = Array(value.utf8.prefix(Wire.maximumString))
            varint(UInt64(utf8.count))
            bytes.append(contentsOf: utf8)
        }

        mutating func address(_ value: IPAddress) {
            let raw = value.networkBytes
            bytes.append(UInt8(raw.count))
            bytes.append(contentsOf: raw)
        }

        mutating func endpoint(_ value: Endpoint) {
            address(value.address)
            u16(value.port)
        }

        mutating func event(_ event: SourceEvent) {
            switch event {
            case .removed(let id):
                byte(0)
                varint(id)
            case .seen(let observation):
                byte(1)
                varint(observation.sourceID)
                byte(observation.proto == .tcp ? 6 : 17)
                endpoint(observation.local)
                endpoint(observation.remote)
                signed(observation.pid)
                string(observation.processName)
                varint(observation.rxBytes)
                varint(observation.txBytes)
                varint(observation.rxPackets)
                varint(observation.txPackets)

                var present: UInt8 = 0
                if observation.uniquePID != nil { present |= 1 }
                if observation.tcpState != nil { present |= 2 }
                if observation.interface != nil { present |= 4 }
                if observation.rttMS != nil { present |= 8 }
                if observation.retransmittedBytes != nil { present |= 16 }
                if observation.ageSeconds != nil { present |= 32 }
                if observation.serviceHint != nil { present |= 64 }
                byte(present)
                if let value = observation.uniquePID { varint(value) }
                if let value = observation.tcpState { byte(UInt8(TCPState.allCases.firstIndex(of: value) ?? 0)) }
                if let value = observation.interface { string(value) }
                if let value = observation.rttMS { double(value) }
                if let value = observation.retransmittedBytes { varint(value) }
                if let value = observation.ageSeconds { double(value) }
                if let value = observation.serviceHint { string(value) }
            }
        }

        mutating func capture(_ observation: CaptureObservation) {
            switch observation {
            case .resolved(let name, let addresses, let pid):
                byte(0)
                string(name)
                varint(UInt64(addresses.count))
                addresses.forEach { address($0) }
                byte(pid == nil ? 0 : 1)
                if let pid { signed(pid) }
            case .serverName(let proto, let from, let to, let name):
                byte(1)
                byte(proto == .tcp ? 6 : 17)
                endpoint(from)
                endpoint(to)
                string(name)
            case .service(let proto, let from, let to, let service):
                byte(2)
                byte(proto == .tcp ? 6 : 17)
                endpoint(from)
                endpoint(to)
                string(service)
            case .reverse(let address, let name):
                byte(3)
                self.address(address)
                string(name)
            }
        }

        mutating func process(_ record: ProcessRecord) {
            signed(record.pid)
            string(record.name)
            var present: UInt8 = record.restricted ? 128 : 0
            if record.uniqueID != nil { present |= 1 }
            if record.path != nil { present |= 2 }
            if record.parentPID != nil { present |= 4 }
            if record.uid != nil { present |= 8 }
            if record.username != nil { present |= 16 }
            if record.startTime != nil { present |= 32 }
            byte(present)
            if let value = record.uniqueID { varint(value) }
            if let value = record.path { string(value) }
            if let value = record.parentPID { signed(value) }
            if let value = record.uid { varint(UInt64(value)) }
            if let value = record.username { string(value) }
            if let value = record.startTime { double(value) }
            string(record.signing.rawValue)
        }
    }

    // MARK: - Reading

    struct Reader {
        private let bytes: [UInt8]
        private var offset = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        var remaining: Int { bytes.count - offset }
        var isAtEnd: Bool { offset == bytes.count }

        mutating func byte() throws(WireError) -> UInt8 {
            guard offset < bytes.count else { throw .truncated }
            defer { offset += 1 }
            return bytes[offset]
        }

        mutating func u16() throws(WireError) -> UInt16 {
            let low = try byte(), high = try byte()
            return UInt16(low) | UInt16(high) << 8
        }

        mutating func varint() throws(WireError) -> UInt64 {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                let next = try byte()
                // Ten bytes hold 64 bits; anything longer is not a number we wrote.
                guard shift < 64 else { throw .malformed("varint too long") }
                value |= UInt64(next & 0x7f) << shift
                if next & 0x80 == 0 { return value }
                shift += 7
            }
        }

        mutating func uint32() throws(WireError) -> UInt32 {
            let value = try varint()
            guard value <= UInt64(UInt32.max) else { throw .malformed("value out of range") }
            return UInt32(value)
        }

        mutating func signed() throws(WireError) -> Int32 {
            let raw = try uint32()
            return Int32(bitPattern: (raw >> 1) ^ (0 &- (raw & 1)))
        }

        mutating func double() throws(WireError) -> Double {
            guard remaining >= 8 else { throw .truncated }
            var bits: UInt64 = 0
            for index in 0..<8 { bits |= UInt64(bytes[offset + index]) << UInt64(8 * index) }
            offset += 8
            return Double(bitPattern: bits)
        }

        /// A count of things to follow, refused unless that many could actually be present.
        mutating func count(minimumBytesEach: Int) throws(WireError) -> Int {
            let value = try varint()
            guard value <= UInt64(remaining / max(minimumBytesEach, 1)) else { throw .malformed("count exceeds message") }
            return Int(value)
        }

        mutating func string() throws(WireError) -> String {
            let length = try varint()
            guard length <= UInt64(Wire.maximumString) else { throw .malformed("string too long") }
            guard Int(length) <= remaining else { throw .truncated }
            defer { offset += Int(length) }
            return String(decoding: bytes[offset..<(offset + Int(length))], as: UTF8.self)
        }

        mutating func address() throws(WireError) -> IPAddress {
            let length = Int(try byte())
            guard length == 4 || length == 16 else { throw .malformed("address length \(length)") }
            guard length <= remaining else { throw .truncated }
            defer { offset += length }
            guard let address = IPAddress(networkBytes: bytes[offset..<(offset + length)]) else {
                throw .malformed("address")
            }
            return address
        }

        mutating func endpoint() throws(WireError) -> Endpoint {
            Endpoint(address: try address(), port: try u16())
        }

        mutating func event() throws(WireError) -> SourceEvent {
            switch try byte() {
            case 0:
                return .removed(sourceID: try varint())
            case 1:
                let id = try varint()
                let proto: TransportProtocol
                switch try byte() {
                case 6: proto = .tcp
                case 17: proto = .udp
                case let other: throw .malformed("protocol \(other)")
                }
                var observation = SocketObservation(
                    sourceID: id, proto: proto, local: try endpoint(), remote: try endpoint(), pid: try signed(),
                    processName: try string(), rxBytes: try varint(), txBytes: try varint(),
                    rxPackets: try varint(), txPackets: try varint())
                let present = try byte()
                guard present & 128 == 0 else { throw .malformed("unknown field flags") }
                if present & 1 != 0 { observation.uniquePID = try varint() }
                if present & 2 != 0 {
                    let index = Int(try byte())
                    guard TCPState.allCases.indices.contains(index) else { throw .malformed("tcp state \(index)") }
                    observation.tcpState = TCPState.allCases[index]
                }
                if present & 4 != 0 { observation.interface = try string() }
                if present & 8 != 0 { observation.rttMS = try double() }
                if present & 16 != 0 { observation.retransmittedBytes = try varint() }
                if present & 32 != 0 { observation.ageSeconds = try double() }
                if present & 64 != 0 { observation.serviceHint = try string() }
                return .seen(observation)
            case let other:
                throw .malformed("event kind \(other)")
            }
        }

        mutating func transport() throws(WireError) -> TransportProtocol {
            switch try byte() {
            case 6: return .tcp
            case 17: return .udp
            case let other: throw .malformed("protocol \(other)")
            }
        }

        mutating func capture() throws(WireError) -> CaptureObservation {
            switch try byte() {
            case 0:
                let name = try string()
                let count = try count(minimumBytesEach: 5)
                var addresses: [IPAddress] = []
                for _ in 0..<count { addresses.append(try address()) }
                let pid: Int32?
                switch try byte() {
                case 0: pid = nil
                case 1: pid = try signed()
                case let other: throw .malformed("presence flag \(other)")
                }
                return .resolved(name: name, addresses: addresses, pid: pid)
            case 1:
                return .serverName(proto: try transport(), from: try endpoint(), to: try endpoint(), name: try string())
            case 2:
                return .service(proto: try transport(), from: try endpoint(), to: try endpoint(), service: try string())
            case 3:
                return .reverse(address: try address(), name: try string())
            case let other:
                throw .malformed("capture kind \(other)")
            }
        }

        mutating func process() throws(WireError) -> ProcessRecord {
            var record = ProcessRecord(pid: try signed(), name: try string())
            let present = try byte()
            guard present & 64 == 0 else { throw .malformed("unknown field flags") }
            record.restricted = present & 128 != 0
            if present & 1 != 0 { record.uniqueID = try varint() }
            if present & 2 != 0 { record.path = try string() }
            if present & 4 != 0 { record.parentPID = try signed() }
            if present & 8 != 0 { record.uid = try uint32() }
            if present & 16 != 0 { record.username = try string() }
            if present & 32 != 0 { record.startTime = try double() }
            guard let signing = SigningStatus(rawValue: try string()) else { throw .malformed("signing status") }
            record.signing = signing
            return record
        }
    }
}
