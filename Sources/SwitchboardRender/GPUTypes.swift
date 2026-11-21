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
    var padding: Float = 0
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

/// Which set of service colours to use.
public enum PaletteScheme: String, Sendable, CaseIterable {
    /// The colours in docs/SPEC.md §9.2.
    case standard
    /// Colours chosen to stay distinguishable with the common colour-vision deficiencies.
    case colorSafe

    private static func rgb(_ hex: UInt32) -> SIMD3<Float> {
        SIMD3(Float((hex >> 16) & 0xff), Float((hex >> 8) & 0xff), Float(hex & 0xff)) / 255
    }

    /// The service categories, in a fixed order: TLS, QUIC, DNS, remote access, cleartext, other.
    public var categories: [SIMD3<Float>] {
        switch self {
        case .standard:
            [Palette.tls, Palette.quic, Palette.dns, Palette.remoteAccess, Palette.cleartext, Palette.other]
        case .colorSafe:
            // After Okabe and Ito: sky blue, reddish purple, bluish green, yellow, vermillion,
            // and a grey dark enough to differ from the purple by lightness alone. Checked
            // in PaletteTests against simulated protanopia, deuteranopia, and tritanopia.
            [Self.rgb(0x56B4E9), Self.rgb(0xCC79A7), Self.rgb(0x009E73), Self.rgb(0xF0E442), Self.rgb(0xD55E00), Self.rgb(0x606060)]
        }
    }

    public var host: SIMD3<Float> { categories[0] }
    public var remoteAccess: SIMD3<Float> { categories[3] }
    public var trunk: SIMD3<Float> { Palette.trunk }
    /// Connections between two processes on this Mac.
    public var local: SIMD3<Float> { Palette.other * 1.15 }

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
