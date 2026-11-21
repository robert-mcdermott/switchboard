import simd

// Instance layouts shared with Shaders/Graph.metal. Field order and sizes must match the
// shader structs exactly; `GraphRenderer` checks the strides when it starts.

public struct EdgeInstance: Sendable {
    public var p0: SIMD2<Float>
    public var p1: SIMD2<Float>
    public var control: SIMD2<Float>
    /// World units.
    public var halfWidth: Float
    public var phase: Float
    public var color: SIMD4<Float>
    public var speed: Float
    public var density: Float
    /// Steady brightness.
    public var glow: Float
    /// Brightness of the travelling pulses.
    public var pulse: Float
}

public struct NodeInstance: Sendable {
    public var center: SIMD2<Float>
    /// World units.
    public var radius: Float
    /// Slot in the icon atlas, or negative for none.
    public var icon: Float
    public var color: SIMD4<Float>
    /// Colour in rgb, opacity in a.
    public var ring: SIMD4<Float>
    /// Animation time at which the node appeared.
    public var birth: Float
    public var intensity: Float
    /// 0 host, 1 process, 2 endpoint.
    public var kind: Float
    public var padding: Float = 0
}

struct LabelInstance {
    /// World position the label hangs from.
    var anchor: SIMD2<Float>
    /// Pixel offset of the label's top-left corner from the anchor.
    var offset: SIMD2<Float>
    /// Pixels.
    var size: SIMD2<Float>
    var padding: SIMD2<Float> = .zero
    var uv: SIMD4<Float>
    var color: SIMD4<Float>
}

struct Uniforms {
    var viewport: SIMD2<Float>
    var center: SIMD2<Float>
    /// Pixels per world unit.
    var scale: Float
    var time: Float
    var pulseGain: Float
    var bloom: Float
    var grain: Float
    var gridAlpha: Float
    /// Pixels per point.
    var backing: Float
    /// Pixels per world unit for sizes, which grow more slowly than distances when zoomed in.
    var markScale: Float = 1
    /// The theme's background and graph-paper colours; the fourth component is unused.
    var field = SIMD4<Float>(5.0 / 255, 8.0 / 255, 15.0 / 255, 1)
    var grid = SIMD4<Float>(0.055, 0.102, 0.169, 1)
}

/// The visual language from docs/SPEC.md §9.2.
public enum Palette {
    private static func rgb(_ hex: UInt32) -> SIMD3<Float> {
        SIMD3(Float((hex >> 16) & 0xff), Float((hex >> 8) & 0xff), Float(hex & 0xff)) / 255
    }

    public static let tls = rgb(0x37E6FF)
    public static let quic = rgb(0x9B8CFF)
    public static let dns = rgb(0x5CF2A5)
    public static let remoteAccess = rgb(0xFFC857)
    public static let cleartext = rgb(0xFF8A3D)
    public static let other = rgb(0x7C8DA6)
    public static let attention = rgb(0xFF3B5C)
    public static let text = rgb(0xC9D6E8)
    public static let secondaryText = rgb(0x6B7C93)
    public static let host = rgb(0x37E6FF)
    public static let process = rgb(0xC9D6E8)
    public static let trunk = rgb(0x5E86B8)

    /// Hue for a service label. Unknown services are slate, never a warm colour.
    public static func color(forService service: String?) -> SIMD3<Float> {
        switch service {
        case "HTTPS", "HTTPS-alt", "TLS", "IMAPS", "SMTPS", "POP3S", "LDAPS", "MQTT-TLS", "APNs", "FCM", "DNS-over-TLS":
            tls
        case "QUIC": quic
        case "DNS", "mDNS", "LLMNR": dns
        case "SSH", "RDP", "VNC", "Remote Desktop", "Telnet": remoteAccess
        case "HTTP", "HTTP-alt", "HTTP-dev", "FTP", "SMTP", "IMAP", "POP3", "MQTT": cleartext
        default: other
        }
    }
}

/// A colour theme: every colour the graph is drawn in, from the service hues to the
/// background. Stored under the "palette" setting; the raw values are what it saves.
///
/// All of them are dark. The graph adds light to a dark field, as a radar screen does,
/// and a pale background would wash the glow out.
public enum PaletteScheme: String, Sendable, CaseIterable {
    /// The colours in docs/SPEC.md §9.2: cyan, violet, and green on deep navy.
    case standard
    /// Magenta and cyan on deep violet, after the neon of film cyberspace.
    case neon
    /// Green on black, like a phosphor terminal; warm colours are kept for remote access
    /// and cleartext so they still stand out.
    case phosphor
    /// Amber on brown-black, like an amber terminal.
    case amber
    /// Pale blues and whites on blue-black: quiet, for a room that is not dark.
    case ice
    /// Colours chosen to stay distinguishable with the common colour-vision deficiencies.
    case colorSafe

    private static func rgb(_ hex: UInt32) -> SIMD3<Float> {
        SIMD3(Float((hex >> 16) & 0xff), Float((hex >> 8) & 0xff), Float(hex & 0xff)) / 255
    }

    /// The name shown in Settings.
    public var displayName: String {
        switch self {
        case .standard: "Standard"
        case .neon: "Neon"
        case .phosphor: "Phosphor"
        case .amber: "Amber"
        case .ice: "Ice"
        case .colorSafe: "Colour-safe"
        }
    }

