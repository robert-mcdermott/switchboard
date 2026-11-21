import Foundation
import SwitchboardCore

/// One connection as the log remembers it. Times are seconds since 1970.
public struct LogEntry: Sendable, Identifiable {
    public var flow: Flow
    public var process: ProcessRecord
    public var id: FlowID { flow.id }
}

public struct LogQueryResult: Sendable {
    /// The newest matches, up to the limit asked for.
    public var entries: [LogEntry] = []
    /// How many connections matched in all.
    public var matched = 0
    /// How many rows SQLite handed back for the in-memory pass.
    public var scanned = 0
    /// Matches by when they started, across the range, oldest first.
    public var histogram: [Int] = []
    public var from = 0.0
    public var to = 0.0
    public var milliseconds = 0.0

    public init() {}
}

public struct LogStats: Sendable {
    public var flows = 0
    public var endpoints = 0
    public var oldest: Double?
    public var newest: Double?
    public var bytesOnDisk = 0

    public init() {}
}

/// How much the log records (docs/SPEC.md §8).
public enum LogDetail: String, Sendable, CaseIterable {
    /// Connections only.
    case summary
    /// Connections, DNS answers, and listening sockets opening and closing.
    case standard
    /// All of that, plus a byte count per active connection each second.
    case detailed
}

public enum ExportFormat: String, Sendable, CaseIterable {
    case csv, jsonl
}

/// The local log of everything Switchboard has seen: a SQLite database, written by the
/// unprivileged app, queried with the same filter language as the live view.
///
/// All work happens on one private queue. Recording is asynchronous and never holds up
/// the caller; queries wait for their answer.
public final class LogStore: @unchecked Sendable {
    public static let directoryName = "Switchboard"

