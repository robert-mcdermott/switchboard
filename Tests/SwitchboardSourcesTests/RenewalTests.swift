import Darwin
import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardSources

private func observation(_ local: UInt16, _ remote: UInt16, pid: Int32 = 10, state: TCPState = .established) -> SocketObservation {
    var observation = SocketObservation(
        sourceID: UInt64(local), proto: .tcp, local: Endpoint(address: IPAddress("10.0.0.2")!, port: local),
        remote: Endpoint(address: IPAddress("93.184.216.34")!, port: remote), pid: pid, processName: "app")
    observation.tcpState = state
    return observation
}

@Suite struct CoverageTests {
    @Test func aFewUnreportedConnectionsAreNormal() {
        let listed = (1...40).map { observation(UInt16(40_000 + $0), 443) }
        // Two of forty never reported, at two checks running: 5%, under the threshold.
        let reported = Array(listed.dropFirst(2))
        let first = SocketCoverage(listed: listed, reported: reported, unreportedBefore: [])
        let second = SocketCoverage(listed: listed, reported: reported, unreportedBefore: first.unreported)
        #expect(second.persistentlyUnreported == 2)
        #expect(!second.isStale)
        #expect(second.summary == "38 of 40 established connections the kernel lists are reported")
    }

    @Test func halfUnreportedAtTwoChecksIsStale() {
        let listed = (1...40).map { observation(UInt16(40_000 + $0), 443) }
        let reported = Array(listed.prefix(20))
        let first = SocketCoverage(listed: listed, reported: reported, unreportedBefore: [])
        // Once is not enough: they may simply be new.
        #expect(!first.isStale)
        let second = SocketCoverage(listed: listed, reported: reported, unreportedBefore: first.unreported)
        #expect(second.isStale)
    }

    @Test func onlyEstablishedConnectionsCount() {
        let listed = (1...10).map { observation(UInt16(40_000 + $0), 443, state: .synSent) }
        let first = SocketCoverage(listed: listed, reported: [], unreportedBefore: [])
        let second = SocketCoverage(listed: listed, reported: [], unreportedBefore: first.unreported)
        #expect(second.listedCount == 0 && !second.isStale)
    }
}

@Suite struct StableIDTests {
    @Test func theSameSocketGetsTheSameIDAndOthersDoNot() {
        let a = NStatSource.stableID(proto: .tcp, pid: 100, localPort: 50_000, startTicks: 123_456_789)
        #expect(a == NStatSource.stableID(proto: .tcp, pid: 100, localPort: 50_000, startTicks: 123_456_789))
        #expect(a != NStatSource.stableID(proto: .udp, pid: 100, localPort: 50_000, startTicks: 123_456_789))
        #expect(a != NStatSource.stableID(proto: .tcp, pid: 101, localPort: 50_000, startTicks: 123_456_789))
        #expect(a != NStatSource.stableID(proto: .tcp, pid: 100, localPort: 50_001, startTicks: 123_456_789))
        #expect(a != NStatSource.stableID(proto: .tcp, pid: 100, localPort: 50_000, startTicks: 123_456_790))
    }
}

/// A loopback TCP connection held open by this process.
private final class LoopbackPair {
    let listener: Int32, client: Int32, server: Int32
    let clientPort: UInt16

    init?() {
        func address(port: UInt16) -> sockaddr_in {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            return address
        }
        func withAddress(port: UInt16, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32 {
            var target = address(port: port)
            return withUnsafePointer(to: &target) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        func port(of fd: Int32) -> UInt16 {
            var bound = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
            return UInt16(bigEndian: bound.sin_port)
        }
        let listening = socket(AF_INET, SOCK_STREAM, 0)
        guard listening >= 0, withAddress(port: 0, { bind(listening, $0, $1) }) == 0, Darwin.listen(listening, 1) == 0 else { return nil }
        let connecting = socket(AF_INET, SOCK_STREAM, 0)
        guard connecting >= 0, withAddress(port: port(of: listening), { connect(connecting, $0, $1) }) == 0 else { return nil }
        let accepted = accept(listening, nil, nil)
        guard accepted >= 0 else { return nil }
        listener = listening
        client = connecting
        server = accepted
        clientPort = port(of: connecting)
        // Some bytes, so there are counters to carry over.
        let message = [UInt8](repeating: 7, count: 1000)
        _ = message.withUnsafeBytes { write(connecting, $0.baseAddress, 1000) }
    }

    private var open = true

    /// Closes both ends, server first, as a finished exchange does, and the listener.
    func closeAll() {
        guard open else { return }
        open = false
        close(server)
        close(client)
        close(listener)
    }
}

/// Against the real framework, as the login user: a renewal keeps every socket's ID and
/// reports nothing removed that is still open, and a close still arrives afterwards.
@Suite(.serialized) struct RenewalTests {
    @Test func renewingKeepsSocketsAndTheirIDs() throws {
        let source = NStatSource(counterInterval: 0.25)
        do { try source.start() } catch {
            // NetworkStatistics is optional at run time; without it there is nothing to test.
            return
        }
        defer { source.stop() }
        let pair = try #require(LoopbackPair())
        defer { pair.closeAll() }

        func clientID(in events: [SourceEvent]) -> UInt64? {
            for case .seen(let observation) in events where observation.local.port == pair.clientPort && observation.pid == getpid() {
                return observation.sourceID
            }
            return nil
        }

        var time: Double = 0
        var id: UInt64?
        for _ in 0..<40 where id == nil {
            time += 0.25
            id = clientID(in: source.poll(now: time))
            Thread.sleep(forTimeInterval: 0.25)
        }
        let first = try #require(id, "NetworkStatistics never reported the test's own connection")

        source.renew()
        var removed: [UInt64] = []
        var seenAfter: UInt64?
        for _ in 0..<24 {
            time += 0.25
            let events = source.poll(now: time)
            for case .removed(let gone) in events { removed.append(gone) }
            if time > 2, let again = clientID(in: events) { seenAfter = again }
            Thread.sleep(forTimeInterval: 0.25)
        }
        #expect(source.renewals == 1)
        #expect(!removed.contains(first), "renewal reported an open connection closed")
        #expect(seenAfter == first, "the connection came back under a different ID")

        // A real close still comes through, once.
        pair.closeAll()
        var closed = 0
        for _ in 0..<20 {
            time += 0.25
            for case .removed(let gone) in source.poll(now: time) where gone == first { closed += 1 }
            Thread.sleep(forTimeInterval: 0.25)
        }
        #expect(closed == 1)
    }
}
