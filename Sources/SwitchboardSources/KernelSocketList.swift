import CDarwinPrivate
import Darwin
import SwitchboardCore

/// One socket as the kernel reports it in `net.inet.{tcp,udp}.pcblist_n`.
public struct KernelSocket: Sendable, Hashable {
    public var proto: TransportProtocol
    /// The socket accepts IPv4 traffic.
    public var isIPv4: Bool
    /// The socket accepts IPv6 traffic. A dual-stack socket sets both flags.
    public var isIPv6: Bool
    public var localAddress: IPAddress
    public var localPort: UInt16
    public var remoteAddress: IPAddress
    public var remotePort: UInt16
    /// The process that last used the socket.
    public var pid: pid_t
    /// The process the socket is acting for, when it is delegated; otherwise equal to `pid`.
    public var effectivePID: pid_t
    public var uid: uid_t
    public var rxBytes: UInt64
    public var txBytes: UInt64
    public var rxPackets: UInt64
    public var txPackets: UInt64
    /// `TCPS_*` value. `nil` for UDP.
    public var tcpState: Int32?
    /// Kernel address of the socket; stable for its lifetime.
    public var socketID: UInt64
    /// Kernel generation count; changes if the socket slot is reused.
    public var generation: UInt64

    public var tcpStateName: String? {
        guard let tcpState else { return nil }
        let names = [
            "CLOSED", "LISTEN", "SYN_SENT", "SYN_RECEIVED", "ESTABLISHED", "CLOSE_WAIT",
            "FIN_WAIT_1", "CLOSING", "LAST_ACK", "FIN_WAIT_2", "TIME_WAIT",
        ]
        return names.indices.contains(Int(tcpState)) ? names[Int(tcpState)] : "STATE_\(tcpState)"
    }
}

public enum KernelSocketListError: Error, CustomStringConvertible {
    case sysctl(name: String, errno: Int32)
    /// The kernel's records do not match the layout this build was written against.
    case layout(String)

    public var description: String {
        switch self {
        case .sysctl(let name, let code):
            "sysctl \(name) failed: \(String(cString: strerror(code)))"
        case .layout(let detail):
            "kernel socket list layout mismatch: \(detail)"
        }
    }
}

/// Reads the kernel's list of internet sockets. Needs no privileges.
public enum KernelSocketList {
    /// Record kinds, from XNU's `XSO_*`.
    public enum Kind {
        public static let socket: UInt32 = 0x001
        public static let receiveBuffer: UInt32 = 0x002
        public static let sendBuffer: UInt32 = 0x004
        public static let stats: UInt32 = 0x008
        public static let inpcb: UInt32 = 0x010
        public static let tcpcb: UInt32 = 0x020
    }

    /// Record length each kind must have for our declarations to be valid.
    /// The TCP record is longer than the prefix we declare, so it is a minimum.
    public static let expectedRecordLengths: [(kind: UInt32, name: String, length: Int, exact: Bool)] = [
        (Kind.socket, "socket", MemoryLayout<sb_xsocket_n>.size, true),
        (Kind.receiveBuffer, "rcvbuf", MemoryLayout<sb_xsockbuf_n>.size, true),
        (Kind.sendBuffer, "sndbuf", MemoryLayout<sb_xsockbuf_n>.size, true),
        (Kind.stats, "stats", MemoryLayout<sb_xsockstat_n>.size, true),
        (Kind.inpcb, "inpcb", MemoryLayout<sb_xinpcb_n>.size, true),
        (Kind.tcpcb, "tcpcb", MemoryLayout<sb_xtcpcb_n_prefix>.size, false),
    ]

    public struct Snapshot: Sendable {
        public var sockets: [KernelSocket]
        /// Record length the kernel actually used, per kind.
        public var observedRecordLengths: [UInt32: Int]
        public var bufferBytes: Int
    }

    public static func snapshot(_ proto: TransportProtocol) throws -> Snapshot {
        let name = "net.inet.\(proto.rawValue).pcblist_n"
        let buffer = try readSysctl(name)
        return try buffer.withUnsafeBytes { try parse($0, proto: proto) }
    }

