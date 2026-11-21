import CDarwinPrivate
import Foundation
import SwitchboardCore

/// Looks at captured packets and reports the few things capture is for: DNS answers, TLS
/// server names, and what a connection was seen to carry.
///
/// PKTAP cannot be filtered in the kernel (docs/spikes/M0-findings.md), so every packet
/// arrives here. Almost all are dismissed after reading a handful of header bytes in
/// place; only DNS messages and the opening of TLS connections are copied and parsed.
/// Nothing is kept beyond the fragments of a handshake still being assembled.
public struct PacketInspector: Sendable {
    public struct Stats: Sendable, Equatable {
        public var packets = 0
        /// Packets whose PKTAP header was not the length this build expects.
        public var unexpectedHeader = 0
        public var dnsAnswers = 0
        public var serverNames = 0
        /// Server names that needed more than one segment to read.
        public var reassembled = 0
        public var quicFlows = 0
    }

    private struct Pair: Hashable {
        var from: Endpoint
        var to: Endpoint
    }

    public private(set) var stats = Stats()
    /// The start of TLS handshakes that ran past their first segment.
    private var partial: [Pair: [UInt8]] = [:]
    private var quicSeen = Set<Pair>()

    static let headerLength = MemoryLayout<sb_pktap_header>.size

    public init() {}

    public mutating func inspect(_ raw: UnsafeRawBufferPointer) -> [CaptureObservation] {
        stats.packets += 1
        guard raw.count >= Self.headerLength else { return [] }
        guard Int(raw.loadUnaligned(as: UInt32.self)) == Self.headerLength else {
            stats.unexpectedHeader += 1
            return []
        }
        let header = raw.loadUnaligned(as: sb_pktap_header.self)

        // Link header: from the link type, as the M0 probe verified.
        let link: Int
        switch header.pth_dlt {
        case 1: link = 14  // Ethernet
        case 0: link = 4  // loopback
        case 12: link = 0  // raw IP
        default: link = Int(header.pth_frame_pre_length)
        }
        var offset = Self.headerLength + link
        guard offset + 20 <= raw.count else { return [] }

        // IP.
        let source: IPAddress, destination: IPAddress
        let proto: UInt8
        switch raw[offset] >> 4 {
        case 4:
            let headerBytes = Int(raw[offset] & 0x0f) * 4
            guard headerBytes >= 20, offset + headerBytes <= raw.count else { return [] }
            proto = raw[offset + 9]
            // A fragment other than the first has no transport header to read.
            guard (UInt16(raw[offset + 6]) << 8 | UInt16(raw[offset + 7])) & 0x1fff == 0 else { return [] }
            source = .v4(Self.be32(raw, offset + 12))
            destination = .v4(Self.be32(raw, offset + 16))
            offset += headerBytes
        case 6:
            guard offset + 40 <= raw.count else { return [] }
            proto = raw[offset + 6]
            source = .v6(hi: Self.be64(raw, offset + 8), lo: Self.be64(raw, offset + 16))
            destination = .v6(hi: Self.be64(raw, offset + 24), lo: Self.be64(raw, offset + 32))
            offset += 40
        default:
            return []
        }
        guard proto == 6 || proto == 17, offset + 8 <= raw.count else { return [] }
        let sourcePort = UInt16(raw[offset]) << 8 | UInt16(raw[offset + 1])
        let destinationPort = UInt16(raw[offset + 2]) << 8 | UInt16(raw[offset + 3])
        let from = Endpoint(address: source, port: sourcePort)
        let to = Endpoint(address: destination, port: destinationPort)

        if proto == 17 {
            let payload = offset + 8
            guard payload < raw.count else { return [] }
            if sourcePort == 53 || destinationPort == 53 {
                return inspectDNS(Array(raw[payload...]), from: from, to: to, header: header)
            }
            // A QUIC connection opens with long-header packets padded to at least 1,200 bytes.
            if sourcePort == 443 || destinationPort == 443, raw[payload] & 0xC0 == 0xC0, raw.count - payload >= 1200 {
                let pair = Pair(from: from, to: to)
                guard !quicSeen.contains(pair), !quicSeen.contains(Pair(from: to, to: from)) else { return [] }
                if quicSeen.count >= 8192 { quicSeen.removeAll() }
                quicSeen.insert(pair)
                stats.quicFlows += 1
                return [.service(proto: .udp, from: from, to: to, service: "QUIC")]
            }
            return []
        }

        // TCP.
        guard offset + 20 <= raw.count else { return [] }
        let payload = offset + Int(raw[offset + 12] >> 4) * 4
        guard payload >= offset + 20, payload < raw.count else { return [] }
        let pair = Pair(from: from, to: to)
        let waiting = partial[pair]
        // Only the opening of a TLS connection, or the continuation of one, is of interest.
        guard waiting != nil || (raw.count - payload >= 6 && raw[payload] == 0x16 && raw[payload + 1] == 0x03) else {
            return []
        }
        var bytes = waiting ?? []
        bytes.append(contentsOf: raw[payload...])

        switch TLSParser.serverName(inTCPPayload: bytes) {
        case .found(let name, _):
            partial[pair] = nil
            stats.serverNames += 1
            if waiting != nil { stats.reassembled += 1 }
            return [
                .serverName(proto: .tcp, from: from, to: to, name: name),
                .service(proto: .tcp, from: from, to: to, service: "TLS"),
            ]
        case .truncated:
            // Current browsers send a hello larger than one segment. Hold what we have and
            // wait for the rest, within limits.
            if bytes.count > 8192 {
                partial[pair] = nil
            } else {
                if partial.count >= 64, waiting == nil { partial.removeAll() }
                partial[pair] = bytes
            }
            return []
        case .absent:
            partial[pair] = nil
            return [.service(proto: .tcp, from: from, to: to, service: "TLS")]
        case .notClientHello:
            partial[pair] = nil
            return []
        }
    }

