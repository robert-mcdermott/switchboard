import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardSources

/// The shape of NetworkStatistics' dictionaries as observed on macOS 27.2
/// (docs/spikes/M0-findings.md, S2). If a macOS update changes the keys, these fail.
@Suite struct NStatDecodingTests {
    static func sockaddr4(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8, port: UInt16) -> Data {
        Data([16, UInt8(AF_INET), UInt8(port >> 8), UInt8(port & 0xff), a, b, c, d, 0, 0, 0, 0, 0, 0, 0, 0])
    }

    static func sockaddr6(lastByte: UInt8, port: UInt16) -> Data {
        var bytes = [UInt8](repeating: 0, count: 28)
        bytes[0] = 28
        bytes[1] = UInt8(AF_INET6)
        bytes[2] = UInt8(port >> 8)
        bytes[3] = UInt8(port & 0xff)
        bytes[8] = 0x26
        bytes[23] = lastByte
        return Data(bytes)
    }

    static let clock = NStatSource.MachClock(secondsPerTick: 1e-9)

    static func established() -> NSMutableDictionary {
        [
            "provider": "TCP", "processID": 6526, "processName": "Cursor Helper", "uniqueProcessID": 2_158_009,
            "localAddress": sockaddr4(10, 0, 0, 36, port: 52_551),
            "remoteAddress": sockaddr4(52, 21, 130, 202, port: 443),
            "TCPState": "Established", "rxBytes": 9110, "txBytes": 2408, "rxPackets": 14, "txPackets": 11,
            "rttAverage": 0.03125, "txRetransmittedBytes": 120, "interface": 0,
            "startAbsoluteTime": 4_000_000_000,
        ]
    }

    @Test func decodesAnEstablishedTCPFlow() throws {
        let observation = try #require(NStatSource.observation(
            from: Self.established(), sourceID: 77, clock: Self.clock, interfaces: nil, machNow: 10_000_000_000))
        #expect(observation.sourceID == 77)
        #expect(observation.proto == .tcp)
        #expect(observation.local.description == "10.0.0.36:52551")
        #expect(observation.remote.description == "52.21.130.202:443")
        #expect(observation.pid == 6526)
        #expect(observation.processName == "Cursor Helper")
        #expect(observation.uniquePID == 2_158_009)
        #expect(observation.tcpState == .established)
        #expect(observation.rxBytes == 9110)
        #expect(observation.txBytes == 2408)
        #expect(observation.rttMS == 31.25)
        #expect(observation.retransmittedBytes == 120)
        #expect(observation.ageSeconds == 6)
    }

    @Test func decodesIPv6AndUDP() throws {
        let dictionary: NSDictionary = [
            "provider": "UDP", "processID": 60_828, "processName": "Brave Browser Helper",
            "localAddress": Self.sockaddr6(lastByte: 0x24, port: 50_566),
            "remoteAddress": Self.sockaddr6(lastByte: 0x0e, port: 443),
            "rxBytes": 51_866, "txBytes": 16_613,
        ]
        let observation = try #require(NStatSource.observation(
            from: dictionary, sourceID: 1, clock: Self.clock, interfaces: nil, machNow: 1))
        #expect(observation.proto == .udp)
        #expect(observation.remote.description == "[2600::e]:443")
        #expect(observation.tcpState == nil)
        #expect(observation.rttMS == nil)
        #expect(observation.ageSeconds == nil)
    }

    @Test func treatsAMissingRemoteAsAWildcard() throws {
        let dictionary = Self.established()
        dictionary.removeObject(forKey: "remoteAddress")
        dictionary["TCPState"] = "Listen"
        let observation = try #require(NStatSource.observation(
            from: dictionary, sourceID: 1, clock: Self.clock, interfaces: nil, machNow: 5_000_000_000))
        #expect(observation.remote.isWildcard)
        #expect(observation.tcpState == .listen)
    }

    @Test func rejectsWhatItCannotUse() {
        let noOwner = Self.established()
        noOwner.removeObject(forKey: "processID")
        #expect(NStatSource.observation(from: noOwner, sourceID: 1, clock: Self.clock, interfaces: nil) == nil)

        let otherProvider = Self.established()
        otherProvider["provider"] = "Route"
        #expect(NStatSource.observation(from: otherProvider, sourceID: 1, clock: Self.clock, interfaces: nil) == nil)

        let shortAddress = Self.established()
        shortAddress["localAddress"] = Data([1, 2, 3])
        #expect(NStatSource.observation(from: shortAddress, sourceID: 1, clock: Self.clock, interfaces: nil) == nil)
    }

    @Test func ignoresAStartTimeInTheFuture() throws {
        let observation = try #require(NStatSource.observation(
            from: Self.established(), sourceID: 1, clock: Self.clock, interfaces: nil, machNow: 1_000))
        #expect(observation.ageSeconds == nil)
    }

    @Test func mapsEveryStateNameTheFrameworkUses() {
        let names = ["Closed", "Listen", "SynSent", "SynReceived", "Established", "CloseWait",
                     "FinWait1", "Closing", "LastAck", "FinWait2", "TimeWait"]
        #expect(names.compactMap(NStatSource.tcpState(named:)) == TCPState.allCases)
        #expect(NStatSource.tcpState(named: "Bogus") == nil)
    }
}

