import CDarwinPrivate
import Foundation
import SwitchboardCore

/// Spike S3: does PKTAP still annotate each captured packet with the owning process,
/// and can we read DNS answers and TLS server names from the capture?
///
/// Needs root, because `/dev/bpf*` is root-only. Captures for a few seconds, keeps
/// nothing, and prints a summary.
public enum PktapProbe {
    public static func run(seconds: Double) -> (lines: [String], ok: Bool) {
        var lines: [String] = []
        var errorBuffer = [CChar](repeating: 0, count: Int(PCAP_ERRBUF_SIZE))

        var handle: OpaquePointer?
        var device = ""
        for candidate in ["pktap,all", "pktap"] {
            guard let created = pcap_create(candidate, &errorBuffer) else {
                lines.append("pcap_create(\(candidate)) failed: \(text(errorBuffer))")
                continue
            }
            pcap_set_want_pktap(created, 1)
            pcap_set_snaplen(created, 2048)
            pcap_set_timeout(created, 200)
            pcap_set_immediate_mode(created, 1)
            let status = pcap_activate(created)
            if status < 0 {
                lines.append(
                    "pcap_activate(\(candidate)) failed: \(String(cString: pcap_statustostr(status))) — \(String(cString: pcap_geterr(created)))"
                )
                pcap_close(created)
                continue
            }
            handle = created
            device = candidate
            break
        }
        guard let handle else {
            if geteuid() != 0 { lines.append("not running as root; rerun with sudo") }
            return (lines, false)
        }
        defer { pcap_close(handle) }

        let datalink = pcap_datalink(handle)
        lines.append("capturing on \(device), datalink \(datalink) (149 is Apple's PKTAP), snaplen 2048")

        // Whether libpcap can compile a filter against the PKTAP link type. Not applied:
        // the probe wants to see every packet to judge attribution.
        var program = bpf_program()
        if pcap_compile(handle, &program, "port 53 or tcp port 443", 1, PCAP_NETMASK_UNKNOWN) == 0 {
            lines.append("BPF filter compiles against this link type: yes")
            pcap_freecode(&program)
        } else {
            lines.append("BPF filter compiles against this link type: no — \(String(cString: pcap_geterr(handle)))")
        }

        // Provoke one lookup of our own, to see whether the resolver's packets name us
        // as the effective process.
        let probeName = "sb-probe-\(UInt32.random(in: 0...UInt32.max)).example.com"
        let ownPID = getpid()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.7) {
            var result: UnsafeMutablePointer<addrinfo>?
            if getaddrinfo(probeName, nil, nil, &result) == 0 { freeaddrinfo(result) }
        }

        let expectedHeader = MemoryLayout<sb_pktap_header>.size
        var headerLengths: [Int: Int] = [:]
        var packets = 0, withPID = 0, delegated = 0, inbound = 0, outbound = 0
        var ipParsed = 0, linkLengthDisagreements = 0
        var perProcess: [String: Int] = [:]
        var dnsLines: [String] = []
        var dnsMessages = 0
        var ownLookup: String?
        var sniLines: [String] = []
        var clientHellos = 0, helloTruncated = 0, helloNoName = 0
        var firstHeaderDump: String?

        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            var headerPointer: UnsafeMutablePointer<pcap_pkthdr>?
            var dataPointer: UnsafePointer<UInt8>?
            let status = pcap_next_ex(handle, &headerPointer, &dataPointer)
            if status == 0 { continue }
            guard status == 1, let headerPointer, let dataPointer else {
                lines.append("pcap_next_ex returned \(status): \(String(cString: pcap_geterr(handle)))")
                break
            }
            let captured = Int(headerPointer.pointee.caplen)
            let raw = UnsafeRawBufferPointer(start: dataPointer, count: captured)
            guard captured >= 4 else { continue }
            packets += 1

            let headerLength = Int(raw.loadUnaligned(as: UInt32.self))
            headerLengths[headerLength, default: 0] += 1
            if firstHeaderDump == nil {
                firstHeaderDump = raw.prefix(min(captured, 160)).map { String(format: "%02x", $0) }.joined()
            }
            guard headerLength == expectedHeader, captured >= headerLength else { continue }

            let header = raw.loadUnaligned(as: sb_pktap_header.self)
            let command = withUnsafeBytes(of: header.pth_comm) { cString($0) }
            let effectiveCommand = withUnsafeBytes(of: header.pth_ecomm) { cString($0) }
            if header.pth_pid > 0 { withPID += 1 }
            if header.pth_epid > 0, header.pth_epid != header.pth_pid { delegated += 1 }
            if header.pth_flags & 0x1 != 0 { inbound += 1 }
            if header.pth_flags & 0x2 != 0 { outbound += 1 }
            perProcess["\(command)(\(header.pth_pid))", default: 0] += 1

            let owner: String = {
                let base = "\(command)(\(header.pth_pid))"
                return header.pth_epid > 0 && header.pth_epid != header.pth_pid
                    ? "\(base) for \(effectiveCommand)(\(header.pth_epid))" : base
            }()

