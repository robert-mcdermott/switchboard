import SwiftUI

/// Colours from docs/SPEC.md §9.2, for everything drawn by SwiftUI.
extension Color {
    static let signal = Color(red: 0.216, green: 0.902, blue: 1.0)
    static let readout = Color(red: 0.79, green: 0.84, blue: 0.91)
    static let dim = Color(red: 0.42, green: 0.49, blue: 0.58)
    static let attention = Color(red: 1.0, green: 0.231, blue: 0.361)
    static let caution = Color(red: 1.0, green: 0.784, blue: 0.341)
    static let quic = Color(red: 0.608, green: 0.549, blue: 1.0)
    static let field = Color(red: 5 / 255, green: 8 / 255, blue: 15 / 255)
    static let panel = Color(red: 0.027, green: 0.043, blue: 0.075)
    static let hairline = Color(red: 0.11, green: 0.17, blue: 0.26)
}

extension Font {
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// A flat panel with a hairline border: no shadows, no rounded corners.
struct PanelChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color.panel)
            .overlay(Rectangle().strokeBorder(Color.hairline, lineWidth: 1))
    }
}

struct SectionTitle: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.mono(10, .semibold))
            .kerning(1.5)
            .foregroundStyle(Color.dim)
    }
}
