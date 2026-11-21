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
        VStack(spacing: 0) {
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    GraphView(session: model.session)
                    GraphStatus(model: model)
                    GraphFooter(model: model)
                    HoverLayer(model: model, container: geometry.size)
                }
            }
            Rectangle().fill(Color.hairline).frame(height: 1)
            TimelineBar(model: model)
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

// The overlays are separate views on purpose. Each reads only what it shows, so a new
// frame-rate figure or a pointer movement redraws that one overlay and not the whole
// window, which is what was costing the graph frames.

private struct GraphStatus: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let failure = model.failure {
                Text(failure).foregroundStyle(Color.attention)
            }
            if !model.summary.healthy {
                ForEach(model.summary.sources, id: \.self) { Text($0).foregroundStyle(Color.attention) }
            }
            if model.focused {
                Text("FOCUS — press esc or double-click empty space to release").foregroundStyle(Color.caution)
            }
            if model.keepEnded {
                Text("KEEPING ENDED CONNECTIONS — \(model.endedCount) shown dimmed · press E to turn off")
                    .foregroundStyle(Color.dim)
            }
        }
        .font(.mono(11))
        .padding(12)
        .allowsHitTesting(false)
    }
}

private struct GraphFooter: View {
    let model: AppModel

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Text("hover for detail · click to inspect · ⌘-click to add · double-click to focus · right-click for more · / filter")
                Spacer()
                Text(String(format: "%.0f fps · gpu %.1f ms", model.frames.framesPerSecond, model.frames.meanGPUMS))
            }
            .font(.mono(10))
            .foregroundStyle(Color.dim)
            .padding(10)
        }
        .allowsHitTesting(false)
    }
}

private struct HoverLayer: View {
    let model: AppModel
    let container: CGSize

    var body: some View {
        if let hover = model.hover {
            TooltipView(info: hover)
                .fixedSize()
                .modifier(TooltipPlacement(point: model.hoverPoint, container: container))
                .allowsHitTesting(false)
        }
    }
}

/// The recent past as a slider. Drag left to go back; the graph and every table follow.
struct TimelineBar: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Button { model.togglePause() } label: {
                Image(systemName: model.paused ? "play.fill" : "pause.fill").frame(width: 14)
            }
            .buttonStyle(.borderless)
            .help(model.paused ? "Return to the present" : "Hold this moment. Collection continues.")

            if let range = model.timeRange, range.upperBound - range.lowerBound >= 2 {
                Text("−" + ByteFormat.duration(range.upperBound - range.lowerBound))
                    .foregroundStyle(Color.dim)
                Slider(
                    value: Binding(
                        get: { model.scrubTime ?? range.upperBound },
                        set: { model.scrub(to: $0) }),
                    in: range)
                    .controlSize(.mini)
                    .accessibilityLabel("Timeline")
                    .accessibilityValue(model.paused ? "\(Int(range.upperBound - (model.scrubTime ?? range.upperBound))) seconds ago" : "live")
            } else {
                Text("history builds as the app runs").foregroundStyle(Color.dim)
                Spacer()
            }

            if let scrub = model.scrubTime, let range = model.timeRange {
                Text(Date(timeIntervalSince1970: model.displayedWallClock).formatted(date: .omitted, time: .standard))
                    .foregroundStyle(Color.caution)
                Text("−" + ByteFormat.duration(range.upperBound - scrub)).foregroundStyle(Color.caution)
                Button("LIVE") { model.goLive() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.signal)
                    .help("Return to the present")
            } else {
                Text("LIVE").foregroundStyle(Color.signal)
            }
        }
        .font(.mono(10, .semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color.panel)
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
                Menu {
                    Button("Save this filter") { model.saveCurrentFilter() }
                        .disabled(model.filterText.isEmpty || model.filterError != nil)
                    if !model.savedFilters.isEmpty {
                        Divider()
                        ForEach(model.savedFilters, id: \.self) { saved in
                            Button(saved) {
                                model.filterText = saved
                                model.applyFilter()
                            }
                        }
                        Divider()
                        Menu("Remove") {
                            ForEach(model.savedFilters, id: \.self) { saved in
                                Button(saved) { model.removeSavedFilter(saved) }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "star")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Saved filters")
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
            .overlay(alignment: .bottomLeading) {
                // Field names that complete the word being typed.
                if filterFocused, !model.filterSuggestions.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(model.filterSuggestions, id: \.self) { field in
                            Button(field) { model.complete(with: field) }
                                .buttonStyle(.plain)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.hairline)
                                .foregroundStyle(Color.signal)
                        }
                    }
                    .font(.mono(10))
                    .padding(4)
                    .background(Color.panel)
                    .overlay(Rectangle().strokeBorder(Color.hairline, lineWidth: 1))
                    .offset(y: 30)
                }
            }
            .zIndex(1)

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

            Toggle(isOn: Binding(get: { model.keepEnded }, set: { model.setKeepEnded($0) })) {
                Image(systemName: "clock.arrow.circlepath")
            }
            .toggleStyle(.button)
            .help("Keep ended connections on the graph, subdued, instead of letting them fade away (E)")
            .contextMenu {
                Button("Forget ended connections") { model.clearEnded() }
            }
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
