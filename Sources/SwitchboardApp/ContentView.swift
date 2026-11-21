import SwiftUI
import SwitchboardCore
import SwitchboardRender

private extension Color {
    static let signal = Color(red: 0.216, green: 0.902, blue: 1.0)
    static let readout = Color(red: 0.79, green: 0.84, blue: 0.91)
    static let dim = Color(red: 0.42, green: 0.49, blue: 0.58)
    static let attention = Color(red: 1.0, green: 0.231, blue: 0.361)
    static let field = Color(red: 5 / 255, green: 8 / 255, blue: 15 / 255)
}

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Color.field.ignoresSafeArea()
                GraphView(session: model.session).ignoresSafeArea()

                hud.padding(16).allowsHitTesting(false)

                VStack {
                    Spacer()
                    footer.padding(16)
                }
                .allowsHitTesting(false)

                if let hover = model.hover {
                    TooltipView(info: hover)
                        .fixedSize()
                        .modifier(TooltipPlacement(point: model.hoverPoint, container: geometry.size))
                        .allowsHitTesting(false)
                }
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                model.refresh()
            }
        }
        .task {
            guard let path = model.measurePath else { return }
            await measure(to: path)
        }
    }

    private var hud: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SWITCHBOARD")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .kerning(3)
                .foregroundStyle(Color.signal)
            Text(model.modeLine).foregroundStyle(Color.dim)

            if let failure = model.failure {
                Text(failure).foregroundStyle(Color.attention)
            } else {
                Text(model.statusLine).foregroundStyle(Color.readout)
                Text("\(model.summary.processes) processes · \(model.summary.listeners) listening, \(model.summary.exposed) exposed")
                    .foregroundStyle(Color.readout)
                if !model.summary.healthy {
                    ForEach(model.summary.sources, id: \.self) { line in
                        Text(line).foregroundStyle(Color.attention)
                    }
                }
            }
            if model.paused {
                Text("PAUSED — collection continues")
                    .foregroundStyle(Color(red: 1.0, green: 0.784, blue: 0.341))
            }
        }
        .font(.system(size: 11, design: .monospaced))
    }

    private var footer: some View {
        HStack {
            Text("space pause · P profile (\(model.profile.rawValue)) · 0 reset view · scroll to pan, pinch or ⌘-scroll to zoom")
            Spacer()
            Text(String(format: "%.0f fps · gpu %.1f ms", model.frames.framesPerSecond, model.frames.meanGPUMS))
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(Color.dim)
    }

    /// Lets the window settle, measures five seconds of frames, saves one, writes the
    /// report, and quits.
    private func measure(to path: String) async {
        try? await Task.sleep(for: .seconds(3))
        model.session.stats.reset()
        try? await Task.sleep(for: .seconds(5))
        let measured = model.session.stats.summary()
        model.session.capture?.request(
            savingTo: URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("png"))
        try? await Task.sleep(for: .milliseconds(600))
        model.writeMeasurement(to: path, measured: measured)
        NSApplication.shared.terminate(nil)
    }
}

/// Keeps the tooltip beside the pointer and inside the window.
private struct TooltipPlacement: ViewModifier {
    let point: CGPoint
    let container: CGSize
    @State private var size: CGSize = .zero

    func body(content: Content) -> some View {
        let gap: CGFloat = 18
        var x = point.x + gap
        var y = point.y + gap
        if x + size.width > container.width - 8 { x = point.x - gap - size.width }
        if y + size.height > container.height - 8 { y = point.y - gap - size.height }
        return content
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .offset(x: max(8, x), y: max(8, y))
    }
}

struct TooltipView: View {
    let info: HoverInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(info.title)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.signal)
            Text(info.subtitle)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.dim)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                ForEach(info.rows) { row in
                    GridRow {
                        Text(row.label).foregroundStyle(Color.dim)
                        Text(row.value).foregroundStyle(Color.readout).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            .font(.system(size: 11, design: .monospaced))
            if let footnote = info.footnote {
                Text(footnote).font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.dim)
            }
        }
        .padding(12)
        .frame(maxWidth: 460, alignment: .leading)
        .background(Color(red: 0.03, green: 0.05, blue: 0.09).opacity(0.94))
        .overlay(Rectangle().strokeBorder(Color(red: 0.16, green: 0.26, blue: 0.38), lineWidth: 1))
    }
}
