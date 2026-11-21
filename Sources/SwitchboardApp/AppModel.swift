import AppKit
import Observation
import SwitchboardCore
import SwitchboardRender
import SwitchboardSources

/// One connection, flattened for tables.
struct ConnectionRow: Identifiable, Sendable {
    let id: FlowID
    var process: String
    var pid: Int
    var user: String
    var proto: String
    var remote: String
    var remotePort: Int
    var localPort: Int
    var service: String
    var state: String
    var age: Double
    var ageExact: Bool
    var rateIn: Double
    var rateOut: Double
    var bytesIn: Double
    var bytesOut: Double
    /// Milliseconds, or -1 when there is no measurement.
    var rtt: Double
    var interface: String
    var target: PickTarget

    init(_ flow: Flow, process record: ProcessRecord?, now: EngineTime) {
        id = flow.id
        process = record?.name ?? "pid \(flow.pid)"
        pid = Int(flow.pid)
        user = record?.username ?? "–"
        proto = flow.key.proto.rawValue
        remote = flow.key.remote.address.description
        remotePort = Int(flow.key.remote.port)
        localPort = Int(flow.key.local.port)
        service = flow.service ?? "–"
        state = flow.state.rawValue
        age = flow.age(at: now)
        ageExact = flow.ageExact
        rateIn = flow.rateIn
        rateOut = flow.rateOut
        bytesIn = Double(flow.bytesIn)
        bytesOut = Double(flow.bytesOut)
        rtt = flow.rttMS ?? -1
        interface = flow.interface ?? "–"
        target = flow.key.remote.address.isLoopback
            ? .node(.process(flow.pid)) : .edge(.process(flow.pid), .endpoint(flow.key.remote.address))
    }
}

struct ListenerRow: Identifiable, Sendable {
    let id: FlowID
    var process: String
    var pid: Int
    var user: String
    var proto: String
    var address: String
    var port: Int
    var exposed: Bool
}

struct Talker: Identifiable, Sendable {
    var id: String
    var name: String
    var rate: Double
    var bytes: Double
    var connections: Int
}

struct ThroughputSample: Identifiable, Sendable {
    var id: Int
    var time: Date
    var rateIn: Double
    var rateOut: Double
}

enum PanelTab: String, CaseIterable, Sendable {
    case connections, talkers, throughput, listeners, health

    var title: String {
        switch self {
        case .connections: "Connections"
        case .talkers: "Top Talkers"
        case .throughput: "Throughput"
        case .listeners: "Listening"
        case .health: "Health"
        }
    }
}

@MainActor
@Observable
final class AppModel {
    let session: GraphSession
    let sourceSpec: String
    /// When set, the app measures itself for a few seconds, writes a report here, and quits.
    let measurePath: String?

    var summary = LiveFeed.Summary()
    var frames = FrameStats.Summary()
    var hover: HoverInfo?
    var hoverPoint: CGPoint = .zero
    var paused = false
    var profile: RenderProfile
    var failure: String?
    var simulated = false

    // Console state.
    var filterText = ""
    var filterError: String?
    private(set) var filter = FlowFilter.all
    var showInspector = true
    var showPanel = true
    var panelTab = PanelTab.connections
    var selection: PickTarget?
    var focused = false
    /// Bumped to ask the filter field to take the keyboard.
    var filterFocusRequests = 0

    // Derived from the latest snapshot, once a second.
    private(set) var rows: [ConnectionRow] = []
    private(set) var totalMatching = 0
    private(set) var totalFlows = 0
    private(set) var listeners: [ListenerRow] = []
    private(set) var talkers: [Talker] = []
    private(set) var destinations: [Talker] = []
    private(set) var history: [ThroughputSample] = []
    private(set) var inspector: HoverInfo?
    private(set) var inspectorRows: [ConnectionRow] = []
    var sortOrder = [KeyPathComparator(\ConnectionRow.rateIn, order: .reverse)] {
        didSet { rows.sort(using: sortOrder) }
    }

    /// Tables stop at this many rows; the filter narrows beyond that.
    static let rowLimit = 1500

    @ObservationIgnored private var snapshot: EngineSnapshot?
    @ObservationIgnored private var feed: LiveFeed?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var sampleCount = 0

