import Charts
import SwiftUI
import SwitchboardCore
import SwitchboardRender

struct BottomPanel: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(PanelTab.allCases, id: \.self) { tab in
                    Button {
                        model.panelTab = tab
                    } label: {
                        Text(tab.title.uppercased())
                            .font(.mono(10, .semibold))
                            .kerning(1.2)
                            .foregroundStyle(model.panelTab == tab ? Color.signal : Color.dim)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(model.panelTab == tab ? Color.signal : .clear).frame(height: 1)
                            }
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Text(model.matchLine).font(.mono(10)).foregroundStyle(Color.dim).padding(.trailing, 12)
            }
            Rectangle().fill(Color.hairline).frame(height: 1)

            Group {
                switch model.panelTab {
                case .connections: ConnectionsPanel(model: model)
                case .talkers: TalkersPanel(model: model)
                case .throughput: ThroughputPanel(model: model)
                case .mix:
                    HStack(alignment: .top, spacing: 0) {
                        RankingList(title: "By service", talkers: model.services, color: .signal)
                        Rectangle().fill(Color.hairline).frame(width: 1)
                        RankingList(title: "By remote port", talkers: model.ports, color: .quic)
                    }
                case .interfaces:
                    RankingList(title: "By network interface", talkers: model.interfaces, color: .signal)
                case .dns: DNSPanel(model: model)
                case .listeners: ListenersPanel(model: model)
                case .health: HealthPanel(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.panel)
    }
}

struct ConnectionsPanel: View {
    @Bindable var model: AppModel
    @State private var selected: FlowID?
    @SceneStorage("connectionColumns") private var columns: TableColumnCustomization<ConnectionRow>

    private typealias Columns = TableColumnContent<ConnectionRow, KeyPathComparator<ConnectionRow>>

    var body: some View {
        VStack(spacing: 0) {
            Table(model.rows, selection: $selected, sortOrder: $model.sortOrder, columnCustomization: $columns) {
                whoColumns
                whereColumns
                stateColumns
                volumeColumns
                extraColumns
            }
            .font(.mono(11))
            .scrollContentBackground(.hidden)
            .onChange(of: selected) {
                guard let selected, let row = model.rows.first(where: { $0.id == selected }) else { return }
                model.select(row: row)
            }
            if model.totalMatching > model.rows.count {
                Text("Showing the busiest \(model.rows.count) of \(model.totalMatching). Narrow the filter to see the rest.")
                    .font(.mono(10))
                    .foregroundStyle(Color.caution)
                    .padding(6)
            }
        }
    }

    // The columns are declared in small groups: one long list is more than the compiler
    // will type-check, and a table builder takes at most ten at a time.

    @TableColumnBuilder<ConnectionRow, KeyPathComparator<ConnectionRow>>
    private var whoColumns: some Columns {
        TableColumn("Process", value: \.process) { (row: ConnectionRow) in Text(row.process) }
            .customizationID("process")
        TableColumn("PID", value: \.pid) { (row: ConnectionRow) in Text(String(row.pid)) }
            .width(56).customizationID("pid")
        TableColumn("User", value: \.user) { (row: ConnectionRow) in Text(row.user) }
            .width(80).customizationID("user")
    }

    @TableColumnBuilder<ConnectionRow, KeyPathComparator<ConnectionRow>>
    private var whereColumns: some Columns {
        TableColumn("Proto", value: \.proto) { (row: ConnectionRow) in Text(row.proto) }
            .width(44).customizationID("proto")
        TableColumn("Remote", value: \.remote) { (row: ConnectionRow) in Text(row.remote) }
            .customizationID("remote")
        TableColumn("Host", value: \.host) { (row: ConnectionRow) in
            // The badge says where the name came from: a DNS answer or a TLS handshake.
            Text(row.host.isEmpty ? "–" : "\(row.host)  \(row.hostSource)").foregroundStyle(row.host.isEmpty ? Color.dim : Color.readout)
        }
        .customizationID("host")
        TableColumn("Port", value: \.remotePort) { (row: ConnectionRow) in Text(String(row.remotePort)) }
            .width(52).customizationID("port")
        TableColumn("Service", value: \.service) { (row: ConnectionRow) in Text(row.service) }
            .width(80).customizationID("service")
    }

    @TableColumnBuilder<ConnectionRow, KeyPathComparator<ConnectionRow>>
    private var stateColumns: some Columns {
        TableColumn("State", value: \.state) { (row: ConnectionRow) in
            Text(row.state).foregroundStyle(row.state == "active" || row.state == "new" ? Color.signal : Color.dim)
        }
        .width(60).customizationID("state")
        TableColumn("Age", value: \.age) { (row: ConnectionRow) in
            Text((row.ageExact ? "" : "≥") + ByteFormat.duration(row.age))
        }
        .width(64).customizationID("age")
    }