            // Link header length: from the link type, cross-checked against the kernel's own figure.
            let linkLength: Int
            switch header.pth_dlt {
            case 1: linkLength = 14  // Ethernet
            case 0: linkLength = 4  // loopback
            case 12: linkLength = 0  // raw IP
            default: linkLength = Int(header.pth_frame_pre_length)
            }
            if linkLength != Int(header.pth_frame_pre_length) { linkLengthDisagreements += 1 }

            let frame = Array(raw[(headerLength + min(linkLength, captured - headerLength))...])
            guard let segment = transportSegment(of: frame) else { continue }
            ipParsed += 1

            if segment.isUDP, segment.sourcePort == 53 || segment.destinationPort == 53,
               let message = DNSParser.parse(segment.payload)
            {
                dnsMessages += 1
                if let question = message.question, question == probeName, ownLookup == nil || message.isResponse {
                    ownLookup = "own lookup seen from \(owner); effective pid \(header.pth_epid == ownPID ? "matches" : "does not match") this probe (\(ownPID))"
                }
                if message.isResponse, !message.addresses.isEmpty, dnsLines.count < 4 {
                    let answers = message.addresses.prefix(2).map { "\($0.address)" }.joined(separator: ", ")
                    dnsLines.append("DNS answer: \(message.question ?? "?") → \(answers) [\(owner)]")
                }
            }

            if !segment.isUDP, !segment.payload.isEmpty {
                switch TLSParser.serverName(inTCPPayload: segment.payload) {
                case .found(let name, let offset):
                    clientHellos += 1
                    if sniLines.count < 4 {
                        sniLines.append(
                            "TLS SNI: \(name) at payload offset \(offset) of \(segment.payload.count) [\(owner)]")
                    }
                case .truncated:
                    clientHellos += 1
                    helloTruncated += 1
                case .absent:
                    clientHellos += 1
                    helloNoName += 1
                case .notClientHello:
                    break
                }
            }
        }

        var stats = pcap_stat()
        let haveStats = pcap_stats(handle, &stats) == 0

        lines.append("packets captured: \(packets) in \(Int(seconds)) s")
        let lengthSummary = headerLengths.sorted { $0.key < $1.key }.map { "\($0.key) bytes ×\($0.value)" }
        lines.append("pktap header length: expected \(expectedHeader); observed \(lengthSummary.joined(separator: ", "))")
        if headerLengths.keys.contains(where: { $0 != expectedHeader }), let firstHeaderDump {
            lines.append("first packet (hex): \(firstHeaderDump)")
        }
        lines.append("packets carrying a pid: \(withPID) of \(packets)")
        lines.append("packets with a different effective pid: \(delegated)")
        lines.append("direction flags: \(inbound) in, \(outbound) out")
        lines.append("IP/transport parsed: \(ipParsed); link-length disagreements with kernel figure: \(linkLengthDisagreements)")
        let top = perProcess.sorted { $0.value > $1.value }.prefix(8).map { "\($0.key)×\($0.value)" }
        lines.append("top processes: \(top.joined(separator: ", "))")
        lines.append("DNS messages on port 53: \(dnsMessages)")
        lines.append(contentsOf: dnsLines)
        lines.append(ownLookup ?? "own lookup (\(probeName)) not seen on port 53 — the resolver may be using encrypted DNS")
        lines.append(
            "TLS ClientHellos: \(clientHellos) (\(helloTruncated) continue past the first segment, \(helloNoName) without a server name)"
        )
        lines.append(contentsOf: sniLines)
        if haveStats { lines.append("kernel drops: \(stats.ps_drop) of \(stats.ps_recv) received") }

        let ok = packets > 0 && headerLengths.keys.allSatisfy { $0 == expectedHeader } && withPID > 0
        return (lines, ok)
    }

    private struct Segment {
        var isUDP: Bool
        var sourcePort: UInt16
        var destinationPort: UInt16
        var payload: [UInt8]
    }

    /// Finds the TCP or UDP payload inside an IP packet.
    private static func transportSegment(of packet: [UInt8]) -> Segment? {
        guard let first = packet.first else { return nil }
        var offset: Int
        let proto: UInt8
        switch first >> 4 {
        case 4:
            guard packet.count >= 20 else { return nil }
            offset = Int(first & 0x0f) * 4
            proto = packet[9]
        case 6:
            guard packet.count >= 40 else { return nil }
            offset = 40
            proto = packet[6]
        default:
            return nil
        }
        guard offset >= 20, packet.count >= offset + 8 else { return nil }
        let sourcePort = UInt16(packet[offset]) << 8 | UInt16(packet[offset + 1])
        let destinationPort = UInt16(packet[offset + 2]) << 8 | UInt16(packet[offset + 3])
        switch proto {
        case 17:
            offset += 8
        case 6:
            guard packet.count >= offset + 20 else { return nil }
            offset += Int(packet[offset + 12] >> 4) * 4
        default:
            return nil
        }
        guard offset <= packet.count else { return nil }
        return Segment(
            isUDP: proto == 17, sourcePort: sourcePort, destinationPort: destinationPort,
            payload: Array(packet[offset...]))
    }

    private static func cString(_ bytes: UnsafeRawBufferPointer) -> String {
        let end = bytes.firstIndex(of: 0) ?? bytes.count
        return String(decoding: bytes[..<end], as: UTF8.self)
    }

    private static func text(_ buffer: [CChar]) -> String {
        buffer.withUnsafeBytes { cString($0) }
    }
}
