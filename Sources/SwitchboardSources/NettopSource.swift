import Foundation
import SwitchboardCore

/// Parses the CSV that `nettop -L 0 -x -n` prints: a header line, then for each process a
/// line naming it followed by one line per socket, repeated every interval.
///
/// ```
/// time,,interface,state,bytes_in,bytes_out,rx_dupe,rx_ooo,re-tx,rtt_avg,…
/// 20:16:42.95,Safari.501,,,81234,9120,0,0,0,,…
/// 20:16:42.95,tcp4 10.0.0.36:52551<->52.21.130.202:443,en0,Established,9110,2408,0,0,0,31.25 ms,…
/// 20:16:42.95,tcp6 ::1.8021<->*.*,lo0,Listen,,,,,,,…
/// ```
///
/// This is another program's display format and may change between macOS releases. The
/// parser skips anything it does not recognise rather than guess.
public struct NettopParser: Sendable {
    private var currentPID: Int32?
    private var currentName = ""
    private var seenThisBlock = Set<UInt64>()
    private var seenLastBlock = Set<UInt64>()
    private var started = false

    public init() {}

    /// Feeds one line. A header line closes the previous block, which is when sockets
    /// that have disappeared are reported.
    public mutating func consume(_ line: Substring) -> [SourceEvent] {
        let fields = line.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count >= 6 else { return [] }

        if fields[0] == "time" {
            defer {
                seenLastBlock = seenThisBlock
                seenThisBlock.removeAll(keepingCapacity: true)
                currentPID = nil
                started = true
            }
            guard started else { return [] }
            return seenLastBlock.subtracting(seenThisBlock).sorted().map { .removed(sourceID: $0) }
        }

        let descriptor = fields[1]
        guard let (proto, hint, rest) = Self.flowPrefix(descriptor) else {
            // A socket of a kind we do not model. It still belongs to the current process,
            // so it must not be mistaken for the start of another one.
            if descriptor.contains("<->") { return [] }
            // A process line: `name.pid`. The name itself may contain dots.
            if let dot = descriptor.lastIndex(of: "."), let pid = Int32(descriptor[descriptor.index(after: dot)...]) {
                currentPID = pid
                currentName = String(descriptor[..<dot])
            } else {
                currentPID = nil
            }
            return []
        }
        guard let pid = currentPID, let arrow = rest.range(of: "<->") else { return [] }
        let isV6 = descriptor.dropFirst(3).first == "6" || descriptor.dropFirst(4).first == "6"
        guard let local = Self.endpoint(rest[..<arrow.lowerBound], isV6: isV6),
              let remote = Self.endpoint(rest[arrow.upperBound...], isV6: isV6)
        else { return [] }

        let id = Self.identity(pid: pid, descriptor: descriptor)
        seenThisBlock.insert(id)

        var observation = SocketObservation(
            sourceID: id, proto: proto, local: local, remote: remote, pid: pid, processName: currentName,
            rxBytes: UInt64(fields[4]) ?? 0, txBytes: UInt64(fields[5]) ?? 0)
        observation.interface = fields[2].isEmpty ? nil : String(fields[2])
        observation.serviceHint = hint
        if proto == .tcp {
            observation.tcpState = NStatSource.tcpState(named: String(fields[3]))
            if fields.count > 8 { observation.retransmittedBytes = UInt64(fields[8]) }
        }
        if fields.count > 9, let value = fields[9].split(separator: " ").first.flatMap({ Double($0) }), value > 0 {
            observation.rttMS = value
        }
        return [.seen(observation)]
    }

    /// `tcp4 `, `udp6 `, `quic4 ` … Returns the transport, any service the label implies,
    /// and the remainder of the descriptor.
    private static func flowPrefix(_ descriptor: Substring) -> (TransportProtocol, String?, Substring)? {
        guard let space = descriptor.firstIndex(of: " ") else { return nil }
        let rest = descriptor[descriptor.index(after: space)...]
        switch descriptor[..<space] {
        case "tcp4", "tcp6": return (.tcp, nil, rest)
        case "udp4", "udp6": return (.udp, nil, rest)
        case "quic4", "quic6": return (.udp, "QUIC", rest)
        default: return nil
        }
    }

    /// IPv4 endpoints are `address:port`; IPv6 are `address.port`. `*` stands for "any".
    private static func endpoint(_ text: Substring, isV6: Bool) -> Endpoint? {
        guard let separator = text.lastIndex(of: isV6 ? "." : ":") else { return nil }
        var host = text[..<separator]
        let portText = text[text.index(after: separator)...]
        let port: UInt16
        if portText == "*" { port = 0 } else if let parsed = UInt16(portText) { port = parsed } else { return nil }
        if let scope = host.firstIndex(of: "%") { host = host[..<scope] }
        if host == "*" { return Endpoint(address: isV6 ? .v6(hi: 0, lo: 0) : .v4(0), port: port) }
        guard let address = IPAddress(String(host)) else { return nil }
        return Endpoint(address: address, port: port)
    }

    /// nettop gives sockets no identity of their own, so one is derived from the owner
    /// and the 5-tuple (FNV-1a).
    private static func identity(pid: Int32, descriptor: Substring) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in "\(pid)|".utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        for byte in descriptor.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return hash
    }
}

/// Flows from a `nettop` subprocess.
///
/// `nettop` is signed and entitled by Apple, so it sees every user's sockets even when we
/// are unprivileged. It refreshes once a second and reports no open and close events, so
/// it is the fallback when NetworkStatistics is unavailable and an optional supplement
/// beside it, not the first choice.
public final class NettopSource: FlowSource, @unchecked Sendable {
    public let name = "nettop"

    private let lock = NSLock()
    private var process: Process?
    private var pending: [SourceEvent] = []
    private var blocks = 0
    private var failure: String?

    public init() {}

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard process == nil else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = ["-L", "0", "-x", "-n", "-s", "1"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            failure = "could not start nettop: \(error.localizedDescription)"
            throw error
        }
        self.process = process

        let handle = pipe.fileHandleForReading
        Thread.detachNewThread { [weak self] in
            var parser = NettopParser()
            var carry = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                carry.append(chunk)
                while let newline = carry.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = String(decoding: carry[carry.startIndex..<newline], as: UTF8.self)
                    carry.removeSubrange(carry.startIndex...newline)
                    let events = parser.consume(line[...])
                    guard let self else { return }
                    self.lock.lock()
                    self.pending.append(contentsOf: events)
                    if line.hasPrefix("time,") { self.blocks += 1 }
                    self.lock.unlock()
                }
            }
        }
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        process?.terminate()
        process = nil
    }

    public func poll(now: EngineTime) -> [SourceEvent] {
        lock.lock()
        defer { lock.unlock() }
        let drained = pending
        pending.removeAll(keepingCapacity: true)
        return drained
    }

    public var health: SourceHealth {
        lock.lock()
        defer { lock.unlock() }
        if let failure { return SourceHealth(running: false, detail: failure) }
        let alive = process?.isRunning ?? false
        return SourceHealth(running: alive, detail: alive ? "\(blocks) samples read" : "nettop is not running")
    }
}
