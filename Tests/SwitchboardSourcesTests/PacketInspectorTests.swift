import CDarwinPrivate
import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardSources

/// Packets built by hand in the shape PKTAP delivers them (verified against live capture
/// in docs/spikes/M0-findings.md, S3), since capturing real ones needs root.
enum Packet {
    static func be16(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xff), UInt8(value & 0xff)] }

    static func pktap(pid: Int32 = 664, effectivePID: Int32 = 0, linkType: UInt32 = 1, headerLength: UInt32? = nil) -> [UInt8] {
        var header = sb_pktap_header()
        header.pth_length = headerLength ?? UInt32(MemoryLayout<sb_pktap_header>.size)
        header.pth_type_next = 1
        header.pth_dlt = linkType
        header.pth_pid = pid
        header.pth_epid = effectivePID
        header.pth_frame_pre_length = linkType == 1 ? 14 : (linkType == 0 ? 4 : 0)
        return withUnsafeBytes(of: header) { Array($0) }
    }

    static let ethernet = [UInt8](repeating: 0x11, count: 12) + [0x08, 0x00]
    static let loopback: [UInt8] = [30, 0, 0, 0]

    static func ipv4(_ source: String, _ destination: String, proto: UInt8, payload: [UInt8], fragmentOffset: Int = 0) -> [UInt8] {
        var bytes: [UInt8] = [0x45, 0] + be16(20 + payload.count) + [0, 0] + be16(fragmentOffset) + [64, proto, 0, 0]
        bytes += IPAddress(source)!.networkBytes + IPAddress(destination)!.networkBytes
        return bytes + payload
    }

    static func ipv6(_ source: String, _ destination: String, proto: UInt8, payload: [UInt8]) -> [UInt8] {
        var bytes: [UInt8] = [0x60, 0, 0, 0] + be16(payload.count) + [proto, 64]
        bytes += IPAddress(source)!.networkBytes + IPAddress(destination)!.networkBytes
        return bytes + payload
    }

    static func udp(_ sourcePort: Int, _ destinationPort: Int, _ payload: [UInt8]) -> [UInt8] {
        be16(sourcePort) + be16(destinationPort) + be16(8 + payload.count) + [0, 0] + payload
    }

    static func tcp(_ sourcePort: Int, _ destinationPort: Int, _ payload: [UInt8]) -> [UInt8] {
        be16(sourcePort) + be16(destinationPort) + [0, 0, 0, 1, 0, 0, 0, 1, 0x50, 0x18, 0xff, 0xff, 0, 0, 0, 0] + payload
    }
}

@Suite struct PacketInspectorTests {
    static func inspect(_ inspector: inout PacketInspector, _ packet: [UInt8]) -> [CaptureObservation] {
        packet.withUnsafeBytes { inspector.inspect($0) }
    }

    static let client = Endpoint(address: IPAddress("10.0.0.36")!, port: 52_551)
    static let server = Endpoint(address: IPAddress("93.184.216.34")!, port: 443)

    static func hello(_ name: String, in segments: Int = 1) -> [[UInt8]] {
        let whole = TLSParserTests.clientHello(serverName: name)
        let size = (whole.count + segments - 1) / segments
        return stride(from: 0, to: whole.count, by: size).map { start in
            Packet.pktap(pid: 6526) + Packet.ethernet + Packet.ipv4(
                "10.0.0.36", "93.184.216.34", proto: 6,
                payload: Packet.tcp(52_551, 443, Array(whole[start..<min(start + size, whole.count)])))
        }
    }

    @Test func readsADNSAnswerAndWhoAsked() {
        var inspector = PacketInspector()
        // The resolver (pid 664) answering on behalf of pid 6526.
        let packet = Packet.pktap(pid: 664, effectivePID: 6526) + Packet.ethernet
            + Packet.ipv4("10.0.0.1", "10.0.0.36", proto: 17, payload: Packet.udp(53, 61_000, DNSParserTests.response))
        let found = Self.inspect(&inspector, packet)
        #expect(found.first == .resolved(name: "example.com", addresses: [IPAddress("93.184.216.34")!], pid: 6526))
        #expect(found.count == 2)
        guard case .service(.udp, _, _, "DNS") = found[1] else {
            Issue.record("expected the DNS service observation")
            return
        }
        #expect(inspector.stats.dnsAnswers == 1)
    }

