import Foundation
import SwitchboardCore

/// A connection to the collector. Hands over what the collector's sources report, and
/// answers process lookups from what the collector, running as root, could see.
public final class CollectorClient: ProcessResolver, @unchecked Sendable {
    public enum ClientError: Error, CustomStringConvertible {
        case unavailable(String)
        case refused(String)

        public var description: String {
            switch self {
            case .unavailable(let detail): "collector unavailable: \(detail)"
            case .refused(let reason): "the collector refused the connection: \(reason)"
            }
        }
    }

    /// The collector's sources, in priority order.
    public let sources: [String]
    public let collectorVersion: String
    /// The account the collector runs as. Zero means it sees every user's sockets.
    public let collectorUID: UInt32

    private let fd: Int32
    private let lock = NSLock()
    private var inbox: [[SourceEvent]]
    private var seen: [Set<UInt64>]
    private var processes: [Int32: ProcessRecord] = [:]
    private var healthLines: [String] = []
    private var resyncCount: UInt32 = 0
    private var connected = true
    private let fallback = LibProcResolver()

    /// Connects and completes the handshake, or throws within `timeout` seconds.
    public init(path: String, clientName: String, timeout: Int = 2) throws {
        guard let fd = CollectorServer.connect(path) else {
            throw ClientError.unavailable("nothing is listening at \(path)")
        }
        var limit = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        guard CollectorServer.writeAll(fd, Wire.frame(.hello(protocolVersion: Wire.protocolVersion, client: clientName))) else {
            Darwin.close(fd)
            throw ClientError.unavailable("could not send hello")
        }

        var buffer = Wire.FrameBuffer()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        var first: Wire.Message?
        while first == nil {
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else {
                Darwin.close(fd)
                throw ClientError.unavailable("no answer from the collector")
            }
            buffer.append(chunk[..<count])
            do {
                if let body = try buffer.next() { first = try Wire.decode(body) }
            } catch {
                Darwin.close(fd)
                throw ClientError.unavailable("\(error)")
            }
        }
        switch first {
        case .welcome(_, let version, let uid, let sources):
            self.sources = sources
            collectorVersion = version
            collectorUID = uid
        case .refused(let reason):
            Darwin.close(fd)
            throw ClientError.refused(reason)
        default:
            Darwin.close(fd)
            throw ClientError.unavailable("unexpected reply")
        }
        limit = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))

        self.fd = fd
        inbox = Array(repeating: [], count: sources.count)
        seen = Array(repeating: [], count: sources.count)

        let pending = buffer
        let thread = Thread { [self] in readLoop(pending) }
        thread.name = "switchboard.collector-client"
        thread.start()
    }

    public var isConnected: Bool { lock.withLock { connected } }
    public var health: [String] { lock.withLock { healthLines } }
    public var resyncs: UInt32 { lock.withLock { resyncCount } }

    public func close() {
        lock.lock()
        let wasConnected = connected
        connected = false
        lock.unlock()
        if wasConnected { shutdown(fd, SHUT_RDWR) }
    }

    /// Everything received since the last call, grouped by the source that reported it.
    public func pollBatches() -> [(source: String, events: [SourceEvent])] {
        lock.lock()
        defer { lock.unlock() }
        var batches: [(String, [SourceEvent])] = []
        for index in inbox.indices where !inbox[index].isEmpty {
            batches.append((sources[index], inbox[index]))
            inbox[index].removeAll(keepingCapacity: true)
        }
        return batches
    }

    public func resolve(pid: Int32, name: String, uniqueID: UInt64?) -> ProcessRecord {
        if let record = lock.withLock({ processes[pid] }) { return record }
        return fallback.resolve(pid: pid, name: name, uniqueID: uniqueID)
    }

    private func readLoop(_ initial: Wire.FrameBuffer) {
        var buffer = initial
        var chunk = [UInt8](repeating: 0, count: 262_144)
        defer {
            lock.withLock { connected = false }
            Darwin.close(fd)
        }
        while true {
            do {
                while let body = try buffer.next() { handle(try Wire.decode(body)) }
            } catch {
                return
            }
            let count = read(fd, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return }
            buffer.append(chunk[..<count])
        }
    }

    private func handle(_ message: Wire.Message) {
        lock.lock()
        defer { lock.unlock() }
        switch message {
        case .events(let source, let events):
            let index = Int(source)
            guard inbox.indices.contains(index) else { return }
            for event in events {
                switch event {
                case .seen(let observation): seen[index].insert(observation.sourceID)
                case .removed(let id): seen[index].remove(id)
                }
            }
            inbox[index].append(contentsOf: events)
        case .process(let record):
            processes[record.pid] = record
        case .health(let lines, let resyncs):
            healthLines = lines
            resyncCount = resyncs
        case .reset:
            // The collector is starting us again from the present. Whatever we were
            // told about before may be gone, so say so; anything still there follows.
            for index in inbox.indices {
                inbox[index].append(contentsOf: seen[index].sorted().map { .removed(sourceID: $0) })
                seen[index].removeAll()
            }
        case .hello, .welcome, .refused:
            break
        }
    }
}

/// One of the collector's sources, seen through a client connection.
public final class CollectorSource: FlowSource, @unchecked Sendable {
    public let name: String
    private let client: CollectorClient
    private let lock = NSLock()
    private var pending: [SourceEvent] = []

    /// Sources for everything the collector publishes, in its priority order.
    public static func all(for client: CollectorClient) -> [CollectorSource] {
        let sources = client.sources.map { CollectorSource(name: $0, client: client) }
        sources.forEach { $0.siblings = sources }
        return sources
    }

    private var siblings: [CollectorSource] = []

    private init(name: String, client: CollectorClient) {
        self.name = name
        self.client = client
    }

    public func start() throws {}
    public func stop() { client.close() }

    public var health: SourceHealth {
        let line = client.health.first { $0.hasPrefix(name + ":") }?.dropFirst(name.count + 2)
        return SourceHealth(running: client.isConnected, detail: client.isConnected ? String(line ?? "connected") : "collector disconnected")
    }

    public func poll(now: EngineTime) -> [SourceEvent] {
        // One read of the connection serves every source that shares it.
        for (source, events) in client.pollBatches() {
            siblings.first { $0.name == source }?.deliver(events)
        }
        lock.lock()
        defer { lock.unlock() }
        let events = pending
        pending.removeAll(keepingCapacity: true)
        return events
    }

    private func deliver(_ events: [SourceEvent]) {
        lock.lock()
        pending.append(contentsOf: events)
        lock.unlock()
    }
}
