import SwiftUI
import SwitchboardCore
import SwitchboardRender

/// The console: filter bar on top, graph in the middle, inspector on the right, panels below.
struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            TopBar(model: model)
            Rectangle().fill(Color.hairline).frame(height: 1)
            HSplitView {
                VSplitView {
                    graph.frame(minWidth: 480, minHeight: 260)
                    if model.showPanel {
                        BottomPanel(model: model).frame(minHeight: 150, idealHeight: 250, maxHeight: 520)
                    }
                }
                if model.showInspector {
                    InspectorView(model: model).frame(minWidth: 280, idealWidth: 330, maxWidth: 460)
                }
            }
        }
        .background(Color.field)
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

    private var graph: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                GraphView(session: model.session)

                VStack(alignment: .leading, spacing: 4) {
                    if let failure = model.failure {
                        Text(failure).foregroundStyle(Color.attention)
                    }
                    if !model.summary.healthy {
                        ForEach(model.summary.sources, id: \.self) { Text($0).foregroundStyle(Color.attention) }
                    }
                    if model.paused {
                        Text("PAUSED — collection continues").foregroundStyle(Color.caution)
                    }
                    if model.focused {
                        Text("FOCUS — press esc or double-click empty space to release").foregroundStyle(Color.caution)
                    }
                }
                .font(.mono(11))
                .padding(12)
                .allowsHitTesting(false)

                VStack {
                    Spacer()
                    HStack {
                        Text("hover for detail · click to inspect · double-click to focus · space pause · / filter · P profile · 0 reset")
                        Spacer()
                        Text(String(format: "%.0f fps · gpu %.1f ms", model.frames.framesPerSecond, model.frames.meanGPUMS))
                    }
                    .font(.mono(10))
                    .foregroundStyle(Color.dim)
                    .padding(10)
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
    }

    /// Lets the window settle, measures five seconds of frames, saves one, writes the
    /// report, and quits.
    private func measure(to path: String) async {
        try? await Task.sleep(for: .seconds(1))
        // Publish the window number so a script can photograph the whole window.
        if let window = NSApplication.shared.windows.first(where: { $0.title == "Switchboard" }) {
            try? "\(window.windowNumber)".write(toFile: path + ".window", atomically: true, encoding: .utf8)
        }
        try? await Task.sleep(for: .seconds(2))
        model.session.stats.reset()
        try? await Task.sleep(for: .seconds(5))
        let measured = model.session.stats.summary()
        model.session.capture?.request(
            savingTo: URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("png"))
        try? await Task.sleep(for: .milliseconds(600))
        let base = URL(fileURLWithPath: path).deletingPathExtension()
        if let window = NSApplication.shared.windows.first(where: { $0.title == "Switchboard" }) {
            WindowCapture.save(
                window: window, graphFrame: base.appendingPathExtension("png"),
                to: URL(fileURLWithPath: base.path + "-window.png"))
        }
        model.writeMeasurement(to: path, measured: measured)
        NSApplication.shared.terminate(nil)
    }
}

struct TopBar: View {
    @Bindable var model: AppModel
    @FocusState private var filterFocused: Bool
    @State private var showHelp = false

    var body: some View {
        HStack(spacing: 12) {
            Text("SWITCHBOARD")
                .font(.mono(12, .semibold))
                .kerning(3)
                .foregroundStyle(Color.signal)

            Text(model.modeLine)
                .font(.mono(10))
                .foregroundStyle(Color.dim)
                .help("Standalone mode sees your own processes. System daemons need the collector.")

            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease").foregroundStyle(Color.dim)
                TextField("Filter — process:Slack rate>100KB/s", text: $model.filterText)
                    .textFieldStyle(.plain)
                    .font(.mono(12))
                    .foregroundStyle(model.filterError == nil ? Color.readout : Color.attention)
                    .focused($filterFocused)
                    .onSubmit { model.applyFilter() }
                    .onChange(of: model.filterText) { model.applyFilter() }
                if !model.filterText.isEmpty {
                    Button { model.clearFilter() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.dim)
                        .help("Clear the filter")
                }
                Button { showHelp.toggle() } label: { Image(systemName: "questionmark.circle") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.dim)
                    .help("Filter fields")
                    .popover(isPresented: $showHelp, arrowEdge: .bottom) { FilterHelp() }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.panel)
            .overlay(Rectangle().strokeBorder(model.filterError == nil ? Color.hairline : Color.attention, lineWidth: 1))
            .frame(minWidth: 260, maxWidth: 620)

            Text(model.filterError ?? model.matchLine)
                .font(.mono(10))
                .foregroundStyle(model.filterError == nil ? Color.dim : Color.attention)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(model.statusLine)
                .font(.mono(11))
                .foregroundStyle(Color.readout)
                .lineLimit(1)

            Picker("Profile", selection: Binding(get: { model.profile }, set: { model.setProfile($0) })) {
                ForEach(RenderProfile.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 210)
            .help("How much motion and glow to use. The data shown is the same.")

            Button { model.togglePause() } label: { Image(systemName: model.paused ? "play.fill" : "pause.fill") }
                .help(model.paused ? "Resume the display" : "Pause the display. Collection continues.")
            Button { model.showPanel.toggle() } label: { Image(systemName: "rectangle.bottomthird.inset.filled") }
                .help("Show or hide the panels (B)")
            Button { model.showInspector.toggle() } label: { Image(systemName: "sidebar.right") }
                .help("Show or hide the inspector (I)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.field)
        .onChange(of: model.filterFocusRequests) { filterFocused = true }
    }
}

struct FilterHelp: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Filter language")
            Text("Terms combine with AND unless you write OR. NOT and parentheses work as expected.\nA bare word matches process name, remote address, or service.")
                .font(.mono(11))
                .foregroundStyle(Color.readout)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 2) {
                ForEach(FlowFilter.fields, id: \.name) { field in
                    GridRow {
                        Text(field.name).foregroundStyle(Color.signal)
                        Text(field.help).foregroundStyle(Color.dim)
                    }
                }
            }
            .font(.mono(11))
            SectionTitle("Examples")
            VStack(alignment: .leading, spacing: 2) {
                Text("process:Slack rate_out>100KB/s")
                Text("r_port:443 NOT process:*Helper*")
                Text("age>1h bytes<10KB")
                Text("remote:10.0.0.0/8 OR remote:192.168.0.0/16")
            }
            .font(.mono(11))
            .foregroundStyle(Color.readout)
        }
        .padding(16)
        .frame(width: 440)
        .background(Color.panel)
    }
}

/// Keeps the tooltip beside the pointer and inside the graph.
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

struct InfoRows: View {
    let info: HoverInfo

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
            ForEach(info.rows) { row in
                GridRow {
                    Text(row.label).foregroundStyle(Color.dim)
                    Text(row.value)
                        .foregroundStyle(Color.readout)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
        }
        .font(.mono(11))
    }
}

struct TooltipView: View {
    let info: HoverInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(info.title).font(.mono(12, .semibold)).foregroundStyle(Color.signal)
            Text(info.subtitle).font(.mono(10)).foregroundStyle(Color.dim)
            InfoRows(info: info)
            if let footnote = info.footnote {
                Text(footnote).font(.mono(10)).foregroundStyle(Color.dim)
            }
        }
        .padding(12)
        .frame(maxWidth: 460, alignment: .leading)
        .background(Color.panel.opacity(0.96))
        .overlay(Rectangle().strokeBorder(Color.hairline, lineWidth: 1))
    }
}
