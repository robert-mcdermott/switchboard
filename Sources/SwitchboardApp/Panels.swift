import Charts
import SwiftUI
import SwitchboardCore
import SwitchboardRender
import SwitchboardStore

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
                case .ages: AgesPanel(model: model)
                case .firstSeen: FirstSeenPanel(model: model)
                case .trust: TrustPanel(model: model)
                case .log: LogPanel(model: model)
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
        TableColumn("Country", value: \.country) { (row: ConnectionRow) in Text(row.country.isEmpty ? "–" : row.country) }
            .width(60).customizationID("country").defaultVisibility(.hidden)
        TableColumn("Network owner", value: \.owner) { (row: ConnectionRow) in Text(row.owner.isEmpty ? "–" : row.owner) }
            .customizationID("owner").defaultVisibility(.hidden)
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
                    SectionTitle("Enrichment")
                    Text(model.geoStatus).foregroundStyle(Color.readout)
                    ForEach(model.tagProblems, id: \.self) { Text("Address lists: \($0)").foregroundStyle(Color.caution) }
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

/// Searches everything Switchboard has recorded, with the same filter as the live view.
struct LogPanel: View {
    @Bindable var model: AppModel
    @State private var moment = 0.0

    var body: some View {
        if !model.logAvailable {
            Text(model.logNote)
                .font(.mono(11))
                .foregroundStyle(Color.dim)
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Picker("Range", selection: $model.logRange) {
                        ForEach(LogRange.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                    Text(model.logBusy ? "Searching…" : model.logSummary).foregroundStyle(Color.readout)
                    Spacer()
                    Text("log holds \(model.logStats.flows) connections · \(ByteFormat.bytes(Double(model.logStats.bytesOnDisk)))")
                        .foregroundStyle(Color.dim)
                    Toggle("Leave out hostnames", isOn: $model.redactExports).toggleStyle(.checkbox)
                    Button("Export CSV") { model.exportLog(.csv) }
                    Button("Export JSONL") { model.exportLog(.jsonl) }
                    Button("Erase…") { model.purgeLog() }
                }
                .font(.mono(10))

                if let span = model.logSpan, !model.logHistogram.isEmpty {
                    Chart(Array(model.logHistogram.enumerated()), id: \.offset) { bucket in
                        BarMark(
                            x: .value("Time", Date(timeIntervalSince1970: span.lowerBound + (Double(bucket.offset) + 0.5) * (span.upperBound - span.lowerBound) / Double(model.logHistogram.count))),
                            y: .value("Connections", bucket.element))
                            .foregroundStyle(Color.signal.opacity(0.7))
                    }
                    .chartYAxis(.hidden)
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 8)) { _ in
                            AxisValueLabel(format: .dateTime.day().hour().minute()).font(.mono(9))
                        }
                    }
                    .frame(height: 54)

                    // Drag to see the graph as it was at that moment.
                    HStack(spacing: 8) {
                        Text("Show in graph").foregroundStyle(Color.dim)
                        Slider(value: $moment, in: span) { editing in
                            if !editing { model.showLogMoment(moment) }
                        }
                        .controlSize(.mini)
                        .accessibilityLabel("Moment to show from the log")
                        Text(Date(timeIntervalSince1970: moment).formatted(date: .abbreviated, time: .standard))
                            .foregroundStyle(model.logMoment == nil ? Color.dim : Color.caution)
                            .frame(width: 170, alignment: .trailing)
                    }
                    .font(.mono(10))
                    .onChange(of: span) { moment = span.upperBound }
                    .onAppear { moment = span.upperBound }
                }

                Table(model.logRows) {
                    TableColumn("Started") { Text($0.started.formatted(date: .abbreviated, time: .standard)) }.width(150)
                    TableColumn("Lasted") { row in
                        Text(row.ended == nil ? "open" : ByteFormat.duration(row.duration)).foregroundStyle(row.ended == nil ? Color.signal : Color.readout)
                    }
                    .width(70)
                    TableColumn("Process") { Text($0.process) }
                    TableColumn("PID") { Text(String($0.pid)) }.width(56)
                    TableColumn("Destination") { Text($0.remote) }
                    TableColumn("Port") { Text(String($0.port)) }.width(52)
                    TableColumn("Service") { Text($0.service) }.width(80)
                    TableColumn("↓ Total") { Text(ByteFormat.bytes($0.bytesIn)) }.width(76)
                    TableColumn("↑ Total") { Text(ByteFormat.bytes($0.bytesOut)) }.width(76)
                }
                .font(.mono(11))
                .scrollContentBackground(.hidden)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
        }
    }
}

