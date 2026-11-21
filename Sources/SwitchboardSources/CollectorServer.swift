import Foundation
import SwitchboardCore

/// Something that can describe its own state for the collector's health report.
public protocol FlowSourceHealth {
    var healthName: String { get }
    var healthDetail: String { get }
}

/// The collector's publishing side: runs sources, and streams what they report to every
/// connected client over a Unix domain socket.
///
/// It accepts no commands. A client says hello and then only listens. A client that
/// cannot keep up has its backlog dropped and is sent the complete current state again,
/// so a slow reader costs itself freshness and never holds up collection.
public final class CollectorServer: @unchecked Sendable {
    public enum ServerError: Error, CustomStringConvertible {
        case socket(String)
        case alreadyRunning(String)

        public var description: String {
            switch self {
            case .socket(let detail): "socket error: \(detail)"
            case .alreadyRunning(let path): "another collector is already serving \(path)"
            }
        }
    }

    /// A client more than this far behind is resynchronised.
    static let backlogLimit = 8 * 1024 * 1024

    private final class Client: @unchecked Sendable {
        let fd: Int32
        let uid: uid_t
        let condition = NSCondition()
        var queue: [[UInt8]] = []
        var queuedBytes = 0
        var resyncs: UInt32 = 0
        var closed = false

        init(fd: Int32, uid: uid_t) {
            self.fd = fd
            self.uid = uid
        }

        func enqueue(_ frames: [[UInt8]]) {
            condition.lock()
            queue.append(contentsOf: frames)
            queuedBytes += frames.reduce(0) { $0 + $1.count }
            condition.signal()
            condition.unlock()
        }

        func close() {
            condition.lock()
            if !closed {
                closed = true
                Darwin.close(fd)
            }
            condition.broadcast()
            condition.unlock()
        }
    }

    private let path: String
    private let sources: [any FlowSource]
    private let resolver: any ProcessResolver
    private let captures: [any CaptureProvider]
    private let lock = NSLock()
    private var clients: [Client] = []
    private var current: [[UInt64: SocketObservation]]
    private var processes: [Int32: ProcessRecord] = [:]
    /// The latest names learned, so a client that connects later still gets them.
    private var recentNames: [CaptureObservation] = []
    private static let recentNameLimit = 4000
    private var listener: Int32 = -1
    private var running = false

    public init(
        path: String, sources: [any FlowSource], resolver: any ProcessResolver, captures: [any CaptureProvider] = []
    ) {
        self.path = path
        self.sources = sources
        self.resolver = resolver
        self.captures = captures
        current = Array(repeating: [:], count: sources.count)
    }

    public var clientCount: Int { lock.withLock { clients.count } }

    // MARK: - Running

    /// Binds the socket and starts accepting clients. Call `tick` regularly afterwards.
    public func start() throws {
        signal(SIGPIPE, SIG_IGN)
        listener = try Self.bind(path)
        // Root serves administrators; anyone else serves only themselves.
        if geteuid() == 0 {
            let admin = getgrnam("admin")?.pointee.gr_gid ?? 80
            chown(path, 0, admin)
            chmod(path, 0o660)
        } else {
            chmod(path, 0o600)
        }
        for source in sources {
            do { try source.start() } catch { FileHandle.standardError.write(Data("\(source.name): \(error)\n".utf8)) }
        }
        lock.withLock { running = true }
        let thread = Thread { [self] in acceptLoop() }
        thread.name = "switchboard.accept"
        thread.start()
    }

    public func stop() {
        lock.lock()
        running = false
        let all = clients
        clients.removeAll()
        lock.unlock()
        all.forEach { $0.close() }
        if listener >= 0 { close(listener) }
        unlink(path)
        sources.forEach { $0.stop() }
    }

