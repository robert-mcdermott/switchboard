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
    var key: FlowKey

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
        key = flow.key
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
    case connections, talkers, throughput, mix, interfaces, listeners, health

    var title: String {
        switch self {
        case .connections: "Connections"
        case .talkers: "Top Talkers"
        case .throughput: "Throughput"
        case .mix: "Protocols"
        case .interfaces: "Interfaces"
        case .listeners: "Listening"
        case .health: "Health"
        }
    }
}

/// What a one-off scan with `nettop` found beyond what Standalone mode shows.
struct ScanResult: Sendable {
    var sockets: Int
    var processes: [Talker]
    var taken: Date
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
    var profile: RenderProfile
    var failure: String?
    var simulated = false

    // Console state.
    var filterText = ""
    var filterError: String?
    private(set) var filter = FlowFilter.all
    var showInspector = true
    var showPanel = true { didSet { derive() } }
    var panelTab = PanelTab.connections { didSet { derive() } }
    /// Everything pinned in the inspector. ⌘-click adds to it.
    var selection = Set<PickTarget>()
    var focused = false
    /// Ended connections stay on the graph, subdued, instead of fading away.
    private(set) var keepEnded = UserDefaults.standard.bool(forKey: "keepEnded")
    private(set) var endedCount = 0

    // Time: `nil` means the present.
    private(set) var scrubTime: EngineTime?
    private(set) var timeRange: ClosedRange<EngineTime>?
    private(set) var displayedWallClock: Double = 0
    var paused: Bool { scrubTime != nil }

    var savedFilters: [String] = UserDefaults.standard.stringArray(forKey: "savedFilters") ?? []
    private(set) var scan: ScanResult?
    private(set) var scanning = false
    /// Bumped to ask the filter field to take the keyboard.
    var filterFocusRequests = 0

    // Derived from the latest snapshot, once a second.
    private(set) var rows: [ConnectionRow] = []
    private(set) var totalMatching = 0
    private(set) var totalFlows = 0
    private(set) var listeners: [ListenerRow] = []
    private(set) var talkers: [Talker] = []
    private(set) var destinations: [Talker] = []
    private(set) var services: [Talker] = []
    private(set) var ports: [Talker] = []
    private(set) var interfaces: [Talker] = []
    private(set) var history: [ThroughputSample] = []
    private(set) var inspector: HoverInfo?
    private(set) var inspectorRows: [ConnectionRow] = []
    var sortOrder = [KeyPathComparator(\ConnectionRow.rateIn, order: .reverse)] {
        didSet { rows.sort(using: sortOrder) }
    }

    /// Tables stop at this many rows; the filter narrows beyond that.
    nonisolated static let rowLimit = 1500