    @TableColumnBuilder<ConnectionRow, KeyPathComparator<ConnectionRow>>
    private var volumeColumns: some Columns {
        TableColumn("↓ Rate", value: \.rateIn) { (row: ConnectionRow) in Text(ByteFormat.rate(row.rateIn)) }
            .width(84).customizationID("rateIn")
        TableColumn("↑ Rate", value: \.rateOut) { (row: ConnectionRow) in Text(ByteFormat.rate(row.rateOut)) }
            .width(84).customizationID("rateOut")
        TableColumn("↓ Total", value: \.bytesIn) { (row: ConnectionRow) in Text(ByteFormat.bytes(row.bytesIn)) }
            .width(76).customizationID("bytesIn")
        TableColumn("↑ Total", value: \.bytesOut) { (row: ConnectionRow) in Text(ByteFormat.bytes(row.bytesOut)) }
            .width(76).customizationID("bytesOut")
    }

    @TableColumnBuilder<ConnectionRow, KeyPathComparator<ConnectionRow>>
    private var extraColumns: some Columns {
        TableColumn("RTT", value: \.rtt) { (row: ConnectionRow) in
            Text(row.rtt < 0 ? "–" : String(format: "%.0f ms", row.rtt))
        }
        .width(60).customizationID("rtt")
        TableColumn("Interface", value: \.interface) { (row: ConnectionRow) in Text(row.interface) }
            .width(70).customizationID("interface").defaultVisibility(.hidden)
        TableColumn("Local port", value: \.localPort) { (row: ConnectionRow) in Text(String(row.localPort)) }
            .width(70).customizationID("localPort").defaultVisibility(.hidden)
    }
}

struct TalkersPanel: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            RankingList(title: "By process", talkers: model.talkers, color: .signal)
            Rectangle().fill(Color.hairline).frame(width: 1)
            RankingList(title: "By destination", talkers: model.destinations, color: .quic)
        }
    }
}

/// A ranked list with a bar per entry: rate, total, and connection count.
struct RankingList: View {
    let title: String
    let talkers: [Talker]
    let color: Color

    var body: some View {
        let top = max(talkers.map(\.rate).max() ?? 0, 1)
        return VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title)
            if talkers.isEmpty {
                Text("Nothing matches").font(.mono(11)).foregroundStyle(Color.dim)
            }
            ForEach(talkers) { talker in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(talker.name).foregroundStyle(Color.readout).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text("\(ByteFormat.rate(talker.rate)) · \(ByteFormat.bytes(talker.bytes)) · \(talker.connections)")
                            .foregroundStyle(Color.dim)
                    }
                    .font(.mono(11))
                    GeometryReader { geometry in
                        // Log scale, so a quiet talker is still visible beside a loud one.
                        let share = talker.rate <= 0 ? 0 : max(0.02, log10(1 + talker.rate) / log10(1 + top))
                        Rectangle().fill(color.opacity(0.75)).frame(width: geometry.size.width * share)
                    }
                    .frame(height: 3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ThroughputPanel: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                SectionTitle("All connections, last \(model.history.count) s")
                Label("received", systemImage: "square.fill").foregroundStyle(Color.signal)
                Label("sent", systemImage: "square.fill").foregroundStyle(Color.quic)
            }
            .font(.mono(10))
            Chart(model.history) { sample in
                AreaMark(x: .value("Time", sample.time), y: .value("Rate", sample.rateIn), series: .value("Direction", "in"))
                    .foregroundStyle(Color.signal.opacity(0.28))
                LineMark(x: .value("Time", sample.time), y: .value("Rate", sample.rateIn), series: .value("Direction", "in"))
                    .foregroundStyle(Color.signal)
                LineMark(x: .value("Time", sample.time), y: .value("Rate", sample.rateOut), series: .value("Direction", "out"))
                    .foregroundStyle(Color.quic)
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine().foregroundStyle(Color.hairline)
                    AxisValueLabel {
                        if let rate = value.as(Double.self) { Text(ByteFormat.rate(rate)).font(.mono(9)) }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                    AxisGridLine().foregroundStyle(Color.hairline)
                    AxisValueLabel(format: .dateTime.hour().minute().second()).font(.mono(9))
                }
            }
        }
        .padding(12)
    }
}

struct DNSPanel: View {
    @Bindable var model: AppModel

