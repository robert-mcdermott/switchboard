/// The recent past, kept in memory so the display can be scrubbed back through it.
///
/// One snapshot of the engine's model is kept per second. The window is bounded two
/// ways: by age, and by the total number of flow records held, so a busy machine keeps a
/// shorter history rather than an unbounded amount of memory.
public struct TimeWindow: Sendable {
    public private(set) var snapshots: [EngineSnapshot] = []
    /// Oldest history kept, in seconds.
    public var maximumAge: Double
    /// Upper bound on flow records across all snapshots.
    public var maximumRecords: Int
    private var records = 0

    public init(maximumAge: Double = 3600, maximumRecords: Int = 600_000) {
        self.maximumAge = maximumAge
        self.maximumRecords = maximumRecords
    }

    public var isEmpty: Bool { snapshots.isEmpty }

    /// Engine times of the oldest and newest moments held.
    public var range: ClosedRange<EngineTime>? {
        guard let first = snapshots.first, let last = snapshots.last else { return nil }
        return first.time...last.time
    }

    public mutating func append(_ snapshot: EngineSnapshot) {
        // Time only moves forward; anything else is a source restarting.
        if let last = snapshots.last, snapshot.time <= last.time { removeAll() }
        snapshots.append(snapshot)
        records += snapshot.flows.count

        var drop = 0
        while drop < snapshots.count - 1,
              snapshot.time - snapshots[drop].time > maximumAge || records > maximumRecords
        {
            records -= snapshots[drop].flows.count
            drop += 1
        }
        if drop > 0 { snapshots.removeFirst(drop) }
    }

    public mutating func removeAll() {
        snapshots.removeAll(keepingCapacity: true)
        records = 0
    }

    /// The latest snapshot at or before `time`, or the oldest held if `time` precedes them all.
    public func snapshot(at time: EngineTime) -> EngineSnapshot? {
        guard !snapshots.isEmpty else { return nil }
        var low = 0, high = snapshots.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if snapshots[middle].time <= time { low = middle } else { high = middle - 1 }
        }
        return snapshots[low]
    }
}