/// Destinations this Mac had never talked to before this session.
struct FirstSeenPanel: View {
    @Bindable var model: AppModel

    var body: some View {
        if model.firstSeen.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Nothing new").font(.mono(12)).foregroundStyle(Color.readout)
                Text(model.logAvailable
                    ? "A destination is listed here, and ringed in the graph, the first time this Mac ever connects to it. That takes knowing what is normal, so nothing is flagged until the log has seen a couple of hundred destinations in earlier sessions."
                    : "First-seen tracking uses the log. \(model.logNote)")
                    .font(.mono(11))
                    .foregroundStyle(Color.dim)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            Table(model.firstSeen) {
                TableColumn("First seen") { Text($0.at.formatted(date: .omitted, time: .standard)) }.width(90)
                TableColumn("Address") { Text($0.address) }
                TableColumn("Hostname") { Text($0.host.isEmpty ? "–" : $0.host) }
                TableColumn("Process") { Text($0.process) }
            }
            .font(.mono(11))
            .scrollContentBackground(.hidden)
        }
    }
}

/// How long connections have been open, and which are old yet nearly silent.
struct AgesPanel: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle("Open connections by age")
                let top = max(model.ages.map(\.count).max() ?? 0, 1)
                ForEach(model.ages) { bucket in
                    HStack(spacing: 10) {
                        Text(bucket.label).foregroundStyle(Color.readout).frame(width: 110, alignment: .leading)
                        GeometryReader { geometry in
                            Rectangle().fill(Color.signal.opacity(0.75)).frame(width: geometry.size.width * CGFloat(bucket.count) / CGFloat(top))
                        }
                        .frame(height: 8)
                        Text("\(bucket.count)").foregroundStyle(Color.dim).frame(width: 50, alignment: .trailing)
                    }
                    .font(.mono(11))
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)

            Rectangle().fill(Color.hairline).frame(width: 1)

            VStack(alignment: .leading, spacing: 8) {
                SectionTitle("Open over an hour, under 100 KB")
                if model.lingering.isEmpty {
                    Text("None. A connection that stays open for hours while carrying almost nothing is worth a look; none match right now.")
                        .font(.mono(11))
                        .foregroundStyle(Color.dim)
                }
                ForEach(model.lingering) { row in
                    Button { model.select(row: row) } label: { ConnectionSummary(row: row) }.buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Programs on the network that Apple does not vouch for.
struct TrustPanel: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(summary).font(.mono(11)).foregroundStyle(Color.dim).padding(.horizontal, 12).padding(.top, 8)
            if !model.trust.isEmpty {
                Table(model.trust) {
                    TableColumn("Signature") { row in
                        Text(Self.label(row.signing)).foregroundStyle(row.signing == .adHoc ? Color.caution : Color.attention)
                    }
                    .width(110)
                    TableColumn("Process") { Text($0.process) }
                    TableColumn("PID") { Text(String($0.pid)) }.width(60)
                    TableColumn("Connections") { Text(String($0.connections)) }.width(90)
                    TableColumn("Path") { Text($0.path).truncationMode(.middle) }
                }
                .font(.mono(11))
                .scrollContentBackground(.hidden)
            } else {
                Spacer()
            }
        }
    }

    private var summary: String {
        if model.simulated { return "Signatures are not checked for simulated processes." }
        var text = model.trust.isEmpty
            ? "Every process on the network is signed by Apple or by an identified developer."
            : "\(model.trust.count) processes on the network are not signed by Apple or an identified developer. Ad hoc is normal for software you built yourself or installed with a package manager; unsigned and invalid deserve a look."
        if model.uncheckedProcesses > 0 { text += " \(model.uncheckedProcesses) not checked yet or not readable." }
        return text
    }

    static func label(_ status: SigningStatus) -> String {
        switch status {
        case .adHoc: "ad hoc"
        case .unsigned: "UNSIGNED"
        case .invalid: "INVALID"
        case .apple: "Apple"
        case .developerID: "developer"
        case .unknown: "unknown"
        }
    }
}
