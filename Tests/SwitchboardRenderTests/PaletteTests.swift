import Foundation
import Testing
import simd

@testable import SwitchboardRender

/// Are the service colours still told apart by someone with a colour-vision deficiency?
///
/// Each colour is passed through a simulation of the deficiency (Machado, Oliveira and
/// Fernandes, 2009, full severity), converted to CIELAB, and compared with every other.
/// A difference of about 10 is roughly where two colours stop being easy to tell apart
/// at a glance.
@Suite struct PaletteTests {
    enum Vision: CaseIterable {
        case normal, protanopia, deuteranopia, tritanopia

        var matrix: simd_float3x3 {
            switch self {
            case .normal:
                matrix_identity_float3x3
            case .protanopia:
                simd_float3x3(rows: [
                    SIMD3(0.152286, 1.052583, -0.204868), SIMD3(0.114503, 0.786281, 0.099216),
                    SIMD3(-0.003882, -0.048116, 1.051998),
                ])
            case .deuteranopia:
                simd_float3x3(rows: [
                    SIMD3(0.367322, 0.860646, -0.227968), SIMD3(0.280085, 0.672501, 0.047413),
                    SIMD3(-0.011820, 0.042940, 0.968881),
                ])
            case .tritanopia:
                simd_float3x3(rows: [
                    SIMD3(1.255528, -0.076749, -0.178779), SIMD3(-0.078411, 0.930809, 0.147602),
                    SIMD3(0.004733, 0.691367, 0.303900),
                ])
            }
        }
    }

    static func lab(_ srgb: SIMD3<Float>, seenWith vision: Vision) -> SIMD3<Float> {
        func linear(_ c: Float) -> Float { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let seen = simd_clamp(vision.matrix * SIMD3(linear(srgb.x), linear(srgb.y), linear(srgb.z)), .zero, .one)
        let x = 0.4124564 * seen.x + 0.3575761 * seen.y + 0.1804375 * seen.z
        let y = 0.2126729 * seen.x + 0.7151522 * seen.y + 0.0721750 * seen.z
        let z = 0.0193339 * seen.x + 0.1191920 * seen.y + 0.9503041 * seen.z
        func f(_ t: Float) -> Float { t > 0.008856 ? cbrt(t) : 7.787 * t + 16 / 116 }
        let fx = f(x / 0.95047), fy = f(y), fz = f(z / 1.08883)
        return SIMD3(116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    /// The smallest difference between any two service colours.
    static func closestPair(_ scheme: PaletteScheme, _ vision: Vision) -> Float {
        let colors = scheme.categories.map { lab($0, seenWith: vision) }
        var closest = Float.infinity
        for i in colors.indices {
            for j in colors.indices where j > i { closest = min(closest, simd_distance(colors[i], colors[j])) }
        }
        return closest
    }

    @Test func theColourSafePaletteStaysDistinctUnderEveryDeficiency() {
        for vision in Vision.allCases {
            #expect(Self.closestPair(.colorSafe, vision) >= 15, "\(vision)")
        }
    }

    @Test func theStandardPaletteDoesNot() {
        // Recorded so the limitation is known, not hidden: under tritanopia the standard
        // cyan and green come within about 8 of each other, and under deuteranopia the
        // amber and orange within about 13. That is why the colour-safe palette exists.
        #expect(Self.closestPair(.standard, .normal) > 30)
        #expect(Self.closestPair(.standard, .tritanopia) < 10)
        #expect(Self.closestPair(.standard, .deuteranopia) < 15)
        for vision in Vision.allCases where vision != .normal {
            #expect(Self.closestPair(.colorSafe, vision) > Self.closestPair(.standard, vision) || vision == .protanopia)
        }
    }

    @Test func everyServiceHasAColourInBothPalettes() {
        for scheme in PaletteScheme.allCases {
            #expect(scheme.categories.count == 6)
            #expect(scheme.color(forService: "HTTPS") == scheme.categories[0])
            #expect(scheme.color(forService: "QUIC") == scheme.categories[1])
            #expect(scheme.color(forService: nil) == scheme.categories[5])
            #expect(scheme.color(forService: "Something new") == scheme.categories[5])
        }
    }
}