    /// `~/Library/Application Support/Switchboard/log.sqlite`
    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(directoryName).appendingPathComponent("log.sqlite")
    }

    private struct Tuple: Hashable {
        var pid: Int32
        var key: FlowKey
    }

    private struct OpenRow {
        var row: Int64
        var lastWritten: Double
        var lastSeen: Double
        var bytesIn: UInt64
        var bytesOut: UInt64
    }

    private struct ListenerKey: Hashable {
        var pid: Int32
        var proto: TransportProtocol
        var local: Endpoint
    }

    private let database: Database
    private let queue = DispatchQueue(label: "switchboard.log", qos: .utility)
    public let url: URL

    // Touched only on `queue`.
    private var open: [Tuple: OpenRow] = [:]
    /// Connections that opened and closed between two recordings, so they are written once.
    private var writtenClosed: [Tuple: Double] = [:]
    private var listening: [ListenerKey: String] = [:]
    private var listeningPrimed = false
    private var lastDNS = 0.0
    private var lastDNSRecord: UInt64 = 0
    private var endpointsAtStart = 0
    private var detailLevel = LogDetail.standard

    /// Called, off the main thread, with destinations never seen in any earlier session.
    public var onFirstSeen: (@Sendable ([IPAddress]) -> Void)?

    /// Open rows are refreshed this often, so a crash loses at most this much of their totals.
    static let refreshSeconds = 10.0
    /// The log must already know this many destinations before a new one is remarkable.
    /// Set before recording starts.
    public var firstSeenBaseline = 200

    public init(url: URL, detail: LogDetail = .standard) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        database = try Database(path: url.path)
        detailLevel = detail
        try migrate()
        // Connections still marked open belong to a session that ended without closing
        // them. They ended, at the latest, when they were last seen.
        try database.run("UPDATE flow SET closed_at = last_seen WHERE closed_at IS NULL")
        endpointsAtStart = Int(try database.scalar("SELECT COUNT(*) FROM endpoint_first_seen"))
        // Lets SQLite refresh what it knows about the indexes, cheaply, when that is worth doing.
        try? database.execute("PRAGMA optimize")
    }

    public var detail: LogDetail {
        get { queue.sync { detailLevel } }
        set { queue.async { self.detailLevel = newValue } }
    }

    /// Leaves out connections from this Mac to itself. Development tools and container
    /// runtimes can open hundreds a minute, which on some machines are most of the log.
    public var excludesLoopback: Bool {
        get { queue.sync { skipLoopback } }
        set { queue.async { self.skipLoopback = newValue } }
    }
    private var skipLoopback = false

    private func migrate() throws {
        let version = try database.scalar("PRAGMA user_version")
        if version < 1 { try createSchema() }
        if version < 2 {
            // Where each destination is, whose network it is on, which of the user's lists
            // it is on, and how the process was signed.
            for column in ["country TEXT", "city TEXT", "asn INTEGER", "org TEXT", "tags TEXT", "signing TEXT", "team TEXT"] {
                try database.execute("ALTER TABLE flow ADD COLUMN \(column)")
            }
            try database.execute("CREATE INDEX flow_country ON flow(country); PRAGMA user_version = 2;")
        }
    }

    private func createSchema() throws {
        // Must be set before the first table exists for space to be handed back later.
        try database.execute("PRAGMA auto_vacuum = INCREMENTAL")
        try database.execute("PRAGMA journal_mode = WAL")
        try database.execute("""
            CREATE TABLE flow (
              id INTEGER PRIMARY KEY, pid INTEGER, process TEXT, user TEXT, path TEXT,
              proto TEXT, l_ip TEXT, l_port INTEGER, r_ip TEXT, r_port INTEGER,
              direction TEXT, iface TEXT, service TEXT, service_basis TEXT,
              hostname TEXT, hostname_src TEXT, attribution TEXT,
              first_seen REAL, last_seen REAL, closed_at REAL, age_exact INTEGER,
              bytes_in INTEGER, bytes_out INTEGER, pkts_in INTEGER, pkts_out INTEGER,
              ascii INTEGER NOT NULL DEFAULT 1
            );
            CREATE INDEX flow_nonascii ON flow(ascii) WHERE ascii = 0;
            CREATE INDEX flow_first ON flow(first_seen);
            CREATE INDEX flow_last ON flow(last_seen);
            CREATE INDEX flow_remote ON flow(r_ip);
            CREATE INDEX flow_process ON flow(process);
            CREATE TABLE flow_sample (flow_id INTEGER, ts REAL, bytes_in INTEGER, bytes_out INTEGER);
            CREATE INDEX flow_sample_flow ON flow_sample(flow_id);
            CREATE TABLE dns_obs (ts REAL, name TEXT, ips TEXT, pid INTEGER);
            CREATE INDEX dns_time ON dns_obs(ts);
            CREATE TABLE listener_event (ts REAL, pid INTEGER, process TEXT, proto TEXT, l_ip TEXT, l_port INTEGER, event TEXT);
            CREATE INDEX listener_time ON listener_event(ts);
            CREATE TABLE endpoint_first_seen (ip TEXT PRIMARY KEY, ts REAL);
            PRAGMA user_version = 1;
            """)
    }

    // MARK: - Recording

    /// Queues the engine's current model to be written. Returns at once.
    public func record(_ snapshot: EngineSnapshot) {
        queue.async { [self] in
            do {
                try database.execute("BEGIN")
                let fresh = try write(snapshot)
                try database.execute("COMMIT")
                // On a new log everything is new; only remark on a destination once the
                // log knows the machine's habits.
                if !fresh.isEmpty, endpointsAtStart >= firstSeenBaseline { onFirstSeen?(fresh) }
            } catch {
                try? database.execute("ROLLBACK")
            }
        }
    }

    /// Waits for everything queued so far to be written.
    public func flush() {
        queue.sync {}
    }

    private static let insertFlow = """
        INSERT INTO flow (pid, process, user, path, proto, l_ip, l_port, r_ip, r_port, direction, iface, service,
          service_basis, hostname, hostname_src, attribution, first_seen, last_seen, closed_at, age_exact,
          bytes_in, bytes_out, pkts_in, pkts_out, ascii, country, city, asn, org, tags, signing, team)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """

    private static let updateFlow = """
        UPDATE flow SET last_seen = ?, closed_at = ?, bytes_in = ?, bytes_out = ?, pkts_in = ?, pkts_out = ?,
          service = ?, service_basis = ?, hostname = ?, hostname_src = ?, iface = ?,
          ascii = MIN(ascii, ?), country = ?, city = ?, asn = ?, org = ?, tags = ?, signing = ?, team = ? WHERE id = ?
        """

    private func write(_ snapshot: EngineSnapshot) throws -> [IPAddress] {
        let now = snapshot.wallClock
        func wall(_ time: EngineTime) -> Double { now - (snapshot.time - time) }
        let processes = Dictionary(uniqueKeysWithValues: snapshot.processes.map { ($0.pid, $0) })
        var fresh: [IPAddress] = []

        func insert(_ flow: Flow, closedAt: Double?) throws -> Int64 {
            let process = processes[flow.pid]
            var values: [Database.Value] = [
                .integer(Int64(flow.pid)), .init(process?.name), .init(process?.username), .init(process?.path),
                .text(flow.key.proto.rawValue), .text(flow.key.local.address.description), .integer(Int64(flow.key.local.port)),
                .text(flow.key.remote.address.description), .integer(Int64(flow.key.remote.port)),
                .text(flow.direction.rawValue), .init(flow.interface), .init(flow.service), .init(flow.serviceBasis?.rawValue),
                .init(flow.hostname), .init(flow.hostnameSource?.rawValue), .text(flow.attribution),
                .real(wall(flow.firstSeen)), .real(closedAt ?? now), closedAt.map { .real($0) } ?? .null,
                .integer(flow.ageExact ? 1 : 0),
                .integer(Int64(clamping: flow.bytesIn)), .integer(Int64(clamping: flow.bytesOut)),
                .integer(Int64(clamping: flow.packetsIn)), .integer(Int64(clamping: flow.packetsOut)),
                .integer(Self.isASCII(process?.name, process?.username, process?.path, flow.service, flow.hostname, flow.interface, flow.org, flow.country) ? 1 : 0),
            ]
            values += Self.enrichment(flow, process)
            try database.run(Self.insertFlow, values)
            let row = database.lastInsertedRow
            let address = flow.key.remote.address
            if !address.isLoopback,
               try database.run("INSERT OR IGNORE INTO endpoint_first_seen (ip, ts) VALUES (?, ?)", [.text(address.description), .real(wall(flow.firstSeen))]) == 1
            {
                fresh.append(address)
            }
            return row
        }

        func update(_ flow: Flow, row: Int64, closedAt: Double?) throws {
            var values: [Database.Value] = [
                .real(closedAt ?? now), closedAt.map { .real($0) } ?? .null,
                .integer(Int64(clamping: flow.bytesIn)), .integer(Int64(clamping: flow.bytesOut)),
                .integer(Int64(clamping: flow.packetsIn)), .integer(Int64(clamping: flow.packetsOut)),
                .init(flow.service), .init(flow.serviceBasis?.rawValue), .init(flow.hostname),
                .init(flow.hostnameSource?.rawValue), .init(flow.interface),
                .integer(Self.isASCII(flow.service, flow.hostname, flow.interface, flow.org, flow.country) ? 1 : 0),
            ]
            values += Self.enrichment(flow, processes[flow.pid])
            values.append(.integer(row))
            try database.run(Self.updateFlow, values)
        }

        for flow in snapshot.flows {
            if skipLoopback, flow.key.remote.address.isLoopback { continue }
            let tuple = Tuple(pid: flow.pid, key: flow.key)
            if flow.state == .closed {
                let closedAt = wall(flow.closedAt ?? snapshot.time)
                if let known = open.removeValue(forKey: tuple) {
                    try update(flow, row: known.row, closedAt: closedAt)
                    writtenClosed[tuple] = closedAt
                } else if writtenClosed[tuple] != closedAt {
                    // It opened and closed between two recordings.
                    _ = try insert(flow, closedAt: closedAt)
                    writtenClosed[tuple] = closedAt
                }
                continue
            }
            if var known = open[tuple] {
                if detailLevel == .detailed, flow.bytesIn != known.bytesIn || flow.bytesOut != known.bytesOut {
                    try database.run(
                        "INSERT INTO flow_sample (flow_id, ts, bytes_in, bytes_out) VALUES (?, ?, ?, ?)",
                        [.integer(known.row), .real(now), .integer(Int64(clamping: flow.bytesIn)), .integer(Int64(clamping: flow.bytesOut))])
                }
                known.lastSeen = now
                known.bytesIn = flow.bytesIn
                known.bytesOut = flow.bytesOut
                if now - known.lastWritten >= Self.refreshSeconds {
                    try update(flow, row: known.row, closedAt: nil)
                    known.lastWritten = now
                }
                open[tuple] = known
            } else {
                let row = try insert(flow, closedAt: nil)
                open[tuple] = OpenRow(row: row, lastWritten: now, lastSeen: now, bytesIn: flow.bytesIn, bytesOut: flow.bytesOut)
            }
        }

        // Anything open in the log but gone from the model without being seen to close:
        // the engine was restarted under it. Give it a few seconds to reappear.
        for (tuple, known) in open where now - known.lastSeen > 15 {
            try database.run("UPDATE flow SET closed_at = last_seen WHERE id = ?", [.integer(known.row)])
            open[tuple] = nil
        }
        writtenClosed = writtenClosed.filter { now - $0.value < 120 }

        if detailLevel != .summary {
            for record in snapshot.dns {
                let at = wall(record.time)
                // Several answers can share an instant; the record's own number tells them apart.
                guard at > lastDNS || (at == lastDNS && record.id > lastDNSRecord) else { continue }
                try database.run(
                    "INSERT INTO dns_obs (ts, name, ips, pid) VALUES (?, ?, ?, ?)",
                    [.real(at), .text(record.name), .text(record.addresses.map(\.description).joined(separator: " ")),
                     record.pid.map { .integer(Int64($0)) } ?? .null])
                lastDNS = at
                lastDNSRecord = record.id
            }

            var present: [ListenerKey: String] = [:]
            for listener in snapshot.listeners {
                present[ListenerKey(pid: listener.pid, proto: listener.proto, local: listener.local)] = processes[listener.pid]?.name ?? ""
            }
            func event(_ key: ListenerKey, _ name: String, _ what: String) throws {
                try database.run(
                    "INSERT INTO listener_event (ts, pid, process, proto, l_ip, l_port, event) VALUES (?, ?, ?, ?, ?, ?, ?)",
                    [.real(now), .integer(Int64(key.pid)), .text(name), .text(key.proto.rawValue),
                     .text(key.local.address.description), .integer(Int64(key.local.port)), .text(what)])
            }
            // The first sight of the machine's listeners is not a set of events.
            if listeningPrimed {
                for (key, name) in present where listening[key] == nil { try event(key, name, "open") }
                for (key, name) in listening where present[key] == nil { try event(key, name, "close") }
            }
            listening = present
            listeningPrimed = true
        }
        return fresh
    }

    /// Rows whose text is all ASCII can be compared in SQL exactly as the filter compares
    /// them. Anything else is flagged, and a query that meets such a row checks every row itself.
    private static func isASCII(_ texts: String?...) -> Bool {
        texts.allSatisfy { $0?.utf8.allSatisfy { $0 < 0x80 } ?? true }
    }

    private static func enrichment(_ flow: Flow, _ process: ProcessRecord?) -> [Database.Value] {
        [
            .init(flow.country), .init(flow.city), flow.asn.map { .integer(Int64($0)) } ?? .null, .init(flow.org),
            flow.tags.isEmpty ? .null : .text(flow.tags.joined(separator: "\n")),
            .init(process?.signing.rawValue), .init(process?.teamID),
        ]
    }

    // MARK: - Reading

    private static let columns = """
        id, pid, process, user, path, proto, l_ip, l_port, r_ip, r_port, direction, iface, service, service_basis,
        hostname, hostname_src, attribution, first_seen, last_seen, closed_at, age_exact, bytes_in, bytes_out, pkts_in, pkts_out,
        country, city, asn, org, tags, signing, team
        """

    private static func entry(_ row: Database.Row) -> LogEntry? {
        guard let proto = row.text(5).flatMap(TransportProtocol.init(rawValue:)),
              let local = row.text(6).flatMap({ IPAddress($0) }), let remote = row.text(8).flatMap({ IPAddress($0) })
        else { return nil }
        let pid = Int32(truncatingIfNeeded: row.integer(1))
        let firstSeen = row.real(17), lastSeen = row.real(18)
        let closedAt: Double? = row.isNull(19) ? nil : row.real(19)
        let bytesIn = UInt64(clamping: row.integer(21)), bytesOut = UInt64(clamping: row.integer(22))
        // A logged connection has no moment-to-moment rate; its average over its life stands in.
        let duration = max((closedAt ?? lastSeen) - firstSeen, 1)
        let flow = Flow(
            id: FlowID(row.integer(0)),
            key: FlowKey(
                proto: proto, local: Endpoint(address: local, port: UInt16(truncatingIfNeeded: row.integer(7))),
                remote: Endpoint(address: remote, port: UInt16(truncatingIfNeeded: row.integer(9)))),
            pid: pid, direction: row.text(10).flatMap(FlowDirection.init(rawValue:)) ?? .unknown, interface: row.text(11),
            state: closedAt == nil ? .active : .closed, tcpState: nil, firstSeen: firstSeen, lastSeen: lastSeen,
            lastActive: lastSeen, closedAt: closedAt, ageExact: row.integer(20) != 0,
            bytesIn: bytesIn, bytesOut: bytesOut, packetsIn: UInt64(clamping: row.integer(23)), packetsOut: UInt64(clamping: row.integer(24)),
            rateIn: Double(bytesIn) / duration, rateOut: Double(bytesOut) / duration, rttMS: nil, retransmittedBytes: nil,
            service: row.text(12), serviceBasis: row.text(13).flatMap(ServiceBasis.init(rawValue:)),
            hostname: row.text(14), hostnameSource: row.text(15).flatMap(NameSource.init(rawValue:)),
            attribution: row.text(16) ?? "", country: row.text(25), city: row.text(26),
            asn: row.isNull(27) ? nil : UInt32(truncatingIfNeeded: row.integer(27)), org: row.text(28),
            tags: row.text(29)?.split(separator: "\n").map(String.init) ?? [])
        var process = ProcessRecord(pid: pid, name: row.text(2) ?? "pid \(pid)", path: row.text(4), username: row.text(3))
        process.signing = row.text(30).flatMap(SigningStatus.init(rawValue:)) ?? .unknown
        process.teamID = row.text(31)
        return LogEntry(flow: flow, process: process)
    }

    /// The time-range conditions, leaving out any bound that does not exclude anything.
    /// With a bound that covers the whole log gone, SQLite is free to use a better index,
    /// such as the one on the remote address.
    private func rangeConditions(from: Double, to: Double) throws -> ([String], [Database.Value]) {
        // Asked separately so each can be answered from its own index instead of a full scan.
        var oldest = Double.infinity, newest = -Double.infinity
        try database.query("SELECT MIN(first_seen) FROM flow") { row in
            if !row.isNull(0) { oldest = row.real(0) }
            return false
        }
        try database.query("SELECT MAX(last_seen) FROM flow") { row in
            if !row.isNull(0) { newest = row.real(0) }
            return false
        }
        var conditions: [String] = []
        var values: [Database.Value] = []
        if from > oldest {
            conditions.append("last_seen >= ?")
            values.append(.real(from))
        }
        if to < newest {
            conditions.append("first_seen <= ?")
            values.append(.real(to))
        }
        return (conditions, values)
    }

    /// Every connection alive at some point in the range that matches `filter`, visited
    /// newest first. SQL narrows the candidates; the filter itself decides.
    private func scan(
        _ filter: FlowFilter, from: Double, to: Double, now: Double, _ body: (LogEntry) -> Void
    ) throws -> Int {
        var (conditions, values) = try rangeConditions(from: from, to: to)
        if let prefilter = filter.sqlPrefilter() {
            conditions.append(prefilter.clause)
            values += prefilter.bindings.map(Database.Value.init)
        }
        let sql = "SELECT \(Self.columns) FROM flow WHERE \(conditions.isEmpty ? "1" : conditions.joined(separator: " AND ")) ORDER BY first_seen DESC"
        var scanned = 0
        try database.query(sql, values) { row in
            scanned += 1
            if let entry = Self.entry(row), filter.matches(entry.flow, process: entry.process, now: now) { body(entry) }
            return true
        }
        return scanned
    }

    public func query(
        _ filter: FlowFilter, from: Double, to: Double, limit: Int = 1000, buckets: Int = 60, now: Double = Date().timeIntervalSince1970
    ) throws -> LogQueryResult {
        try queue.sync {
            let started = DispatchTime.now().uptimeNanoseconds
            var result = LogQueryResult()
            result.from = from
            result.to = to
            result.histogram = Array(repeating: 0, count: max(buckets, 1))
            let width = max(to - from, 1e-9) / Double(result.histogram.count)

            // When SQL can express the whole filter, let it count and summarise, and
            // rebuild only the rows that will be shown.
            let prefilter = filter.sqlPrefilter()
            if filter.isEmpty || prefilter?.exact == true,
               try database.scalar("SELECT COUNT(*) FROM flow WHERE ascii = 0 AND last_seen >= ? AND first_seen <= ?", [.real(from), .real(to)]) == 0
            {
                var (conditions, values) = try rangeConditions(from: from, to: to)
                if let prefilter {
                    conditions.append(prefilter.clause)
                    values += prefilter.bindings.map(Database.Value.init)
                }
                let condition = conditions.isEmpty ? "1" : conditions.joined(separator: " AND ")
                // One pass gives both the histogram and, by adding it up, the count.
                try database.query(
                    "SELECT CAST((MAX(first_seen, ?) - ?) / ? AS INTEGER) AS bucket, COUNT(*) FROM flow WHERE \(condition) GROUP BY bucket",
                    [.real(from), .real(from), .real(width)] + values
                ) { row in
                    let bucket = min(max(Int(row.integer(0)), 0), result.histogram.count - 1)
                    result.histogram[bucket] += Int(row.integer(1))
                    result.matched += Int(row.integer(1))
                    return true
                }
                try database.query(
                    "SELECT \(Self.columns) FROM flow WHERE \(condition) ORDER BY first_seen DESC LIMIT ?", values + [.integer(Int64(limit))]
                ) { row in
                    if let entry = Self.entry(row) { result.entries.append(entry) }
                    return true
                }
                result.scanned = result.entries.count
                result.milliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
                return result
            }

            result.scanned = try scan(filter, from: from, to: to, now: now) { entry in
                result.matched += 1
                if result.entries.count < limit { result.entries.append(entry) }
                let bucket = Int((max(entry.flow.firstSeen, from) - from) / width)
                result.histogram[min(max(bucket, 0), result.histogram.count - 1)] += 1
            }
            result.milliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
            return result
        }
    }

    /// The machine as the log remembers it at one moment, in the shape the graph draws.
    public func snapshot(at moment: Double, fade: Double = 6) throws -> EngineSnapshot {
        try queue.sync {
            var flows: [Flow] = []
            var processes: [Int32: ProcessRecord] = [:]
            try database.query(
                "SELECT \(Self.columns) FROM flow WHERE last_seen >= ? AND first_seen <= ?",
                [.real(moment - fade), .real(moment)]
            ) { row in
                guard var entry = Self.entry(row) else { return true }
                // What had not yet ended at that moment was open at that moment.
                if let closed = entry.flow.closedAt, closed > moment {
                    entry.flow.closedAt = nil
                    entry.flow.state = .active
                }
                flows.append(entry.flow)
                processes[entry.process.pid] = entry.process
                return true
            }
            return EngineSnapshot(
                time: moment, wallClock: moment, flows: flows.sorted { $0.id < $1.id }, listeners: [],
                processes: processes.values.sorted { $0.pid < $1.pid })
        }
    }

    public func stats() throws -> LogStats {
        try queue.sync {
            var stats = LogStats()
            stats.flows = Int(try database.scalar("SELECT COUNT(*) FROM flow"))
            stats.endpoints = Int(try database.scalar("SELECT COUNT(*) FROM endpoint_first_seen"))
            try database.query("SELECT MIN(first_seen), MAX(COALESCE(closed_at, last_seen)) FROM flow") { row in
                if !row.isNull(0) {
                    stats.oldest = row.real(0)
                    stats.newest = row.real(1)
                }
                return false
            }
            stats.bytesOnDisk = Int(try database.scalar("PRAGMA page_count") * database.scalar("PRAGMA page_size"))
            return stats
        }
    }

    /// When each of these destinations was first seen, for those the log knows.
    public func firstSeen(_ addresses: [IPAddress]) throws -> [IPAddress: Double] {
        try queue.sync {
            var result: [IPAddress: Double] = [:]
            for address in addresses {
                try database.query("SELECT ts FROM endpoint_first_seen WHERE ip = ?", [.text(address.description)]) { row in
                    result[address] = row.real(0)
                    return false
                }
            }
            return result
        }
    }

    /// The newest destinations the log had never seen before, newest first.
    public func recentFirstSeen(limit: Int = 100) throws -> [(address: IPAddress, at: Double)] {
        try queue.sync {
            var result: [(IPAddress, Double)] = []
            try database.query("SELECT ip, ts FROM endpoint_first_seen ORDER BY ts DESC LIMIT ?", [.integer(Int64(limit))]) { row in
                if let address = row.text(0).flatMap({ IPAddress($0) }) { result.append((address, row.real(1))) }
                return true
            }
            return result
        }
    }

    // MARK: - Export

    public static let exportColumns = [
        "first_seen", "closed_at", "process", "pid", "user", "proto", "local_ip", "local_port", "remote_ip", "remote_port",
        "hostname", "hostname_source", "service", "direction", "interface", "bytes_in", "bytes_out", "packets_in", "packets_out",
        "country", "city", "asn", "network_owner", "tags", "signing",
    ]

    /// Writes every match to `destination`. Returns how many were written.
    @discardableResult
    public func export(
        _ filter: FlowFilter, from: Double, to: Double, format: ExportFormat, redactHostnames: Bool, to destination: URL,
        now: Double = Date().timeIntervalSince1970
    ) throws -> Int {
        try queue.sync {
            FileManager.default.createFile(atPath: destination.path, contents: nil)
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }
            let stamp = ISO8601DateFormatter()
            stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if format == .csv { try handle.write(contentsOf: Data((Self.exportColumns.joined(separator: ",") + "\n").utf8)) }

            var written = 0
            var failure: Error?
            var pending = Data()
            _ = try scan(filter, from: from, to: to, now: now) { entry in
                let flow = entry.flow
                let values: [String] = [
                    stamp.string(from: Date(timeIntervalSince1970: flow.firstSeen)),
                    flow.closedAt.map { stamp.string(from: Date(timeIntervalSince1970: $0)) } ?? "",
                    entry.process.name, "\(flow.pid)", entry.process.username ?? "", flow.key.proto.rawValue,
                    flow.key.local.address.description, "\(flow.key.local.port)",
                    flow.key.remote.address.description, "\(flow.key.remote.port)",
                    redactHostnames ? "" : (flow.hostname ?? ""), redactHostnames ? "" : (flow.hostnameSource?.rawValue ?? ""),
                    flow.service ?? "", flow.direction.rawValue, flow.interface ?? "",
                    "\(flow.bytesIn)", "\(flow.bytesOut)", "\(flow.packetsIn)", "\(flow.packetsOut)",
                    flow.country ?? "", flow.city ?? "", flow.asn.map(String.init) ?? "", flow.org ?? "",
                    flow.tags.joined(separator: " "), entry.process.signing == .unknown ? "" : entry.process.signing.rawValue,
                ]
                switch format {
                case .csv:
                    pending.append(Data((values.map(Self.csvField).joined(separator: ",") + "\n").utf8))
                case .jsonl:
                    let numeric: Set<String> = ["pid", "local_port", "remote_port", "bytes_in", "bytes_out", "packets_in", "packets_out", "asn"]
                    var object: [String: Any] = [:]
                    for (name, value) in zip(Self.exportColumns, values) where !value.isEmpty {
                        object[name] = numeric.contains(name) ? (Int(value) ?? 0) as Any : value as Any
                    }
                    if let line = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
                        pending.append(line)
                        pending.append(0x0A)
                    }
                }
                written += 1
                if pending.count > 1 << 20 {
                    do { try handle.write(contentsOf: pending) } catch { failure = error }
                    pending.removeAll(keepingCapacity: true)
                }
            }
            try handle.write(contentsOf: pending)
            if let failure { throw failure }
            return written
        }
    }

    /// Quotes a field when it needs it, and defuses values a spreadsheet would run as a formula.
    static func csvField(_ value: String) -> String {
        var text = value
        if let first = text.first, "=+-@".contains(first) { text = "'" + text }
        guard text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - Retention

    /// Removes connections that ended more than `maximumAge` seconds ago, then the oldest
    /// until the file is under `maximumBytes`. Returns how many connections were removed.
    @discardableResult
    public func prune(maximumAge: Double, maximumBytes: Int, now: Double = Date().timeIntervalSince1970) throws -> Int {
        try queue.sync {
            let cutoff = now - maximumAge
            var removed = try remove(endedBefore: cutoff)
            // Too big even so: drop the oldest tenth at a time.
            for _ in 0..<40 {
                try database.execute("PRAGMA incremental_vacuum")
                let size = Int(try database.scalar("PRAGMA page_count") * database.scalar("PRAGMA page_size"))
                guard size > maximumBytes else { break }
                let total = try database.scalar("SELECT COUNT(*) FROM flow WHERE closed_at IS NOT NULL")
                guard total > 0 else { break }
                var boundary = 0.0
                try database.query(
                    "SELECT closed_at FROM flow WHERE closed_at IS NOT NULL ORDER BY closed_at LIMIT 1 OFFSET ?",
                    [.integer(max(total / 10, 1) - 1)]
                ) { row in
                    boundary = row.real(0)
                    return false
                }
                removed += try remove(endedBefore: boundary + 1e-6)
            }
            try database.execute("PRAGMA incremental_vacuum")
            return removed
        }
    }

    private func remove(endedBefore cutoff: Double) throws -> Int {
        try database.run("DELETE FROM flow_sample WHERE flow_id IN (SELECT id FROM flow WHERE closed_at IS NOT NULL AND closed_at < ?)", [.real(cutoff)])
        let removed = try database.run("DELETE FROM flow WHERE closed_at IS NOT NULL AND closed_at < ?", [.real(cutoff)])
        try database.run("DELETE FROM dns_obs WHERE ts < ?", [.real(cutoff)])
        try database.run("DELETE FROM listener_event WHERE ts < ?", [.real(cutoff)])
        return removed
    }

    /// Erases the whole log and hands the space back.
    public func purge() throws {
        try queue.sync {
            for table in ["flow", "flow_sample", "dns_obs", "listener_event", "endpoint_first_seen"] {
                try database.execute("DELETE FROM \(table)")
            }
            try database.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            try database.execute("VACUUM")
            open.removeAll()
            writtenClosed.removeAll()
            listening.removeAll()
            listeningPrimed = false
            lastDNS = 0
            lastDNSRecord = 0
            endpointsAtStart = 0
        }
    }
}
