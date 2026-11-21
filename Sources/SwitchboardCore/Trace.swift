import Foundation

/// A recorded stream of source events (`.sbtrace`): one JSON object per line, a header
/// first and then one record per engine tick.
///
/// Traces record what the sources said, not what the engine concluded, so replaying one
/// re-runs the engine itself. That makes a trace both a regression test and a demo.
public enum TraceFile {
    public static let version = 1

    public struct Header: Codable, Sendable {
        public var sbtrace: Int
        /// Seconds since 1970 at trace time zero.
        public var wallClock: Double
        public var note: String

        public init(wallClock: Double, note: String) {
            sbtrace = TraceFile.version
            self.wallClock = wallClock
            self.note = note
        }
    }

    public struct Record: Codable, Sendable {
        /// Seconds from the start of the trace.
        public var t: Double
        public var source: String
        public var events: [SourceEvent]

        public init(t: Double, source: String, events: [SourceEvent]) {
            self.t = t
            self.source = source
            self.events = events
        }
    }

    public enum TraceError: Error, CustomStringConvertible {
        case empty
        case unsupportedVersion(Int)
        case malformed(line: Int)

        public var description: String {
            switch self {
            case .empty: "trace is empty"
            case .unsupportedVersion(let version): "trace version \(version) is not supported"
            case .malformed(let line): "trace line \(line) is not valid"
            }
        }
    }

    public static func read(_ url: URL) throws -> (header: Header, records: [Record]) {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        var header: Header?
        var records: [Record] = []
        var lineNumber = 0
        for line in data.split(separator: UInt8(ascii: "\n")) {
            lineNumber += 1
            do {
                if header == nil {
                    let decoded = try decoder.decode(Header.self, from: Data(line))
                    guard decoded.sbtrace == version else { throw TraceError.unsupportedVersion(decoded.sbtrace) }
                    header = decoded
                } else {
                    records.append(try decoder.decode(Record.self, from: Data(line)))
                }
            } catch let error as TraceError {
                throw error
            } catch {
                throw TraceError.malformed(line: lineNumber)
            }
        }
        guard let header else { throw TraceError.empty }
        return (header, records)
    }

    /// Feeds every record through an engine at its recorded time and returns the result.
    public static func replay(_ records: [Record], into engine: FlowEngine) {
        for record in records {
            engine.ingest(record.events, from: record.source, at: record.t)
        }
    }
}

public final class TraceWriter {
    private let handle: FileHandle
    private let encoder = JSONEncoder()
    public private(set) var recordCount = 0

    public init(url: URL, wallClock: Double, note: String) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        encoder.outputFormatting = [.sortedKeys]
        try write(TraceFile.Header(wallClock: wallClock, note: note))
    }

    public func append(_ record: TraceFile.Record) throws {
        try write(record)
        recordCount += 1
    }

    public func close() throws {
        try handle.close()
    }

    private func write(_ value: some Encodable) throws {
        var data = try encoder.encode(value)
        data.append(UInt8(ascii: "\n"))
        try handle.write(contentsOf: data)
    }
}

/// Plays a trace back in real time, as if its sources were live.
public final class TraceReplaySource: FlowSource, @unchecked Sendable {
    public let name: String
    private let records: [TraceFile.Record]
    private let lock = NSLock()
    private var index = 0
    private var startedAt: EngineTime?
    private let loop: Bool

    public init(records: [TraceFile.Record], loop: Bool = false) {
        self.records = records
        self.loop = loop
        name = records.first?.source ?? "trace"
    }

    public func start() throws {}
    public func stop() {}

    public var health: SourceHealth {
        lock.lock()
        defer { lock.unlock() }
        return SourceHealth(running: index < records.count, detail: "record \(index) of \(records.count)")
    }

    public func poll(now: EngineTime) -> [SourceEvent] {
        lock.lock()
        defer { lock.unlock() }
        let origin = startedAt ?? now
        startedAt = origin
        var events: [SourceEvent] = []
        while index < records.count, records[index].t <= now - origin {
            events.append(contentsOf: records[index].events)
            index += 1
        }
        return events
    }
}