    init() {
        let arguments = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        sourceSpec = value("--source") ?? "nstat"
        measurePath = value("--measure")

        // Respect the system setting: no motion unless the user has said otherwise.
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let stored = UserDefaults.standard.string(forKey: "profile").flatMap(RenderProfile.init(rawValue:))
        profile = value("--profile").flatMap(RenderProfile.init(rawValue:)) ?? stored ?? (reduceMotion ? .still : .cinema)

        let hostName = Host.current().localizedName ?? "This Mac"
        let controller = GraphController(hostLabel: hostName.uppercased())
        session = GraphSession(controller: controller)
        session.profile = profile
        if measurePath != nil { session.capture = FrameCapture() }

        if arguments.contains("--no-inspector") { showInspector = false }
        if arguments.contains("--no-panel") { showPanel = false }
        if let tab = value("--panel").flatMap(PanelTab.init(rawValue:)) { panelTab = tab }

        session.onHover = { [weak self] info, point in
            self?.hover = info
            self?.hoverPoint = point
        }
        session.onFailure = { [weak self] message in self?.failure = message }
        session.onSelect = { [weak self] target in self?.select(target, fromGraph: true) }
        session.onContext = { [weak self] action, target in self?.perform(action, on: target) }
        session.onKey = { [weak self] key in
            guard let self else { return }
            switch key {
            case .togglePause: togglePause()
            case .cycleProfile: setProfile(profile.next)
            case .resetView: break
            case .focusFilter: filterFocusRequests += 1
            case .toggleInspector: showInspector.toggle()
            case .togglePanel: showPanel.toggle()
            case .escape: focused = false
            }
        }

        do {
            let epoch = CACurrentMediaTime()
            let feed = try LiveFeed(
                spec: sourceSpec, flows: value("--flows").flatMap(Int.init), controller: controller,
                clock: { Float(CACurrentMediaTime() - epoch) },
                onSummary: { [weak self] summary in
                    Task { @MainActor in self?.summary = summary }
                },
                onSnapshot: { [weak self] snapshot in
                    Task { @MainActor in self?.receive(snapshot) }
                })
            simulated = feed.simulated
            self.feed = feed
            feed.start()
            feed.setForeground(NSApplication.shared.isActive)
        } catch {
            failure = "\(error)"
        }

        if let text = value("--filter") {
            filterText = text
            applyFilter()
        }
        if let select = value("--select") {
            if select == "host" {
                selection = .node(.host)
            } else if select.hasPrefix("process:"), let pid = Int32(select.dropFirst(8)) {
                selection = .node(.process(pid))
            }
            session.selection = selection
        }

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.feed?.setForeground(true) }
        })
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.feed?.setForeground(false) }
        })
    }

    // MARK: - Actions

    func togglePause() {
        paused.toggle()
        session.controller.paused = paused
    }

    func setProfile(_ next: RenderProfile) {
        profile = next
        session.profile = next
        UserDefaults.standard.set(next.rawValue, forKey: "profile")
    }

    /// Parses the filter field. A filter that does not parse is reported and the last
    /// good one stays in force, so a half-typed filter never blanks the display.
    func applyFilter() {
        do {
            let parsed = try FlowFilter(filterText)
            filter = parsed
            filterError = nil
            session.controller.filter = parsed
            derive()
        } catch {
            filterError = error.message
        }
    }

    func clearFilter() {
        filterText = ""
        applyFilter()
    }

    func select(_ target: PickTarget?, fromGraph: Bool = false) {
        selection = target
        if !fromGraph { session.selection = target }
        focused = session.controller.focus != nil
        if target != nil { showInspector = true }
        deriveInspector()
    }

    func clearFocus() {
        session.controller.focus = nil
        focused = false
    }

    private func perform(_ action: GraphSession.ContextAction, on target: PickTarget) {
        switch action {
        case .filterToThis:
            switch target {
            case .node(.process(let pid)), .edge(.host, .process(let pid)): filterText = "pid=\(pid)"
            case .node(.endpoint(let address)): filterText = "remote=\(address)"
            case .edge(.process(let pid), .endpoint(let address)): filterText = "pid=\(pid) remote=\(address)"
            default: filterText = ""
            }
            applyFilter()
        case .focusOnThis:
            focused = true
        case .copyDetails:
            guard let info = session.controller.info(for: target) else { return }
            let text = ([info.title, info.subtitle] + info.rows.map { "\($0.label): \($0.value)" }).joined(separator: "\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case .revealInFinder:
            guard case .node(.process(let pid)) = target, let path = session.controller.process(pid)?.path else { return }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }

    // MARK: - Derived state

    func refresh() {
        frames = session.stats.summary()
        focused = session.controller.focus != nil
    }

    private func receive(_ snapshot: EngineSnapshot) {
        // While paused the tables hold still with the graph.
        guard !paused else { return }
        self.snapshot = snapshot
        var rateIn = 0.0, rateOut = 0.0
        for flow in snapshot.flows where flow.state != .closed {
            rateIn += flow.rateIn
            rateOut += flow.rateOut
        }
        sampleCount += 1
        history.append(ThroughputSample(id: sampleCount, time: Date(), rateIn: rateIn, rateOut: rateOut))
        if history.count > 300 { history.removeFirst(history.count - 300) }
        derive()
    }

    private func derive() {
        guard let snapshot else { return }
        let processes = Dictionary(uniqueKeysWithValues: snapshot.processes.map { ($0.pid, $0) })
        let open = snapshot.flows.filter { $0.state != .closed }
        totalFlows = open.count
        let matching = filter.isEmpty
            ? open : open.filter { filter.matches($0, process: processes[$0.pid], now: snapshot.time) }
        totalMatching = matching.count

        var all = matching.map { ConnectionRow($0, process: processes[$0.pid], now: snapshot.time) }
        if all.count > Self.rowLimit {
            // Keep the busiest; the filter is the way to see the rest.
            all.sort { ($0.rateIn + $0.rateOut, $0.bytesIn + $0.bytesOut) > ($1.rateIn + $1.rateOut, $1.bytesIn + $1.bytesOut) }
            all.removeSubrange(Self.rowLimit...)
        }
        all.sort(using: sortOrder)
        rows = all

        func rank(_ groups: [String: [Flow]], name: (String) -> String) -> [Talker] {
            groups.map { key, flows in
                Talker(
                    id: key, name: name(key), rate: flows.reduce(0) { $0 + $1.rateTotal },
                    bytes: flows.reduce(0) { $0 + Double($1.bytesTotal) }, connections: flows.count)
            }
            .sorted { ($0.rate, $0.bytes) > ($1.rate, $1.bytes) }
            .prefix(10).map { $0 }
        }
        talkers = rank(Dictionary(grouping: matching) { "\($0.pid)" }) { key in
            processes[Int32(key) ?? 0]?.name ?? "pid \(key)"
        }
        destinations = rank(Dictionary(grouping: matching.filter { !$0.key.remote.address.isLoopback }) {
            $0.key.remote.address.description
        }) { $0 }

        listeners = snapshot.listeners.map { listener in
            let record = processes[listener.pid]
            return ListenerRow(
                id: listener.id, process: record?.name ?? "pid \(listener.pid)", pid: Int(listener.pid),
                user: record?.username ?? "–", proto: listener.proto.rawValue,
                address: listener.local.address.isUnspecified ? "any address" : listener.local.address.description,
                port: Int(listener.local.port), exposed: listener.exposed)
        }
        .sorted { ($0.exposed ? 0 : 1, $0.process, $0.port) < ($1.exposed ? 0 : 1, $1.process, $1.port) }

        deriveInspector()
    }

    private func deriveInspector() {
        guard let selection, let snapshot else {
            inspector = nil
            inspectorRows = []
            return
        }
        inspector = session.controller.info(for: selection)
        let processes = Dictionary(uniqueKeysWithValues: snapshot.processes.map { ($0.pid, $0) })
        inspectorRows = session.controller.flows(for: selection)
            .sorted { ($0.rateTotal, $0.bytesTotal) > ($1.rateTotal, $1.bytesTotal) }
            .prefix(200)
            .map { ConnectionRow($0, process: processes[$0.pid], now: snapshot.time) }
    }

    // MARK: - Text for the chrome

    var statusLine: String {
        "\(summary.flows) connections · ↓ \(ByteFormat.rate(summary.rateIn)) ↑ \(ByteFormat.rate(summary.rateOut))"
    }

    /// Standalone shows the login user's processes only; say so rather than imply more.
    var modeLine: String {
        if simulated { return "SIMULATED · \(sourceSpec)" }
        return getuid() == 0 ? "STANDALONE · all users" : "STANDALONE · your processes"
    }

    var matchLine: String {
        filter.isEmpty ? "\(totalFlows) connections" : "\(totalMatching) of \(totalFlows) match"
    }

    /// Facts about a run, gathered from inside the app, for measurement and screenshots.
    func writeMeasurement(to path: String, measured: FrameStats.Summary) {
        let processStart = ProcessTable.bsdInfo(of: getpid()).map {
            Double($0.pbi_start_tvsec) + Double($0.pbi_start_tvusec) / 1e6
        }
        let firstData = session.firstDataFrame?.timeIntervalSince1970
        let report: [String: Any] = [
            "version": Switchboard.version,
            "source": sourceSpec,
            "profile": profile.rawValue,
            "device": session.rendererInfo?.deviceName ?? "",
            "resourceOrigin": session.rendererInfo?.resourceOrigin.rawValue ?? "",
            "shaderCompileMS": session.rendererInfo?.shaderCompileMS ?? -1,
            "failure": failure ?? "",
            "filter": filter.text,
            "filterError": filterError ?? "",
            "nodes": session.nodeCount,
            "edges": session.edgeCount,
            "flows": summary.flows,
            "rows": rows.count,
            "matching": totalMatching,
            "listeners": listeners.count,
            "talkers": talkers.map(\.name),
            "inspectorTitle": inspector?.title ?? "",
            "inspectorRows": inspectorRows.count,
            "launchToFirstDataSeconds": (processStart != nil && firstData != nil) ? firstData! - processStart! : -1,
            "windowPixels": NSApplication.shared.windows.first { $0.title == "Switchboard" }.map {
                let size = $0.convertToBacking($0.contentLayoutRect).size
                return "\(Int(size.width))x\(Int(size.height))"
            } ?? "",
            "frames": measured.frames,
            "fps": measured.framesPerSecond,
            "medianIntervalMS": measured.medianIntervalMS,
            "p99IntervalMS": measured.p99IntervalMS,
            "worstIntervalMS": measured.worstIntervalMS,
            "meanGPUMS": measured.meanGPUMS,
            "p99GPUMS": measured.p99GPUMS,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