    @Test func doesNotInventAnAskerWhenTheResolverActedForItself() {
        var inspector = PacketInspector()
        let packet = Packet.pktap(pid: 664, effectivePID: 664) + Packet.ethernet
            + Packet.ipv4("10.0.0.1", "10.0.0.36", proto: 17, payload: Packet.udp(53, 61_000, DNSParserTests.response))
        #expect(Self.inspect(&inspector, packet).first == .resolved(name: "example.com", addresses: [IPAddress("93.184.216.34")!], pid: nil))
    }

    @Test func ignoresDNSQueriesAndAnswersWithNoAddresses() {
        var inspector = PacketInspector()
        var query = DNSParserTests.response
        query[2] = 0x01  // clear the response bit
        let packet = Packet.pktap() + Packet.ethernet + Packet.ipv4("10.0.0.36", "10.0.0.1", proto: 17, payload: Packet.udp(61_000, 53, query))
        #expect(Self.inspect(&inspector, packet).isEmpty)
    }

    @Test func readsATLSServerNameFromOneSegment() {
        var inspector = PacketInspector()
        let found = Self.inspect(&inspector, Self.hello("switchboard.example")[0])
        #expect(found == [
            .serverName(proto: .tcp, from: Self.client, to: Self.server, name: "switchboard.example"),
            .service(proto: .tcp, from: Self.client, to: Self.server, service: "TLS"),
        ])
        #expect(inspector.stats.serverNames == 1)
        #expect(inspector.stats.reassembled == 0)
    }

    @Test func assemblesAHelloThatSpansSegments() {
        for segments in [2, 3, 5] {
            var inspector = PacketInspector()
            let packets = Self.hello("a-long-name.cdn.example.net", in: segments)
            #expect(packets.count == segments)
            for packet in packets.dropLast() { #expect(Self.inspect(&inspector, packet).isEmpty) }
            let found = Self.inspect(&inspector, packets.last!)
            #expect(found.first == .serverName(proto: .tcp, from: Self.client, to: Self.server, name: "a-long-name.cdn.example.net"))
            #expect(inspector.stats.reassembled == 1)
        }
    }

    @Test func keepsInterleavedConnectionsApart() {
        var inspector = PacketInspector()
        let first = Self.hello("first.example", in: 2)
        let other = Packet.pktap() + Packet.ethernet + Packet.ipv4(
            "10.0.0.36", "1.1.1.1", proto: 6, payload: Packet.tcp(40_000, 443, TLSParserTests.clientHello(serverName: "second.example")))
        #expect(Self.inspect(&inspector, first[0]).isEmpty)
        guard case .serverName(_, _, _, "second.example") = Self.inspect(&inspector, other).first else {
            Issue.record("the complete hello on another connection should be read at once")
            return
        }
        guard case .serverName(_, _, _, "first.example") = Self.inspect(&inspector, first[1]).first else {
            Issue.record("the split hello should still complete")
            return
        }
    }

    @Test func reportsQUICOncePerConnection() {
        var inspector = PacketInspector()
        let initial = [UInt8](repeating: 0xC3, count: 1200)
        let out = Packet.pktap() + Packet.ethernet + Packet.ipv4("10.0.0.36", "142.250.1.1", proto: 17, payload: Packet.udp(50_566, 443, initial))
        let back = Packet.pktap() + Packet.ethernet + Packet.ipv4("142.250.1.1", "10.0.0.36", proto: 17, payload: Packet.udp(443, 50_566, initial))
        #expect(Self.inspect(&inspector, out).count == 1)
        #expect(Self.inspect(&inspector, out).isEmpty)
        #expect(Self.inspect(&inspector, back).isEmpty)
        // Short packets on 443, and long-header-looking packets elsewhere, are not QUIC handshakes.
        let short = Packet.pktap() + Packet.ethernet + Packet.ipv4("10.0.0.36", "8.8.8.8", proto: 17, payload: Packet.udp(50_000, 443, [0xC3, 1, 2, 3]))
        let elsewhere = Packet.pktap() + Packet.ethernet + Packet.ipv4("10.0.0.36", "8.8.8.8", proto: 17, payload: Packet.udp(50_000, 8801, initial))
        #expect(Self.inspect(&inspector, short).isEmpty)
        #expect(Self.inspect(&inspector, elsewhere).isEmpty)
        #expect(inspector.stats.quicFlows == 1)
    }

    @Test func readsIPv6AndOtherLinkTypes() {
        var inspector = PacketInspector()
        let hello = TLSParserTests.clientHello(serverName: "v6.example")
        let overLoopback = Packet.pktap(linkType: 0) + Packet.loopback
            + Packet.ipv6("2601:602::24", "2606:4700::1", proto: 6, payload: Packet.tcp(51_000, 443, hello))
        guard case .serverName(_, let from, let to, "v6.example") = Self.inspect(&inspector, overLoopback).first else {
            Issue.record("server name not read over IPv6")
            return
        }
        #expect(from.description == "[2601:602::24]:51000")
        #expect(to.description == "[2606:4700::1]:443")

        let raw = Packet.pktap(linkType: 12) + Packet.ipv4("10.0.0.36", "1.1.1.1", proto: 6, payload: Packet.tcp(51_001, 443, hello))
        #expect(Self.inspect(&inspector, raw).count == 2)
    }

    @Test func dismissesEverythingElse() {
        var inspector = PacketInspector()
        let web = Packet.pktap() + Packet.ethernet + Packet.ipv4("10.0.0.36", "1.1.1.1", proto: 6, payload: Packet.tcp(51_000, 80, Array("GET / HTTP/1.1\r\n".utf8)))
        let ack = Packet.pktap() + Packet.ethernet + Packet.ipv4("10.0.0.36", "1.1.1.1", proto: 6, payload: Packet.tcp(51_000, 443, []))
        let data = Packet.pktap() + Packet.ethernet + Packet.ipv4("10.0.0.36", "1.1.1.1", proto: 6, payload: Packet.tcp(51_000, 443, [0x17, 0x03, 0x03, 0, 5, 1, 2, 3, 4, 5]))
        let ping = Packet.pktap() + Packet.ethernet + Packet.ipv4("10.0.0.36", "1.1.1.1", proto: 1, payload: [8, 0, 0, 0, 0, 0, 0, 0])
        let fragment = Packet.pktap() + Packet.ethernet + Packet.ipv4(
            "10.0.0.1", "10.0.0.36", proto: 17, payload: Packet.udp(53, 61_000, DNSParserTests.response), fragmentOffset: 100)
        for packet in [web, ack, data, ping, fragment] { #expect(Self.inspect(&inspector, packet).isEmpty) }
        #expect(inspector.stats.packets == 5)
    }

    @Test func refusesAHeaderItDoesNotRecognise() {
        var inspector = PacketInspector()
        let packet = Packet.pktap(headerLength: 180) + Self.hello("x.example")[0].dropFirst(156)
        #expect(Self.inspect(&inspector, Array(packet)).isEmpty)
        #expect(inspector.stats.unexpectedHeader == 1)
    }

    @Test func survivesEveryTruncationAndRandomNoise() {
        var inspector = PacketInspector()
        let samples = [
            Self.hello("switchboard.example")[0],
            Packet.pktap(effectivePID: 9) + Packet.ethernet + Packet.ipv4("10.0.0.1", "10.0.0.36", proto: 17, payload: Packet.udp(53, 61_000, DNSParserTests.response)),
            Packet.pktap(linkType: 0) + Packet.loopback + Packet.ipv6("::1", "::1", proto: 6, payload: Packet.tcp(1, 443, TLSParserTests.clientHello(serverName: "l.example"))),
        ]
        for sample in samples {
            for length in 0...sample.count { _ = Self.inspect(&inspector, Array(sample.prefix(length))) }
        }
        var random = SplitMix64(seed: 0xCA97)
        let header = Packet.pktap()
        for _ in 0..<3000 {
            // A valid capture header in front of noise, so the noise reaches the parsers.
            let noise = (0..<random.below(300)).map { _ in UInt8(truncatingIfNeeded: random.next()) }
            _ = Self.inspect(&inspector, header + Packet.ethernet + noise)
        }
        #expect(inspector.stats.packets > 3000)
    }
}