/// `nettop -L 0 -x -n` output in the shape observed on macOS 27.2.
@Suite struct NettopParserTests {
    static let header = "time,,interface,state,bytes_in,bytes_out,rx_dupe,rx_ooo,re-tx,rtt_avg,rcvsize,tx_win,tc_class,tc_mgt,cc_algo,P,C,R,W,arch,"

    static let firstBlock = [
        header,
        "20:16:42.957704,launchd.1,,,0,0,0,0,0,,,,,,,,,,,,",
        "20:16:42.955016,tcp4 127.0.0.1:8021<->*:*,lo0,Listen,,,,,,,,,,-,cubic,-,-,-,-,so,",
        "20:16:42.954997,tcp6 ::1.8021<->*.*,lo0,Listen,,,,,,,,,,-,cubic,-,-,-,-,so,",
        "20:16:42.954000,Brave Browser He.60828,,,81234,9120,0,0,0,,,,,,,,,,,,",
        "20:16:42.953000,tcp4 10.0.0.36:58555<->44.215.138.159:443,en0,Established,10732,1973,0,0,96,31.25 ms,131072,65535,BE,-,cubic,-,-,-,-,so,",
        "20:16:42.952000,quic6 2601:602:8182:9b00::24.50566<->2607:f8b0:400a:80a::200e.443,en0,,51866,16613,,,,12.50 ms,,,BE,-,,-,-,-,-,ch,",
        "20:16:42.951000,udp4 *:5353<->*:*,en0,,1200,800,,,,,,,BE,-,,-,-,-,-,so,",
    ]

    static func feed(_ parser: inout NettopParser, _ lines: [String]) -> [SourceEvent] {
        lines.flatMap { parser.consume($0[...]) }
    }

    static func observations(_ events: [SourceEvent]) -> [SocketObservation] {
        events.compactMap { if case .seen(let observation) = $0 { observation } else { nil } }
    }

    @Test func readsProcessesAndTheirSockets() {
        var parser = NettopParser()
        let seen = Self.observations(Self.feed(&parser, Self.firstBlock))
        #expect(seen.count == 5)

        #expect(seen[0].pid == 1)
        #expect(seen[0].processName == "launchd")
        #expect(seen[0].tcpState == .listen)
        #expect(seen[0].local.description == "127.0.0.1:8021")
        #expect(seen[0].remote.isWildcard)
        #expect(seen[1].local.description == "[::1]:8021")

        let tcp = seen[2]
        #expect(tcp.pid == 60_828)
        #expect(tcp.processName == "Brave Browser He")
        #expect(tcp.remote.description == "44.215.138.159:443")
        #expect(tcp.rxBytes == 10_732)
        #expect(tcp.txBytes == 1973)
        #expect(tcp.tcpState == .established)
        #expect(tcp.retransmittedBytes == 96)
        #expect(tcp.rttMS == 31.25)
        #expect(tcp.interface == "en0")

        let quic = seen[3]
        #expect(quic.proto == .udp)
        #expect(quic.serviceHint == "QUIC")
        #expect(quic.remote.description == "[2607:f8b0:400a:80a::200e]:443")
        #expect(quic.remote.port == 443)

        #expect(seen[4].proto == .udp)
        #expect(seen[4].local.port == 5353)
        #expect(seen[4].remote.isWildcard)
    }

    @Test func reportsSocketsThatDisappearBetweenSamples() {
        var parser = NettopParser()
        let first = Self.observations(Self.feed(&parser, Self.firstBlock))
        // Second sample: the Brave TCP connection is gone.
        let second = Self.firstBlock.filter { !$0.contains("44.215.138.159") }
        let events = Self.feed(&parser, second)
        #expect(Self.observations(events).count == 4)
        // The removal is only known once the second sample is complete, at the next header.
        #expect(!events.contains { if case .removed = $0 { true } else { false } })
        let closing = parser.consume(Self.header[...])
        #expect(closing == [.removed(sourceID: first[2].sourceID)])
    }

    @Test func givesTheSameSocketTheSameIdentityEachSample() {
        var parser = NettopParser()
        let first = Self.observations(Self.feed(&parser, Self.firstBlock)).map(\.sourceID)
        let second = Self.observations(Self.feed(&parser, Self.firstBlock)).map(\.sourceID)
        #expect(first == second)
        #expect(Set(first).count == first.count)
    }

    @Test func skipsWhatItDoesNotRecognise() {
        var parser = NettopParser()
        let lines = [
            Self.header,
            "garbage",
            "20:16:42.9,tcp4 10.0.0.1:1<->10.0.0.2:2,en0,Established,1,1,,,,,,,,,,,,,,,",  // no owning process yet
            "20:16:42.9,weird.name.with.dots.4242,,,0,0,0,0,0,,,,,,,,,,,,",
            "20:16:42.9,sctp4 10.0.0.1:1<->10.0.0.2:2,en0,,1,1,,,,,,,,,,,,,,,",
            "20:16:42.9,tcp4 not-an-address:1<->10.0.0.2:2,en0,Established,1,1,,,,,,,,,,,,,,,",
            "20:16:42.9,tcp4 10.0.0.1:5000<->10.0.0.2:443,en0,Established,7,9,,,,,,,,,,,,,,,",
        ]
        let seen = Self.observations(Self.feed(&parser, lines))
        #expect(seen.count == 1)
        #expect(seen.first?.pid == 4242)
        #expect(seen.first?.processName == "weird.name.with.dots")
    }
}