    /// Polls every source once and publishes what changed.
    public func tick(now: EngineTime, includeHealth: Bool) {
        var frames: [[UInt8]] = []
        for (index, source) in sources.enumerated() {
            let events = source.poll(now: now)
            guard !events.isEmpty else { continue }
            lock.lock()
            for event in events {
                switch event {
                case .seen(let observation):
                    current[index][observation.sourceID] = observation
                    if let known = processes[observation.pid],
                       observation.uniquePID == nil || known.uniqueID == nil || known.uniqueID == observation.uniquePID
                    {
                        continue
                    }
                    let record = resolver.resolve(
                        pid: observation.pid, name: observation.processName, uniqueID: observation.uniquePID)
                    processes[observation.pid] = record
                    frames.append(Wire.frame(.process(record)))
                case .removed(let id):
                    current[index][id] = nil
                }
            }
            lock.unlock()
            for chunk in Self.chunks(events) { frames.append(Wire.frame(.events(source: UInt8(index), chunk))) }
        }
        for capture in captures {
            let observations = capture.pollCapture(now: now)
            guard !observations.isEmpty else { continue }
            lock.lock()
            recentNames.append(contentsOf: observations)
            if recentNames.count > Self.recentNameLimit { recentNames.removeFirst(recentNames.count - Self.recentNameLimit) }
            lock.unlock()
            for start in stride(from: 0, to: observations.count, by: 500) {
                frames.append(Wire.frame(.capture(Array(observations[start..<min(start + 500, observations.count)]))))
            }
        }
        broadcast(frames, includeHealth: includeHealth)
    }

    private func broadcast(_ frames: [[UInt8]], includeHealth: Bool) {
        lock.lock()
        let live = clients.filter { !$0.closed }
        clients = live
        var health = sources.map { "\($0.name): \($0.health.detail)" }
        for capture in captures {
            if let reporting = capture as? any FlowSourceHealth { health.append("\(reporting.healthName): \(reporting.healthDetail)") }
        }
        var state: [[UInt8]]?
        for client in live {
            client.condition.lock()
            let behind = client.queuedBytes > Self.backlogLimit
            client.condition.unlock()
            if behind {
                // Too far behind to catch up frame by frame: start it again from the present.
                let fresh = state ?? stateFrames()
                state = fresh
                client.condition.lock()
                client.queue = []
                client.queuedBytes = 0
                client.resyncs += 1
                client.condition.unlock()
                client.enqueue(fresh)
            } else if !frames.isEmpty {
                client.enqueue(frames)
            }
            if includeHealth { client.enqueue([Wire.frame(.health(sources: health, resyncs: client.resyncs))]) }
        }
        lock.unlock()
    }

    /// Everything a client needs to start from nothing. Call with `lock` held.
    private func stateFrames() -> [[UInt8]] {
        var frames = [Wire.frame(.reset)]
        var needed = Set<Int32>()
        for table in current { for observation in table.values { needed.insert(observation.pid) } }
        // Forget processes nothing refers to any more, so the table cannot grow for ever.
        processes = processes.filter { needed.contains($0.key) }
        for pid in processes.keys.sorted() { frames.append(Wire.frame(.process(processes[pid]!))) }
        for (index, table) in current.enumerated() {
            let events = table.keys.sorted().map { SourceEvent.seen(table[$0]!) }
            for chunk in Self.chunks(events) { frames.append(Wire.frame(.events(source: UInt8(index), chunk))) }
        }
        for start in stride(from: 0, to: recentNames.count, by: 500) {
            frames.append(Wire.frame(.capture(Array(recentNames[start..<min(start + 500, recentNames.count)]))))
        }
        return frames
    }

    private static func chunks(_ events: [SourceEvent]) -> [[SourceEvent]] {
        stride(from: 0, to: events.count, by: 2000).map { Array(events[$0..<min($0 + 2000, events.count)]) }
    }

    // MARK: - Clients

    private func acceptLoop() {
        while lock.withLock({ running }) {
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else {
                if errno == EINTR { continue }
                break
            }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let thread = Thread { [self] in serve(fd) }
            thread.name = "switchboard.client"
            thread.start()
        }
    }

