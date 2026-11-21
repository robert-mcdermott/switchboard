import Foundation

/// Turns a cumulative byte counter, sampled at uneven intervals, into a smoothed rate.
///
/// The smoothing is an exponentially weighted moving average defined by its half-life,
/// so the result does not depend on how often it is sampled.
public struct RateEstimator: Sendable, Codable {
    public private(set) var rate: Double = 0
    private var lastCount: UInt64?
    private var lastTime: EngineTime = 0

    public init() {}

    public enum Outcome: Equatable, Sendable {
        /// The counter moved forward by this many bytes.
        case advanced(UInt64)
        /// First sample; nothing to compare against yet.
        case primed
        /// The counter went backwards: this is a different socket.
        case reset
    }

    @discardableResult
    public mutating func update(count: UInt64, at time: EngineTime, halfLife: Double) -> Outcome {
        guard let previous = lastCount else {
            lastCount = count
            lastTime = time
            return .primed
        }
        guard count >= previous else {
            lastCount = count
            lastTime = time
            rate = 0
            return .reset
        }
        let elapsed = time - lastTime
        // Two samples at the same instant carry no rate information.
        guard elapsed > 1e-6 else { return .advanced(0) }
        let delta = count - previous
        let instantaneous = Double(delta) / elapsed
        let weight = 1 - pow(0.5, elapsed / max(halfLife, 1e-6))
        rate += weight * (instantaneous - rate)
        if rate < 0.5 { rate = 0 }
        lastCount = count
        lastTime = time
        return .advanced(delta)
    }
}

public enum ByteFormat {
    /// `1.4 MB`, `12 KB`, `980 B` — decimal units, as network rates are quoted.
    public static func bytes(_ value: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var scaled = value
        var unit = 0
        while scaled >= 1000, unit < units.count - 1 {
            scaled /= 1000
            unit += 1
        }
        if unit == 0 { return "\(Int(scaled)) B" }
        return String(format: scaled >= 100 ? "%.0f %@" : "%.1f %@", scaled, units[unit])
    }

    public static func rate(_ bytesPerSecond: Double) -> String {
        bytesPerSecond < 1 ? "–" : bytes(bytesPerSecond) + "/s"
    }

    /// `2h14m`, `37m`, `12s`.
    public static func duration(_ seconds: Double) -> String {
        let total = Int(seconds)
        if total >= 86_400 { return "\(total / 86_400)d\(total % 86_400 / 3600)h" }
        if total >= 3600 { return "\(total / 3600)h\(total % 3600 / 60)m" }
        if total >= 60 { return "\(total / 60)m\(total % 60)s" }
        return "\(total)s"
    }
}