    /// The next theme, for cycling through them with a key.
    public var next: PaletteScheme {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    /// The service categories, in a fixed order: TLS, QUIC, DNS, remote access, cleartext, other.
    public var categories: [SIMD3<Float>] {
        switch self {
        case .standard:
            [Palette.tls, Palette.quic, Palette.dns, Palette.remoteAccess, Palette.cleartext, Palette.other]
        case .neon:
            [Self.rgb(0x00F0FF), Self.rgb(0xFF2BD6), Self.rgb(0x7CFF6B), Self.rgb(0xFFE347), Self.rgb(0xFF6B35), Self.rgb(0x8C7AB8)]
        case .phosphor:
            [Self.rgb(0x33FF88), Self.rgb(0xC6FF3B), Self.rgb(0x3BE8D0), Self.rgb(0xFFD23F), Self.rgb(0xFF8F3B), Self.rgb(0x4E7D62)]
        case .amber:
            [Self.rgb(0xFFB000), Self.rgb(0xFFE6B0), Self.rgb(0xC8D86A), Self.rgb(0xFF7A45), Self.rgb(0xFF4D6D), Self.rgb(0x8A6F4E)]
        case .ice:
            [Self.rgb(0x9EE7FF), Self.rgb(0xC3B6FF), Self.rgb(0xA6FFE0), Self.rgb(0xFFE3A3), Self.rgb(0xFFB08A), Self.rgb(0x7D93AD)]
        case .colorSafe:
            // After Okabe and Ito: sky blue, reddish purple, bluish green, yellow, vermillion,
            // and a grey dark enough to differ from the purple by lightness alone. Checked
            // in PaletteTests against simulated protanopia, deuteranopia, and tritanopia.
            [Self.rgb(0x56B4E9), Self.rgb(0xCC79A7), Self.rgb(0x009E73), Self.rgb(0xF0E442), Self.rgb(0xD55E00), Self.rgb(0x606060)]
        }
    }

    /// This Mac.
    public var host: SIMD3<Float> {
        switch self {
        case .ice: Self.rgb(0xEAF8FF)
        default: categories[0]
        }
    }

    public var remoteAccess: SIMD3<Float> { categories[3] }

    /// The lines from this Mac to its processes, and the grid lines a layout draws.
    public var trunk: SIMD3<Float> {
        switch self {
        case .standard, .colorSafe: Palette.trunk
        case .neon: Self.rgb(0x7A3FD0)
        case .phosphor: Self.rgb(0x2E8F55)
        case .amber: Self.rgb(0xA8621E)
        case .ice: Self.rgb(0x6F93BF)
        }
    }

    /// Connections between two processes on this Mac.
    public var local: SIMD3<Float> {
        switch self {
        case .standard, .colorSafe: Palette.other * 1.15
        default: categories[5] * 1.15
        }
    }

    /// Process nodes.
    public var process: SIMD3<Float> {
        switch self {
        case .standard, .colorSafe: Palette.process
        case .neon: Self.rgb(0xF2D9FF)
        case .phosphor: Self.rgb(0xC8FFD9)
        case .amber: Self.rgb(0xFFE7C2)
        case .ice: Self.rgb(0xDDE8F5)
        }
    }

    /// Labels of processes and destinations.
    public var text: SIMD3<Float> {
        switch self {
        case .standard, .colorSafe: Palette.text
        case .neon: Self.rgb(0xE8D8FF)
        case .phosphor: Self.rgb(0xB8F5C8)
        case .amber: Self.rgb(0xFFD9A0)
        case .ice: Self.rgb(0xDDE8F5)
        }
    }

    /// Quieter labels, places with no location, and the land on the globe.
    public var secondaryText: SIMD3<Float> {
        switch self {
        case .standard, .colorSafe: Palette.secondaryText
        case .neon: Self.rgb(0x8A6FB0)
        case .phosphor: Self.rgb(0x4F8F66)
        case .amber: Self.rgb(0x9C7444)
        case .ice: Self.rgb(0x7E93AD)
        }
    }

    /// The ring on a process whose signature is missing or broken.
    public var attention: SIMD3<Float> {
        switch self {
        case .standard, .colorSafe: Palette.attention
        case .neon: Self.rgb(0xFF1E56)
        case .phosphor: Self.rgb(0xFF4545)
        case .amber: Self.rgb(0xFF2E4D)
        case .ice: Self.rgb(0xFF5C7A)
        }
    }

    /// The background, before the vignette darkens its edges.
    public var field: SIMD3<Float> {
        switch self {
        case .standard, .colorSafe: SIMD3(5, 8, 15) / 255
        case .neon: SIMD3(11, 4, 24) / 255
        case .phosphor: SIMD3(2, 10, 5) / 255
        case .amber: SIMD3(13, 7, 2) / 255
        case .ice: SIMD3(4, 8, 15) / 255
        }
    }

    /// The graph paper behind everything, at full strength.
    public var grid: SIMD3<Float> {
        switch self {
        case .standard, .colorSafe: SIMD3(0.055, 0.102, 0.169)
        case .neon: SIMD3(0.12, 0.04, 0.17)
        case .phosphor: SIMD3(0.03, 0.12, 0.06)
        case .amber: SIMD3(0.13, 0.07, 0.02)
        case .ice: SIMD3(0.06, 0.11, 0.16)
        }
    }

    public func color(forService service: String?) -> SIMD3<Float> {
        categories[Palette.category(forService: service)]
    }
}

extension Palette {
    /// Index into `PaletteScheme.categories` for a service label.
    public static func category(forService service: String?) -> Int {
        switch service {
        case "HTTPS", "HTTPS-alt", "TLS", "IMAPS", "SMTPS", "POP3S", "LDAPS", "MQTT-TLS", "APNs", "FCM", "DNS-over-TLS": 0
        case "QUIC": 1
        case "DNS", "mDNS", "LLMNR": 2
        case "SSH", "RDP", "VNC", "Remote Desktop", "Telnet": 3
        case "HTTP", "HTTP-alt", "HTTP-dev", "FTP", "SMTP", "IMAP", "POP3", "MQTT": 4
        default: 5
        }
    }
}
