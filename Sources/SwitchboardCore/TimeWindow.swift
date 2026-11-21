/// The recent past, kept in memory so the display can be scrubbed back through it.
///
/// One snapshot of the engine's model is kept per second for the last five minutes, and
/// one every five seconds before that, which is fine enough to scrub through and a
/// fifth of the memory. The window is bounded two ways: by age, and by the total number
/// of flow records held, so a busy machine keeps a shorter history rather than an
/// unbounded amount of memory.
public struct TimeWindow: Sendable {
    public private(set) var snapshots: [EngineSnapshot] = []
    /// Oldest history kept, in seconds.
    public var maximumAge: Double
    /// Upper bound on flow records across all snapshots.
    public var maximumRecords: Int
    private var records = 0
    /// History older than this is thinned to one snapshot per `coarseSpacing`.
    public var fineSeconds: Double = 300
    public var coarseSpacing: Double = 5
    /// Snapshots before this index have already been thinned.
    private var thinnedUpTo = 0

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
        if drop > 0 {
            snapshots.removeFirst(drop)
            thinnedUpTo = max(0, thinnedUpTo - drop)
        }
        thin(before: snapshot.time - fineSeconds)
    }

    /// Keeps one snapshot per `coarseSpacing` among those older than `cutoff`. Each
    /// snapshot is looked at once, as it crosses the cutoff.
    private mutating func thin(before cutoff: EngineTime) {
        var index = max(thinnedUpTo, 1)
        while index < snapshots.count, snapshots[index].time < cutoff {
            if snapshots[index].time - snapshots[index - 1].time < coarseSpacing {
                records -= snapshots[index].flows.count
                snapshots.remove(at: index)
            } else {
                index += 1
            }
        }
        thinnedUpTo = index
    }

    public mutating func removeAll() {
        snapshots.removeAll(keepingCapacity: true)
        records = 0
        thinnedUpTo = 0
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