    /// Parses a raw `pcblist_n` buffer. Exposed so recorded buffers can be replayed in tests.
    public static func parse(_ raw: UnsafeRawBufferPointer, proto: TransportProtocol) throws -> Snapshot {
        let headerSize = MemoryLayout<sb_xinpgen>.size
        guard raw.count >= headerSize else {
            throw KernelSocketListError.layout("buffer is \(raw.count) bytes, shorter than its header")
        }
        let header = raw.loadUnaligned(as: sb_xinpgen.self)
        guard Int(header.xig_len) == headerSize else {
            throw KernelSocketListError.layout("header length \(header.xig_len), expected \(headerSize)")
        }

        let wanted: UInt32 = Kind.socket | Kind.receiveBuffer | Kind.sendBuffer | Kind.stats | Kind.inpcb
            | (proto == .tcp ? Kind.tcpcb : 0)

        var sockets: [KernelSocket] = []
        var observed: [UInt32: Int] = [:]

        var socket = sb_xsocket_n()
        var inpcb = sb_xinpcb_n()
        var stats = sb_xsockstat_n()
        var tcpcb = sb_xtcpcb_n_prefix()
        var seen: UInt32 = 0

        var offset = roundUp8(headerSize)
        while offset + MemoryLayout<sb_xgen_n>.size <= raw.count {
            let prefix = raw.loadUnaligned(fromByteOffset: offset, as: sb_xgen_n.self)
            let length = Int(prefix.xgn_len)
            // The list ends with a second copy of the header.
            if length <= headerSize { break }
            guard offset + length <= raw.count else {
                throw KernelSocketListError.layout("record at \(offset) runs past the buffer")
            }
            let kind = prefix.xgn_kind

            if wanted & kind != 0 {
                guard seen & kind == 0 else {
                    throw KernelSocketListError.layout("record kind \(kind) repeated within one socket")
                }
                if let expected = expectedRecordLengths.first(where: { $0.kind == kind }) {
                    let ok = expected.exact ? length == expected.length : length >= expected.length
                    guard ok else {
                        throw KernelSocketListError.layout(
                            "\(expected.name) record is \(length) bytes, expected \(expected.exact ? "" : "at least ")\(expected.length)"
                        )
                    }
                }
                observed[kind] = length
                switch kind {
                case Kind.socket: socket = raw.loadUnaligned(fromByteOffset: offset, as: sb_xsocket_n.self)
                case Kind.inpcb: inpcb = raw.loadUnaligned(fromByteOffset: offset, as: sb_xinpcb_n.self)
                case Kind.stats: stats = raw.loadUnaligned(fromByteOffset: offset, as: sb_xsockstat_n.self)
                case Kind.tcpcb: tcpcb = raw.loadUnaligned(fromByteOffset: offset, as: sb_xtcpcb_n_prefix.self)
                default: break
                }
                seen |= kind
            }
            offset += roundUp8(length)

            if seen == wanted {
                sockets.append(makeSocket(proto: proto, socket: socket, inpcb: inpcb, stats: stats, tcpcb: tcpcb))
                seen = 0
            }
        }

        return Snapshot(sockets: sockets, observedRecordLengths: observed, bufferBytes: raw.count)
    }

    private static func makeSocket(
        proto: TransportProtocol,
        socket: sb_xsocket_n,
        inpcb: sb_xinpcb_n,
        stats: sb_xsockstat_n,
        tcpcb: sb_xtcpcb_n_prefix
    ) -> KernelSocket {
        let isIPv4 = inpcb.inp_vflag & 0x1 != 0
        let isIPv6 = inpcb.inp_vflag & 0x2 != 0

        func address(_ words: (UInt32, UInt32, UInt32, UInt32)) -> IPAddress {
            let bytes = withUnsafeBytes(of: words) { Array($0) }
            let chosen = isIPv6 ? bytes[...] : bytes[12...]
            return IPAddress(networkBytes: chosen) ?? .v4(0)
        }

        var rxBytes: UInt64 = 0, txBytes: UInt64 = 0, rxPackets: UInt64 = 0, txPackets: UInt64 = 0
        withUnsafeBytes(of: stats.xst_tc_stats) { classes in
            for index in 0..<Int(SB_SO_TC_STATS_MAX) {
                let entry = classes.loadUnaligned(
                    fromByteOffset: index * MemoryLayout<sb_data_stats>.stride, as: sb_data_stats.self)
                rxBytes &+= entry.rxbytes
                txBytes &+= entry.txbytes
                rxPackets &+= entry.rxpackets
                txPackets &+= entry.txpackets
            }
        }

        return KernelSocket(
            proto: proto,
            isIPv4: isIPv4,
            isIPv6: isIPv6,
            localAddress: address(inpcb.inp_laddr),
            localPort: UInt16(bigEndian: inpcb.inp_lport),
            remoteAddress: address(inpcb.inp_faddr),
            remotePort: UInt16(bigEndian: inpcb.inp_fport),
            pid: socket.so_last_pid,
            effectivePID: socket.so_e_pid,
            uid: socket.so_uid,
            rxBytes: rxBytes,
            txBytes: txBytes,
            rxPackets: rxPackets,
            txPackets: txPackets,
            tcpState: proto == .tcp ? tcpcb.t_state : nil,
            socketID: socket.xso_so,
            generation: socket.so_gencnt
        )
    }

    private static func roundUp8(_ value: Int) -> Int {
        value > 0 ? (value + 7) & ~7 : 8
    }

    private static func readSysctl(_ name: String) throws -> [UInt8] {
        var needed = 0
        guard sysctlbyname(name, nil, &needed, nil, 0) == 0 else {
            throw KernelSocketListError.sysctl(name: name, errno: errno)
        }
        // The list can grow between the size query and the read, so leave headroom and retry.
        var capacity = needed + needed / 4 + 4096
        for _ in 0..<4 {
            var buffer = [UInt8](repeating: 0, count: capacity)
            var length = capacity
            let result = buffer.withUnsafeMutableBytes { sysctlbyname(name, $0.baseAddress, &length, nil, 0) }
            if result == 0 {
                buffer.removeSubrange(length...)
                return buffer
            }
            guard errno == ENOMEM else {
                throw KernelSocketListError.sysctl(name: name, errno: errno)
            }
            capacity *= 2
        }
        throw KernelSocketListError.sysctl(name: name, errno: ENOMEM)
    }
}