    /// The model the tables are showing: the present, or the moment being scrubbed to.
    @ObservationIgnored private var snapshot: EngineSnapshot?
    @ObservationIgnored private var latest: EngineSnapshot?
    @ObservationIgnored private var window = TimeWindow()
    @ObservationIgnored private var feed: LiveFeed?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var sampleCount = 0
    @ObservationIgnored private var scrubRequest: Double?
    @ObservationIgnored private var derivation = 0

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
        session.onSelect = { [weak self] target, extend in self?.select(target, extend: extend) }
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
            case .toggleKeepEnded: setKeepEnded(!keepEnded)
            }
        }
        applySettings()
        if arguments.contains("--keep-ended") { keepEnded = true }
        controller.keepsEnded = keepEnded

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
            for part in select.split(separator: ",") {
                if part == "host" {
                    selection.insert(.node(.host))
                } else if part.hasPrefix("process:"), let pid = Int32(part.dropFirst(8)) {
                    selection.insert(.node(.process(pid)))
                }
            }
            session.selection = selection
        }
        if let mode = value("--clustering") { applyClustering(mode, threshold: 300) }
        if let scheme = value("--palette").flatMap(PaletteScheme.init(rawValue:)) { controller.palette = scheme }
        scrubRequest = value("--scrub-back").flatMap(Double.init)
        if arguments.contains("--scan") { scanAllUsers() }

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.feed?.setForeground(true) }
        })
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.feed?.setForeground(false) }
        })
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.applySettings() }
        })
    }

    // MARK: - Actions

    func setKeepEnded(_ on: Bool) {
        keepEnded = on
        session.controller.keepsEnded = on
        UserDefaults.standard.set(on, forKey: "keepEnded")
        endedCount = session.controller.endedCount
        deriveInspector()
    }

    func clearEnded() {
        session.controller.clearEnded()
        endedCount = 0
        deriveInspector()
    }

    /// Pausing is scrubbing to this moment and staying there.
    func togglePause() {
        if scrubTime != nil { goLive() } else if let now = timeRange?.upperBound { scrub(to: now) }
    }

    /// Shows the moment `time` on the graph and in every table.
    func scrub(to time: EngineTime) {
        guard let moment = window.snapshot(at: time) else { return }
        scrubTime = moment.time
        snapshot = moment
        displayedWallClock = moment.wallClock
        session.controller.hold(moment)
        derive()
    }

    func goLive() {
        scrubTime = nil
        snapshot = latest
        displayedWallClock = latest?.wallClock ?? 0
        session.controller.hold(nil)
        derive()
    }

    /// Reads the Settings window's choices and applies them.
    func applySettings() {
        let defaults = UserDefaults.standard
        let threshold = defaults.object(forKey: "clusterThreshold") as? Int ?? 300
        applyClustering(defaults.string(forKey: "clustering") ?? "automatic", threshold: threshold)
        session.controller.palette = defaults.string(forKey: "palette").flatMap(PaletteScheme.init(rawValue:)) ?? .standard
        let minutes = defaults.object(forKey: "historyMinutes") as? Double ?? 15
        window.maximumAge = max(minutes, 1) * 60
    }

    private func applyClustering(_ mode: String, threshold: Int) {
        switch mode {
        case "off": session.controller.clustering = .off
        case "subnet": session.controller.clustering = .subnet
        default: session.controller.clustering = .automatic(threshold: max(threshold, 10))
        }
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

    /// Pins `target`. With `extend`, adds it to what is already pinned, or removes it if
    /// it was; without, it replaces the selection, and `nil` clears it.
    func select(_ target: PickTarget?, extend: Bool = false) {
        if let target {
            if extend {
                if selection.contains(target) { selection.remove(target) } else { selection.insert(target) }
            } else {
                selection = [target]
            }
            showInspector = true
        } else if !extend {
            selection = []
        }
        session.selection = selection
        focused = session.controller.focus != nil
        deriveInspector()
    }

    func select(row: ConnectionRow) {
        select(session.controller.target(pid: Int32(row.pid), remote: row.key.remote, proto: row.key.proto))
    }

    static func filterText(for target: PickTarget) -> String? {
        switch target {
        case .node(.process(let pid)), .edge(.host, .process(let pid)): "pid=\(pid)"
        case .node(.endpoint(let address)): "remote=\(address)"
        case .node(.network(let address, let bits)): "remote:\(address)/\(bits)"
        case .edge(.process(let from), .process): "pid=\(from) remote:127.0.0.0/8"
        case .edge(.process(let pid), .endpoint(let address)): "pid=\(pid) remote=\(address)"
        case .edge(.process(let pid), .network(let address, let bits)): "pid=\(pid) remote:\(address)/\(bits)"
        default: nil
        }
    }

    /// Narrows everything to the selection. Several items are joined with OR.
    func filterToSelection() {
        let parts = selection.compactMap(Self.filterText(for:)).sorted()
        guard !parts.isEmpty else { return }
        filterText = parts.count == 1 ? parts[0] : parts.map { "(\($0))" }.joined(separator: " OR ")
        applyFilter()
    }

    func toggleFocusOnSelection() {
        if session.controller.focus != nil {
            clearFocus()
        } else if let first = selection.first {
            session.controller.focus = first
            focused = true
        }
    }

    // MARK: - Saved filters and completion

    func saveCurrentFilter() {
        let text = filterText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, filterError == nil, !savedFilters.contains(text) else { return }
        savedFilters.append(text)
        UserDefaults.standard.set(savedFilters, forKey: "savedFilters")
    }

    func removeSavedFilter(_ text: String) {
        savedFilters.removeAll { $0 == text }
        UserDefaults.standard.set(savedFilters, forKey: "savedFilters")
    }

    /// Field names that complete the word being typed.
    var filterSuggestions: [String] {
        guard let last = filterText.split(separator: " ", omittingEmptySubsequences: false).last, !last.isEmpty,
              !last.contains(where: { ":=<>!\"(".contains($0) })
        else { return [] }
        let typed = last.lowercased()
        let names = FlowFilter.fields.map(\.name)
        guard !names.contains(typed) else { return [] }
        return Array(names.filter { $0.hasPrefix(typed) }.prefix(6))
    }

    func complete(with field: String) {
        var words = filterText.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard !words.isEmpty else { return }
        words[words.count - 1] = field + ":"
        filterText = words.joined(separator: " ")
        filterFocusRequests += 1
    }

    // MARK: - Scanning beyond Standalone

    /// Runs `nettop` once to count the sockets Standalone mode cannot show. `nettop` is
    /// Apple-signed and sees every account, but costs more than a CPU core while it runs,
    /// so this is a deliberate one-off rather than something left on.
    func scanAllUsers() {
        guard !scanning, !simulated else { return }
        scanning = true
        let me = getuid()
        Task.detached(priority: .utility) {
            let source = NettopSource()
            var seen: [UInt64: SocketObservation] = [:]
            if (try? source.start()) != nil {
                for _ in 0..<12 {
                    try? await Task.sleep(for: .milliseconds(250))
                    for case .seen(let observation) in source.poll(now: 0) { seen[observation.sourceID] = observation }
                }
                source.stop()
            }
            var owners: [Int32: Bool] = [:]
            var groups: [String: (sockets: Int, bytes: Double)] = [:]
            var hidden = 0
            for observation in seen.values {
                let mine = owners[observation.pid] ?? (ProcessTable.basicInfo(of: observation.pid)?.uid == me)
                owners[observation.pid] = mine
                guard !mine else { continue }
                hidden += 1
                var group = groups[observation.processName] ?? (0, 0)
                group.sockets += 1
                group.bytes += Double(observation.rxBytes + observation.txBytes)
                groups[observation.processName] = group
            }
            let processes = groups.map { Talker(id: $0.key, name: $0.key, rate: 0, bytes: $0.value.bytes, connections: $0.value.sockets) }
                .sorted { ($0.connections, $0.bytes) > ($1.connections, $1.bytes) }
            let result = ScanResult(sockets: hidden, processes: Array(processes.prefix(12)), taken: Date())
            await MainActor.run {
                self.scan = result
                self.scanning = false
            }
        }
    }

    func clearFocus() {
        session.controller.focus = nil
        focused = false
    }

    private func perform(_ action: GraphSession.ContextAction, on target: PickTarget) {
        switch action {
        case .filterToThis:
            filterText = Self.filterText(for: target) ?? ""
            applyFilter()
        case .focusOnThis:
            focused = true
        case .toggleCluster:
            deriveInspector()
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
        endedCount = keepEnded ? session.controller.endedCount : 0
    }

    private func receive(_ snapshot: EngineSnapshot) {
        latest = snapshot
        window.append(snapshot)
        timeRange = window.range
        if let back = scrubRequest, snapshot.time > back + 2 {
            // For screenshots: jump back once there is enough history to jump into.
            scrubRequest = nil
            scrub(to: snapshot.time - back)
        }
        var rateIn = 0.0, rateOut = 0.0
        for flow in snapshot.flows where flow.state != .closed {
            rateIn += flow.rateIn
            rateOut += flow.rateOut
        }
        sampleCount += 1
        history.append(ThroughputSample(id: sampleCount, time: Date(), rateIn: rateIn, rateOut: rateOut))
        if history.count > 300 { history.removeFirst(history.count - 300) }
        // While the past is on screen, the tables stay with it.
        guard scrubTime == nil else { return }
        self.snapshot = snapshot
        displayedWallClock = snapshot.wallClock
        derive()
    }

    /// Everything the panels show, worked out from one snapshot.
    private struct Derived: Sendable {
        var rows: [ConnectionRow] = []
        var totalMatching = 0
        var totalFlows = 0
        var listeners: [ListenerRow] = []
        var talkers: [Talker] = []
        var destinations: [Talker] = []
        var services: [Talker] = []
        var ports: [Talker] = []
        var interfaces: [Talker] = []

        /// Runs off the main thread: on a busy machine this is tens of milliseconds, and
        /// on the main thread that is a dropped frame every second.
        static func make(_ snapshot: EngineSnapshot, filter: FlowFilter, rowLimit: Int, wantRows: Bool) -> Derived {
            var derived = Derived()
            let processes = Dictionary(uniqueKeysWithValues: snapshot.processes.map { ($0.pid, $0) })
            let open = snapshot.flows.filter { $0.state != .closed }
            derived.totalFlows = open.count
            let matching = filter.isEmpty
                ? open : open.filter { filter.matches($0, process: processes[$0.pid], now: snapshot.time) }
            derived.totalMatching = matching.count

            if wantRows {
                // Keep the busiest; the filter is the way to see the rest.
                let busiest = matching.count > rowLimit
                    ? Array(matching.sorted { ($0.rateTotal, $0.bytesTotal) > ($1.rateTotal, $1.bytesTotal) }.prefix(rowLimit))
                    : matching
                derived.rows = busiest.map { ConnectionRow($0, process: processes[$0.pid], now: snapshot.time) }
            }

            func rank(_ groups: [String: [Flow]], name: (String) -> String) -> [Talker] {
                groups.map { key, flows in
                    Talker(
                        id: key, name: name(key), rate: flows.reduce(0) { $0 + $1.rateTotal },
                        bytes: flows.reduce(0) { $0 + Double($1.bytesTotal) }, connections: flows.count)
                }
                .sorted { ($0.rate, $0.bytes, $0.id) > ($1.rate, $1.bytes, $1.id) }
                .prefix(10).map { $0 }
            }
            derived.talkers = rank(Dictionary(grouping: matching) { "\($0.pid)" }) { key in
                processes[Int32(key) ?? 0]?.name ?? "pid \(key)"
            }
            derived.destinations = rank(Dictionary(grouping: matching.filter { !$0.key.remote.address.isLoopback }) {
                $0.key.remote.address.description
            }) { $0 }
            derived.services = rank(Dictionary(grouping: matching) { $0.service ?? "unidentified" }) { $0 }
            derived.ports = rank(Dictionary(grouping: matching) { "\($0.key.proto.rawValue)/\($0.key.remote.port)" }) { $0 }
            derived.interfaces = rank(Dictionary(grouping: matching) { $0.interface ?? "unknown" }) { $0 }

            derived.listeners = snapshot.listeners.map { listener in
                let record = processes[listener.pid]
                return ListenerRow(
                    id: listener.id, process: record?.name ?? "pid \(listener.pid)", pid: Int(listener.pid),
                    user: record?.username ?? "–", proto: listener.proto.rawValue,
                    address: listener.local.address.isUnspecified ? "any address" : listener.local.address.description,
                    port: Int(listener.local.port), exposed: listener.exposed)
            }
            .sorted { ($0.exposed ? 0 : 1, $0.process, $0.port) < ($1.exposed ? 0 : 1, $1.process, $1.port) }
            return derived
        }
    }

    private func derive() {
        guard let snapshot else { return }
        derivation += 1
        let generation = derivation
        let filter = self.filter
        // Rows are only built when the table that shows them is on screen.
        let wantRows = showPanel && panelTab == .connections
        Task.detached(priority: .userInitiated) { [weak self] in
            let derived = Derived.make(snapshot, filter: filter, rowLimit: Self.rowLimit, wantRows: wantRows)
            await self?.apply(derived, generation: generation, wantRows: wantRows)
        }
    }

    private func apply(_ derived: Derived, generation: Int, wantRows: Bool) {
        // A newer snapshot or filter has overtaken this one.
        guard generation == derivation else { return }
        totalFlows = derived.totalFlows
        totalMatching = derived.totalMatching
        if wantRows {
            var sorted = derived.rows
            sorted.sort(using: sortOrder)
            rows = sorted
        }
        talkers = derived.talkers
        destinations = derived.destinations
        services = derived.services
        ports = derived.ports
        interfaces = derived.interfaces
        listeners = derived.listeners
        deriveInspector()
    }

    private func deriveInspector() {
        guard !selection.isEmpty, let snapshot else {
            inspector = nil
            inspectorRows = []
            return
        }
        let controller = session.controller
        let processes = Dictionary(uniqueKeysWithValues: snapshot.processes.map { ($0.pid, $0) })
        var flows: [FlowID: Flow] = [:]
        for target in selection {
            for flow in controller.flows(for: target) { flows[flow.id] = flow }
        }
        if selection.count == 1, let only = selection.first {
            inspector = controller.info(for: only)
        } else {
            // Several things at once: add them up.
            let open = flows.values.filter { $0.state != .closed }
            let names = selection.compactMap { controller.info(for: $0)?.title }.sorted()
            inspector = flows.isEmpty ? nil : HoverInfo(
                title: "\(selection.count) items", subtitle: names.prefix(4).joined(separator: ", ") + (names.count > 4 ? " +\(names.count - 4)" : ""),
                rows: [
                    .init(label: "Connections", value: "\(open.count)"),
                    .init(label: "Rate", value: "↓ \(ByteFormat.rate(open.reduce(0) { $0 + $1.rateIn }))  ↑ \(ByteFormat.rate(open.reduce(0) { $0 + $1.rateOut }))"),
                    .init(label: "Total", value: "↓ \(ByteFormat.bytes(flows.values.reduce(0) { $0 + Double($1.bytesIn) }))  ↑ \(ByteFormat.bytes(flows.values.reduce(0) { $0 + Double($1.bytesOut) }))"),
                    .init(label: "Processes", value: "\(Set(flows.values.map(\.pid)).count)"),
                    .init(label: "Destinations", value: "\(Set(flows.values.map(\.key.remote.address)).count)"),
                ],
                footnote: "⌘-click to add or remove items")
        }
        inspectorRows = flows.values
            .sorted { ($0.rateTotal, $0.bytesTotal, $0.id) > ($1.rateTotal, $1.bytesTotal, $1.id) }
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
            "scrubbedTo": scrubTime ?? -1,
            "keepEnded": keepEnded,
            "endedKept": session.controller.endedCount,
            "scanSockets": scan?.sockets ?? -1,
            "scanProcesses": scan?.processes.count ?? -1,
            "historySeconds": timeRange.map { $0.upperBound - $0.lowerBound } ?? 0,
            "services": services.map(\.name),
            "interfaces": interfaces.map(\.name),
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
