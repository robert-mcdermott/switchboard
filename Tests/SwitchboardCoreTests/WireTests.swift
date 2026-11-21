import Foundation
import Testing

@testable import SwitchboardCore

@Suite struct WireTests {
    static func observation(_ id: UInt64, full: Bool) -> SocketObservation {
        var observation = SocketObservation(
            sourceID: id, proto: full ? .tcp : .udp,
            local: Endpoint(address: IPAddress(full ? "10.0.0.36" : "2601:602:8182:9b00::24")!, port: 52_551),
            remote: Endpoint(address: IPAddress(full ? "52.21.130.202" : "2607:f8b0:400a:80a::200e")!, port: 443),
            pid: full ? 6526 : -1, processName: full ? "Cursor Helper (Plugin)" : "",
            rxBytes: full ? .max : 0, txBytes: 2408, rxPackets: 14, txPackets: 11)
        if full {
            observation.uniquePID = 2_158_009
            observation.tcpState = .timeWait
            observation.interface = "en0"
            observation.rttMS = 31.25
            observation.retransmittedBytes = 120
            observation.ageSeconds = 8040.5
            observation.serviceHint = "QUIC"
        }
        return observation
    }

    static let messages: [Wire.Message] = [
        .hello(protocolVersion: 1, client: "sbctl"),
        .welcome(protocolVersion: 1, version: "0.0.1", uid: 0, sources: ["nstat", "kernel"]),
        .welcome(protocolVersion: 65_535, version: "", uid: .max, sources: []),
        .refused(reason: "only administrators may connect"),
        .events(source: 0, []),
        .events(source: 1, [.seen(observation(1, full: true)), .removed(sourceID: .max), .seen(observation(2, full: false))]),
        .process(ProcessRecord(pid: 42, name: "minimal")),
        .process(ProcessRecord(
            pid: 6526, uniqueID: 2_158_009, name: "Cursor Helper", path: "/Applications/Cursor.app/Contents/MacOS/Cursor",
            parentPID: 1, uid: 501, username: "robert", startTime: 1_795_000_000.25, signing: .developerID, restricted: true)),
        .health(sources: ["nstat: 250 sockets tracked", "kernel: 267 sockets"], resyncs: 3),
        .reset,
        .capture([]),
        .capture([
            .resolved(name: "api.example.com", addresses: [IPAddress("93.184.216.34")!, IPAddress("2606:2800:220:1::1")!], pid: 6526),
            .resolved(name: "", addresses: [], pid: nil),
            .serverName(
                proto: .tcp, from: Endpoint(address: IPAddress("10.0.0.36")!, port: 52_551),
                to: Endpoint(address: IPAddress("93.184.216.34")!, port: 443), name: "api.example.com"),
            .service(
                proto: .udp, from: Endpoint(address: IPAddress("2601:602::24")!, port: 50_566),
                to: Endpoint(address: IPAddress("2607:f8b0::200e")!, port: 443), service: "QUIC"),
        ]),
    ]

    static func body(_ message: Wire.Message) -> [UInt8] { Array(Wire.frame(message).dropFirst(4)) }

    @Test func everyMessageSurvivesARoundTrip() throws {
        for message in Self.messages {
            let frame = Wire.frame(message)
            let length = Int(frame[0]) | Int(frame[1]) << 8 | Int(frame[2]) << 16 | Int(frame[3]) << 24
            #expect(length == frame.count - 4)
            #expect(try Wire.decode(frame.dropFirst(4)) == message)
        }
    }

    @Test func aTruncatedMessageFailsCleanlyAtEveryLength() {
        for message in Self.messages {
            let body = Self.body(message)
            for length in 0..<body.count {
                #expect(throws: Wire.WireError.self) { try Wire.decode(body.prefix(length)) }
            }
        }
    }

    @Test func trailingBytesAreRefused() {
        #expect(throws: Wire.WireError.self) { try Wire.decode(Self.body(Self.messages[0]) + [0]) }
    }

    @Test func aCountLargerThanTheMessageIsRefusedBeforeAllocating() {
        // An events frame claiming four billion events in a five-byte body.
        let lie: [UInt8] = [4, 0, 0xff, 0xff, 0xff, 0xff, 0x0f]
        #expect(throws: Wire.WireError.malformed("count exceeds message")) { try Wire.decode(lie) }
        // A string claiming more bytes than exist.
        #expect(throws: Wire.WireError.self) { try Wire.decode([3, 0xff, 0x3f]) }
    }

    @Test func corruptedAndRandomInputNeverCrashes() {
        var random = SplitMix64(seed: 0xC0DEC)
        var decoded = 0, refused = 0
        func attempt(_ bytes: [UInt8]) {
            do {
                _ = try Wire.decode(bytes)
                decoded += 1
            } catch {
                refused += 1
            }
        }
        // Valid messages with one or more bytes changed.
        for message in Self.messages {
            let original = Self.body(message)
            for _ in 0..<400 where !original.isEmpty {
                var bytes = original
                for _ in 0...random.below(3) { bytes[random.below(bytes.count)] = UInt8(truncatingIfNeeded: random.next()) }
                attempt(bytes)
            }
        }
        // Pure noise, with a plausible type byte so it gets past the first check.
        for _ in 0..<4000 {
            var bytes = (0..<random.below(200)).map { _ in UInt8(truncatingIfNeeded: random.next()) }
            if !bytes.isEmpty { bytes[0] = UInt8(1 + random.below(8)) }
            attempt(bytes)
        }
        #expect(refused > 2500)
        #expect(decoded + refused > 7000)
    }

    @Test func framesAreRecoveredFromAStreamInAnyChunking() throws {
        let stream = Self.messages.flatMap(Wire.frame)
        for chunk in [1, 2, 3, 7, 64, stream.count] {
            var buffer = Wire.FrameBuffer()
            var recovered: [Wire.Message] = []
            var offset = 0
            while offset < stream.count {
                buffer.append(stream[offset..<min(offset + chunk, stream.count)])
                offset += chunk
                while let body = try buffer.next() { recovered.append(try Wire.decode(body)) }
            }
            #expect(recovered == Self.messages)
        }
    }

    @Test func anOversizedFrameIsRefusedFromItsHeaderAlone() {
        var buffer = Wire.FrameBuffer()
        buffer.append([0xff, 0xff, 0xff, 0x7f])
        #expect(throws: Wire.WireError.self) { try buffer.next() }
        var empty = Wire.FrameBuffer()
        empty.append([0, 0, 0, 0])
        #expect(throws: Wire.WireError.malformed("empty frame")) { try empty.next() }
    }

    @Test func overLongTextIsCutNotRefused() throws {
        let long = String(repeating: "x", count: 20_000)
        guard case .refused(let reason) = try Wire.decode(Self.body(.refused(reason: long))) else {
            Issue.record("wrong message")
            return
        }
        #expect(reason.count == 8192)
    }
}

extension WireTests {
    @Test func aMessageTypeFromANewerBuildIsSteppedOver() throws {
        #expect(try Wire.decode([200, 1, 2, 3]) == .unknown(type: 200))
        // And the stream carries on with the next frame.
        var buffer = Wire.FrameBuffer()
        buffer.append([4, 0, 0, 0, 200, 1, 2, 3] + Wire.frame(.reset))
        #expect(try Wire.decode(try #require(try buffer.next())) == .unknown(type: 200))
        #expect(try Wire.decode(try #require(try buffer.next())) == .reset)
    }
}