    var body: some View {
        if model.dns.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("No DNS answers seen").font(.mono(12)).foregroundStyle(Color.readout)
                Text(model.fullMode
                    ? "Lookups appear here as they happen. Apps that use encrypted DNS, such as most browsers, do not show up: their lookups cannot be read."
                    : "Reading DNS answers needs the collector, which captures packets as root. See the Health panel.")
                    .font(.mono(11))
                    .foregroundStyle(Color.dim)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            Table(model.dns) {
                TableColumn("Time") { Text($0.time.formatted(date: .omitted, time: .standard)) }.width(90)
                TableColumn("Name") { Text($0.name) }
                TableColumn("Resolved to") { Text($0.addresses) }
                TableColumn("Asked by") { Text($0.askedBy) }.width(180)
                TableColumn("Connections") { row in
                    Text(row.connections == 0 ? "–" : "\(row.connections)").foregroundStyle(row.connections == 0 ? Color.dim : Color.signal)
                }
                .width(90)
            }
            .font(.mono(11))
            .scrollContentBackground(.hidden)
        }
    }
}

struct ListenersPanel: View {
    @Bindable var model: AppModel

    var body: some View {
        Table(model.listeners) {
            TableColumn("Process") { Text($0.process) }
            TableColumn("PID") { Text("\($0.pid)") }.width(60)
            TableColumn("User") { Text($0.user) }.width(90)
            TableColumn("Proto") { Text($0.proto) }.width(50)
            TableColumn("Bound to") { Text($0.address) }
            TableColumn("Port") { Text("\($0.port)") }.width(60)
            TableColumn("Reach") { row in
                // Anything not bound to loopback can be reached from other machines.
                Text(row.exposed ? "EXPOSED" : "local only").foregroundStyle(row.exposed ? Color.caution : Color.dim)
            }
            .width(90)
        }
        .font(.mono(11))
        .scrollContentBackground(.hidden)
    }
}

struct HealthPanel: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    SectionTitle("Mode")
                    Text(model.modeLine).foregroundStyle(Color.readout)
                    if model.fullMode {
                        Text("The collector is running as root and reports every account's connections. The app switched to it automatically and will fall back to Standalone if it stops.")
                            .foregroundStyle(Color.dim)
                    } else if !model.simulated, getuid() != 0 {
                        Text("Standalone mode shows connections made by your own processes. System daemons and other accounts are not shown; that needs the root collector, which is not built yet.")
                            .foregroundStyle(Color.dim)
                        Text("Around one in twenty of your own connections is also withheld by macOS from unprivileged tools. The cause is not yet known.")
                            .foregroundStyle(Color.dim)
                        HStack(spacing: 10) {
                            Text("To see everything, install the collector. In Terminal, from the Switchboard folder:")
                                .foregroundStyle(Color.dim)
                            Text("sudo scripts/install.sh").foregroundStyle(Color.signal).textSelection(.enabled)
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString("sudo scripts/install.sh", forType: .string)
                            }
                        }
                        Text("Switchboard never asks for your password itself. The app notices the collector within a couple of seconds of it starting.")
                            .foregroundStyle(Color.dim)
                    }
                }
                if !model.simulated, !model.fullMode, getuid() != 0 {
                    VStack(alignment: .leading, spacing: 4) {
                        SectionTitle("What is not shown")
                        HStack(spacing: 10) {
                            Button(model.scanning ? "Scanning…" : "Scan all accounts once") { model.scanAllUsers() }
                                .disabled(model.scanning)
                            Text("Takes about three seconds and uses a full CPU core while it runs.")
                                .foregroundStyle(Color.dim)
                        }
                        if let scan = model.scan {
                            Text("\(scan.sockets) sockets belonging to other accounts were open at \(scan.taken.formatted(date: .omitted, time: .standard)):")
                                .foregroundStyle(Color.readout)
                            ForEach(scan.processes) { process in
                                Text("  \(process.name) — \(process.connections) sockets, \(ByteFormat.bytes(process.bytes))")
                                    .foregroundStyle(Color.dim)
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    SectionTitle("Sources")
                    ForEach(model.summary.sources, id: \.self) { line in
                        Text(line).foregroundStyle(model.summary.healthy ? Color.readout : Color.attention)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    SectionTitle("Engine")
                    Text("\(model.summary.flows) connections · \(model.summary.listeners) listening sockets (\(model.summary.exposed) exposed) · \(model.summary.processes) processes")
                        .foregroundStyle(Color.readout)
                }
                VStack(alignment: .leading, spacing: 4) {
                    SectionTitle("Display")
                    Text(String(
                        format: "%.0f frames/s · slowest 1%% of frames %.1f ms · GPU %.1f ms · %d nodes · %d lines",
                        model.frames.framesPerSecond, model.frames.p99IntervalMS, model.frames.meanGPUMS,
                        model.session.nodeCount, model.session.edgeCount))
                        .foregroundStyle(Color.readout)
                    if let info = model.session.rendererInfo {
                        Text("\(info.deviceName) · shaders compiled in \(Int(info.shaderCompileMS)) ms")
                            .foregroundStyle(Color.dim)
                    }
                }
            }
            .font(.mono(11))
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