    private func serve(_ fd: Int32) {
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else {
            close(fd)
            return
        }
        func refuse(_ reason: String) {
            _ = Self.writeAll(fd, Wire.frame(.refused(reason: reason)))
            close(fd)
        }
        // Everyone's network activity is sensitive. Root's collector serves root and
        // administrators; a collector someone runs for themselves serves only them.
        guard Self.mayConnect(uid) else {
            return refuse("only administrators may connect to the collector")
        }

        // The one thing a client sends. It gets three seconds to send it.
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var buffer = Wire.FrameBuffer()
        var hello: Wire.Message?
        var chunk = [UInt8](repeating: 0, count: 1024)
        var received = 0
        while hello == nil {
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else {
                close(fd)
                return
            }
            received += count
            // A hello is a few dozen bytes. Anything much larger is not one.
            guard received <= 4096 else { return refuse("unexpected data") }
            buffer.append(chunk[..<count])
            do {
                if let body = try buffer.next() { hello = try Wire.decode(body) }
            } catch {
                return refuse("malformed hello")
            }
        }
        guard case .hello(let version, _) = hello else { return refuse("expected hello") }
        guard version == Wire.protocolVersion else {
            return refuse("protocol \(version) is not supported; this collector speaks \(Wire.protocolVersion)")
        }
        timeout = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let client = Client(fd: fd, uid: uid)
        lock.lock()
        client.enqueue([Wire.frame(.welcome(
            protocolVersion: Wire.protocolVersion, version: Switchboard.version, uid: geteuid(),
            sources: sources.map(\.name)))])
        client.enqueue(stateFrames())
        clients.append(client)
        lock.unlock()

        // Nothing more is expected from the client; reading only tells us when it leaves.
        let watcher = Thread {
            var sink = [UInt8](repeating: 0, count: 256)
            while read(fd, &sink, sink.count) > 0 {}
            client.close()
        }
        watcher.start()

        while true {
            client.condition.lock()
            while client.queue.isEmpty, !client.closed { client.condition.wait() }
            if client.closed {
                client.condition.unlock()
                break
            }
            let batch = client.queue
            client.queue = []
            client.condition.unlock()
            var failed = false
            for frame in batch {
                if !Self.writeAll(fd, frame) {
                    failed = true
                    break
                }
                client.condition.lock()
                client.queuedBytes -= frame.count
                client.condition.unlock()
            }
            if failed { break }
        }
        client.close()
    }

    static func mayConnect(_ uid: uid_t) -> Bool {
        if uid == 0 || uid == geteuid() { return true }
        guard geteuid() == 0, let entry = getpwuid(uid) else { return false }
        let admin = Int32(getgrnam("admin")?.pointee.gr_gid ?? 80)
        var groups = [Int32](repeating: 0, count: 64)
        var count = Int32(groups.count)
        _ = getgrouplist(entry.pointee.pw_name, Int32(entry.pointee.pw_gid), &groups, &count)
        return groups.prefix(Int(max(count, 0))).contains(admin)
    }

    static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + offset, bytes.count - offset) }
            if written < 0 {
                if errno == EINTR { continue }
                return false
            }
            offset += written
        }
        return true
    }

    // MARK: - Socket setup

    static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    static func connect(_ path: String) -> Int32? {
        guard var address = address(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            return nil
        }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    private static func bind(_ path: String) throws -> Int32 {
        guard var address = address(path) else { throw ServerError.socket("path too long: \(path)") }
        // A socket file left by a collector that has died is cleared; a live one is not.
        if let existing = connect(path) {
            close(existing)
            throw ServerError.alreadyRunning(path)
        }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.socket(String(cString: strerror(errno))) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            let reason = String(cString: strerror(errno))
            close(fd)
            throw ServerError.socket("cannot serve \(path): \(reason)")
        }
        return fd
    }
}