    private mutating func inspectDNS(
        _ message: [UInt8], from: Endpoint, to: Endpoint, header: sb_pktap_header
    ) -> [CaptureObservation] {
        guard let parsed = DNSParser.parse(message), parsed.isResponse, !parsed.addresses.isEmpty,
              let name = parsed.question ?? parsed.addresses.first?.name
        else { return [] }
        stats.dnsAnswers += 1
        // The resolver answers on behalf of whoever asked; the effective pid is the asker.
        let asker: Int32? = header.pth_epid > 0 && header.pth_epid != header.pth_pid ? header.pth_epid : nil
        return [
            .resolved(name: name, addresses: parsed.addresses.map(\.address), pid: asker),
            .service(proto: .udp, from: from, to: to, service: "DNS"),
        ]
    }

    private static func be32(_ raw: UnsafeRawBufferPointer, _ at: Int) -> UInt32 {
        UInt32(raw[at]) << 24 | UInt32(raw[at + 1]) << 16 | UInt32(raw[at + 2]) << 8 | UInt32(raw[at + 3])
    }

    private static func be64(_ raw: UnsafeRawBufferPointer, _ at: Int) -> UInt64 {
        UInt64(be32(raw, at)) << 32 | UInt64(be32(raw, at + 4))
    }
}

/// Live packet capture with process metadata, feeding a `PacketInspector`. Needs root.
///
/// Packets are read, inspected, and dropped. Nothing is written anywhere.
public final class PktapCapture: CaptureProvider, FlowSourceHealth, @unchecked Sendable {
    public enum CaptureError: Error, CustomStringConvertible {
        case unavailable(String)

        public var description: String {
            switch self {
            case .unavailable(let reason): "packet capture unavailable: \(reason)"
            }
        }
    }

    private let lock = NSLock()
    private var pending: [CaptureObservation] = []
    private var stats = PacketInspector.Stats()
    private var dropped: UInt32 = 0
    private var status = "not started"
    private var running = false
    private var handle: OpaquePointer?

    public init() {}

    public let healthName = "capture"

    public var healthDetail: String {
        lock.lock()
        defer { lock.unlock() }
        guard running else { return status }
        var text = "\(stats.packets) packets, \(stats.dnsAnswers) DNS answers, \(stats.serverNames) TLS names"
        if stats.reassembled > 0 { text += " (\(stats.reassembled) across segments)" }
        if stats.quicFlows > 0 { text += ", \(stats.quicFlows) QUIC" }
        if dropped > 0 { text += ", \(dropped) dropped" }
        if stats.unexpectedHeader > 0 { text += ", \(stats.unexpectedHeader) with an unrecognised header" }
        return text
    }

    public func start() throws {
        var errorBuffer = [CChar](repeating: 0, count: Int(PCAP_ERRBUF_SIZE))
        var failure = "no pktap interface"
        for device in ["pktap,all", "pktap"] {
            guard let created = pcap_create(device, &errorBuffer) else {
                failure = errorBuffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
                continue
            }
            pcap_set_want_pktap(created, 1)
            // Room for the PKTAP and link headers and one full segment of a TLS hello.
            pcap_set_snaplen(created, 2048)
            pcap_set_timeout(created, 250)
            pcap_set_immediate_mode(created, 1)
            pcap_set_buffer_size(created, 4 * 1024 * 1024)
            let result = pcap_activate(created)
            if result < 0 {
                failure = "\(String(cString: pcap_statustostr(result))): \(String(cString: pcap_geterr(created)))"
                pcap_close(created)
                continue
            }
            handle = created
            break
        }
        guard let handle else {
            let reason = geteuid() == 0 ? failure : "needs root"
            lock.withLock { status = reason }
            throw CaptureError.unavailable(reason)
        }
        lock.withLock {
            running = true
            status = "running"
        }
        nonisolated(unsafe) let capture = handle
        let thread = Thread { [self] in loop(capture) }
        thread.name = "switchboard.capture"
        thread.start()
    }

    public func stop() {
        lock.withLock { running = false }
    }

    public func pollCapture(now: EngineTime) -> [CaptureObservation] {
        lock.lock()
        defer { lock.unlock() }
        let drained = pending
        pending.removeAll(keepingCapacity: true)
        return drained
    }

    private func loop(_ handle: OpaquePointer) {
        var inspector = PacketInspector()
        var sinceStats = 0
        while lock.withLock({ running }) {
            var header: UnsafeMutablePointer<pcap_pkthdr>?
            var data: UnsafePointer<UInt8>?
            let result = pcap_next_ex(handle, &header, &data)
            if result == 0 { continue }
            guard result == 1, let header, let data else {
                lock.withLock {
                    running = false
                    status = "stopped: \(String(cString: pcap_geterr(handle)))"
                }
                break
            }
            let found = inspector.inspect(UnsafeRawBufferPointer(start: data, count: Int(header.pointee.caplen)))
            sinceStats += 1
            if !found.isEmpty || sinceStats >= 256 {
                var counters = pcap_stat()
                let haveCounters = sinceStats >= 256 && pcap_stats(handle, &counters) == 0
                lock.lock()
                pending.append(contentsOf: found)
                // If nobody is collecting, do not let the queue grow without limit.
                if pending.count > 20_000 { pending.removeFirst(pending.count - 20_000) }
                stats = inspector.stats
                if haveCounters { dropped = counters.ps_drop }
                lock.unlock()
                if sinceStats >= 256 { sinceStats = 0 }
            }
        }
        pcap_close(handle)
    }
}
