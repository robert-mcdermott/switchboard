/// Small deterministic generator. Anything synthetic (the simulator, the render prototype)
/// draws from one of these so every run produces the same result.
public struct SplitMix64: Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in 0 ..< 1.
    public mutating func unit() -> Float {
        Float(next() >> 40) / Float(1 << 24)
    }

    /// Uniform in 0 ..< 1.
    public mutating func double() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }

    /// Uniform in 0 ..< bound.
    public mutating func below(_ bound: Int) -> Int {
        bound <= 1 ? 0 : Int(next() % UInt64(bound))
    }
}
