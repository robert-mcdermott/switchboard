import Foundation

/// Frame timing, written by the renderer and the GPU completion handler and read by the UI.
public final class FrameStats: @unchecked Sendable {
    public struct Summary: Sendable {
        public var frames = 0
        public var framesPerSecond = 0.0
        public var medianIntervalMS = 0.0
        public var p99IntervalMS = 0.0
        public var worstIntervalMS = 0.0
        public var meanEncodeMS = 0.0
        public var meanGPUMS = 0.0
        public var p99GPUMS = 0.0

        public init() {}
    }

    private let lock = NSLock()
    private var intervals: [Double] = []
    private var encodeTimes: [Double] = []
    private var gpuTimes: [Double] = []
    private let capacity = 4096

    public init() {}

    public func recordFrame(interval: Double, encode: Double) {
        lock.lock()
        append(interval, to: &intervals)
        append(encode, to: &encodeTimes)
        lock.unlock()
    }

    public func recordGPU(_ seconds: Double) {
        lock.lock()
        append(seconds, to: &gpuTimes)
        lock.unlock()
    }

    public func reset() {
        lock.lock()
        intervals.removeAll(keepingCapacity: true)
        encodeTimes.removeAll(keepingCapacity: true)
        gpuTimes.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    public func summary() -> Summary {
        lock.lock()
        let intervals = self.intervals.sorted()
        let encodeTimes = self.encodeTimes
        let gpuTimes = self.gpuTimes.sorted()
        lock.unlock()

        var summary = Summary()
        guard !intervals.isEmpty else { return summary }
        let total = intervals.reduce(0, +)
        summary.frames = intervals.count
        summary.framesPerSecond = Double(intervals.count) / total
        summary.medianIntervalMS = percentile(intervals, 0.5) * 1000
        summary.p99IntervalMS = percentile(intervals, 0.99) * 1000
        summary.worstIntervalMS = (intervals.last ?? 0) * 1000
        summary.meanEncodeMS = encodeTimes.reduce(0, +) / Double(max(encodeTimes.count, 1)) * 1000
        if !gpuTimes.isEmpty {
            summary.meanGPUMS = gpuTimes.reduce(0, +) / Double(gpuTimes.count) * 1000
            summary.p99GPUMS = percentile(gpuTimes, 0.99) * 1000
        }
        return summary
    }

    private func append(_ value: Double, to samples: inout [Double]) {
        if samples.count >= capacity { samples.removeFirst(capacity / 4) }
        samples.append(value)
    }

    private func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))]
    }
}
