import SwiftUI
import AppKit
import Observation
import SwitchboardCore
import SwitchboardRender
import SwitchboardSources
import SwitchboardStore

/// One connection, flattened for tables.
struct ConnectionRow: Identifiable, Sendable {
    let id: FlowID
    var process: String
    var pid: Int
    var user: String
    var proto: String
    var remote: String
    /// Hostname, or empty when none is known.
    var host: String
    /// `DNS`, `TLS`, `PTR`, or empty.
    var hostSource: String
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
    var country: String
    var owner: String
    var key: FlowKey

    init(_ flow: Flow, process record: ProcessRecord?, now: EngineTime) {
        id = flow.id
        process = record?.name ?? "pid \(flow.pid)"
        pid = Int(flow.pid)
        user = record?.username ?? "–"
        proto = flow.key.proto.rawValue
        remote = flow.key.remote.address.description
        host = flow.hostname ?? ""
        switch flow.hostnameSource {
        case .dns: hostSource = "DNS"
        case .sni: hostSource = "TLS"
        case .ptr: hostSource = "PTR"
        case nil: hostSource = ""
        }
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
        country = flow.country ?? ""
        owner = flow.org ?? flow.asn.map { "AS\($0)" } ?? ""
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

/// A connection from the log.
struct LogRow: Identifiable, Sendable {
    let id: FlowID
    var started: Date
    var ended: Date?
    var process: String
    var pid: Int
    var remote: String
    var port: Int
    var service: String
    var bytesIn: Double
    var bytesOut: Double
    var duration: Double
}

/// A destination this Mac had never talked to before.
struct FirstSeenRow: Identifiable, Sendable {
    var id: String { address }
    var address: String
    var host: String
    var process: String
    var at: Date
}

/// A process on the network that Apple does not vouch for.
struct TrustRow: Identifiable, Sendable {
    var id: Int { pid }
    var pid: Int
    var process: String
    var signing: SigningStatus
    var path: String
    var connections: Int
}

struct AgeBucket: Identifiable, Sendable {
    var id: String { label }
    var label: String
    var count: Int
}

enum LogRange: String, CaseIterable, Sendable {
    case quarterHour = "15 min", hour = "1 hour", day = "24 hours", week = "7 days", all = "Everything"

    var seconds: Double? {
        switch self {
        case .quarterHour: 900
        case .hour: 3600
        case .day: 86_400
        case .week: 604_800
        case .all: nil
        }
    }
}

/// One DNS answer, for the DNS panel.
struct DNSRow: Identifiable, Sendable {
    let id: UInt64
    var time: Date
    var name: String
    var addresses: String
    var askedBy: String
    /// Open connections to any of the answer's addresses.
    var connections: Int
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
    case connections, talkers, throughput, mix, interfaces, dns, ages, firstSeen, trust, listeners, log, health

    var title: String {
        switch self {
        case .connections: "Connections"
        case .talkers: "Top Talkers"
        case .throughput: "Throughput"
        case .mix: "Protocols"
        case .interfaces: "Interfaces"
        case .dns: "DNS"
        case .ages: "Ages"
        case .firstSeen: "First Seen"
        case .trust: "Trust"
        case .log: "Log"
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
    /// Extra seconds to wait before measuring.
    let measureSettle: Double
    /// Minutes of timeline to keep, for this run only, overriding Settings.
    let historyOverride: Double?

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
    var panelTab = PanelTab.connections {
        didSet {
            derive()
            if panelTab == .log { runLogQuery() }
        }
    }
    /// Everything pinned in the inspector. ⌘-click adds to it.
    var selection = Set<PickTarget>()
    var focused = false
    /// Ended connections stay on the graph, subdued, instead of fading away.
    private(set) var keepEnded = UserDefaults.standard.bool(forKey: "keepEnded")
    /// Connections that never leave this Mac are shown unless this is turned off.
    private(set) var showThisMac = UserDefaults.standard.object(forKey: "showThisMac") as? Bool ?? true
    private(set) var endedCount = 0
    /// How the connections are arranged.
    var layout = GraphLayout.constellation
    /// Full screen with nothing but the graph.
    var kiosk = false
    var workspaces = WorkspaceStore.all()
    var activeWorkspace: String?
    @ObservationIgnored var enteredFullScreenForKiosk = false
    @ObservationIgnored var wakeLock: NSObjectProtocol?

    // Time: `nil` means the present.
    private(set) var scrubTime: EngineTime?
    private(set) var timeRange: ClosedRange<EngineTime>?
    /// What the menu bar menu shows: the totals and the top three talkers, every five seconds.
    private(set) var menuLines: [String] = []
    @ObservationIgnored private var menuUpdated = Date.distantPast
    @ObservationIgnored private var summaryUpdated = Date.distantPast
    private(set) var displayedWallClock: Double = 0
    var paused: Bool { scrubTime != nil || logMoment != nil }

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
    private(set) var dns: [DNSRow] = []
    private(set) var ages: [AgeBucket] = []
    private(set) var lingering: [ConnectionRow] = []
    private(set) var firstSeen: [FirstSeenRow] = []
    private(set) var trust: [TrustRow] = []
    private(set) var uncheckedProcesses = 0
    /// What location and ownership data is loaded, for Health and Settings.
    private(set) var geoStatus = ""
    private(set) var tagProblems: [String] = []

    // The log.
    private(set) var logAvailable = false
    private(set) var logNote = ""
    var logRange = LogRange.hour { didSet { runLogQuery() } }
    private(set) var logRows: [LogRow] = []
    private(set) var logHistogram: [Int] = []
    private(set) var logSummary = ""
    private(set) var logSpan: ClosedRange<Double>?
    private(set) var logBusy = false
    private(set) var logStats = LogStats()
    /// The past moment from the log being shown in the graph, if any.
    private(set) var logMoment: Double?
    var redactExports = false
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
    @ObservationIgnored private(set) var latest: EngineSnapshot?
    @ObservationIgnored private var soak: SoakRecorder?
    @ObservationIgnored private var window = TimeWindow()
    @ObservationIgnored private var feed: LiveFeed?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var sampleCount = 0
    @ObservationIgnored private var scrubRequest: Double?
    @ObservationIgnored private var logMomentRequest: Double?
    @ObservationIgnored private var derivation = 0
    @ObservationIgnored private var lastDerived = Date.distantPast
    @ObservationIgnored private var startupWorkspace: String?
    @ObservationIgnored private var startupKiosk = false
    @ObservationIgnored private var startupDisplay: Int?
    @ObservationIgnored private var loadedTags = ""
    @ObservationIgnored private var enrichmentLoaded = false
    @ObservationIgnored private var store: LogStore?
    @ObservationIgnored private var logQuery = 0
    @ObservationIgnored private var lastPrune = Date.distantPast

    init() {
        let arguments = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        sourceSpec = value("--source") ?? "nstat"
        measurePath = value("--measure")
        measureSettle = value("--settle").flatMap(Double.init) ?? 0
        historyOverride = value("--history-minutes").flatMap(Double.init)

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
            case .escape:
                if kiosk { setKiosk(false) } else { focused = false }
            case .toggleKeepEnded: setKeepEnded(!keepEnded)
            case .toggleThisMac: setShowThisMac(!showThisMac)
            case .layout(let number):
                if GraphLayout.allCases.indices.contains(number - 1) { setLayout(GraphLayout.allCases[number - 1]) }
            case .toggleKiosk: setKiosk(!kiosk)
            }
        }
        applySettings()
        if arguments.contains("--keep-ended") { keepEnded = true }
        layout = value("--layout").flatMap(GraphLayout.init(rawValue:))
            ?? UserDefaults.standard.string(forKey: "layout").flatMap(GraphLayout.init(rawValue:)) ?? .constellation
        controller.layout = layout
        startupWorkspace = value("--workspace")
        startupKiosk = arguments.contains("--kiosk")
        startupDisplay = value("--display").flatMap(Int.init)
        controller.keepsEnded = keepEnded
        if arguments.contains("--hide-this-mac") { showThisMac = false }
        controller.showsThisMac = showThisMac

        do {
            let epoch = CACurrentMediaTime()
            let feed = try LiveFeed(
                spec: sourceSpec, flows: value("--flows").flatMap(Int.init),
                collectorPath: value("--collector-socket") ?? Switchboard.collectorSocketPath, controller: controller,
                clock: { Float(CACurrentMediaTime() - epoch) },
                onSummary: { [weak self] summary in
                    Task { @MainActor in self?.receiveSummary(summary) }
                },
                onSnapshot: { [weak self] snapshot in
                    Task { @MainActor in self?.receive(snapshot) }
                })
            simulated = feed.simulated
            self.feed = feed
            feed.start()
            feed.setForeground(NSApplication.shared.isActive)
            // The settings were applied before the feed existed; apply what concerns it now.
            applySettings()
        } catch {
            failure = "\(error)"
        }

        openLog(path: value("--log-db"))
        if let path = value("--soak") {
            soak = SoakRecorder(path: path, hours: value("--hours").flatMap(Double.init) ?? 8, model: self)
            soak?.start()
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
        logMomentRequest = value("--log-back").flatMap(Double.init)
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

    /// Shows or hides connections that never leave this Mac, in the graph, the tables, and the log search.
    func setShowThisMac(_ on: Bool) {
        showThisMac = on
        session.controller.showsThisMac = on
        UserDefaults.standard.set(on, forKey: "showThisMac")
        derive()
        if panelTab == .log { runLogQuery() }
    }

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
        if paused { goLive() } else if let now = timeRange?.upperBound { scrub(to: now) }
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
        logMoment = nil
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
        let hostnames = defaults.string(forKey: "hostnames") ?? "passive"
        session.controller.showsHostnames = hostnames != "off"
        // Only "active" makes Switchboard send anything itself: reverse lookups through the system resolver.
        feed?.setActiveLookups(hostnames == "active")
        loadEnrichment()
        let minutes = historyOverride ?? defaults.object(forKey: "historyMinutes") as? Double ?? 15
        window.maximumAge = max(minutes, 1) * 60
        session.controller.lanesWindow = max(defaults.object(forKey: "lanesMinutes") as? Double ?? 10, 0.5) * 60
        session.controller.home = (defaults.string(forKey: "homeLocation")).flatMap(GeoPoint.init) ?? GeoPoint.guess()
        if let store, store.excludesLoopback != defaults.bool(forKey: "logSkipLoopback") {
            store.excludesLoopback = defaults.bool(forKey: "logSkipLoopback")
        }
    }

    /// What the command line asked for that needs the window to exist first.
    func applyStartupArrangement() {
        if let number = startupDisplay { moveToDisplay(number) }
        if let name = startupWorkspace {
            if let workspace = workspaces.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                apply(workspace)
            } else {
                failure = "No workspace named \(name). There are: \(workspaces.map(\.name).joined(separator: ", "))"
            }
        }
        if startupKiosk { setKiosk(true) }
        startupWorkspace = nil
        startupKiosk = false
        startupDisplay = nil
    }

    private func applyClustering(_ mode: String, threshold: Int) {
        switch mode {
        case "off": session.controller.clustering = .off
        case "subnet": session.controller.clustering = .subnet
        case "owner": session.controller.clustering = .owner
        case "country": session.controller.clustering = .country
        default: session.controller.clustering = .automatic(threshold: max(threshold, 10))
        }
    }

    /// `~/Library/Application Support/Switchboard/GeoIP`, where `.mmdb` files are looked for.
    static var geoDirectory: URL {
        LogStore.defaultURL().deletingLastPathComponent().appendingPathComponent("GeoIP")
    }

    /// Loads location databases and the user's address lists, and hands them to the engine.
    private func loadEnrichment() {
        // Settings are first applied before the feed exists; there is nothing to hand the
        // databases to yet, and marking them loaded then would mean they never are.
        guard feed != nil else { return }
        let text = UserDefaults.standard.string(forKey: "tagLists") ?? ""
        // Simulated traffic gets invented places; that is decided once the feed exists.
        let key = text + (simulated ? "\u{0}simulated" : "")
        guard key != loadedTags || !enrichmentLoaded else { return }
        loadedTags = key
        enrichmentLoaded = true
        let parsed = TagList.parse(text)
        tagProblems = parsed.problems
        let loaded = simulated
            ? (database: GeoDatabase(tags: parsed.lists, fallback: SimulatedGeography()), problems: [String]())
            : GeoDatabase.load(directory: Self.geoDirectory, tags: parsed.lists)
        var colors: [String: SIMD3<Float>] = [:]
        for list in parsed.lists {
            guard let hex = list.color.flatMap({ UInt32($0.dropFirst(), radix: 16) }) else { continue }
            colors[list.name] = SIMD3(Float((hex >> 16) & 0xff), Float((hex >> 8) & 0xff), Float(hex & 0xff)) / 255
        }
        session.controller.setTagColors(colors)
        feed?.setEnricher(loaded.database.isEmpty ? nil : loaded.database)
        if loaded.database.sources.isEmpty {
            geoStatus = "No location database. Run scripts/fetch-geoip.sh to add one."
        } else {
            geoStatus = "Location data: " + loaded.database.sources.joined(separator: ", ")
        }
        if !loaded.problems.isEmpty { geoStatus += " · could not read " + loaded.problems.joined(separator: "; ") }
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
            if panelTab == .log { runLogQuery() }
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

    /// A filter that selects what a node or edge stands for, in whichever layout it is.
    func filterExpression(for target: PickTarget) -> String? {
        session.controller.filterHint(for: target) ?? Self.filterText(for: target)
    }

    static func filterText(for target: PickTarget) -> String? {
        switch target {
        case .node(.process(let pid)), .edge(.host, .process(let pid)): "pid=\(pid)"
        case .node(.endpoint(let address)): "remote=\(address)"
        case .node(.network(let address, let bits)): "remote:\(address)/\(bits)"
        case .node(.group(.asn, let key)): "asn=\(key)"
        case .node(.group(.country, let key)): "country=\(key)"
        case .node(.group(.domain, let key)): "host:*\(key)"
        case .node(.service(let name)): "service=\"\(name)\""
        case .edge(.process(let pid), .service(let name)): "pid=\(pid) service=\"\(name)\""
        case .edge(.service(let name), .group(.asn, let key)): "service=\"\(name)\" asn=\(key)"
        case .edge(.service(let name), .group(.domain, let key)): "service=\"\(name)\" host:*\(key)"
        case .edge(.process(let pid), .group(.asn, let key)): "pid=\(pid) asn=\(key)"
        case .edge(.process(let pid), .group(.country, let key)): "pid=\(pid) country=\(key)"
        case .edge(.process(let from), .process): "pid=\(from) remote:127.0.0.0/8"
        case .edge(.process(let pid), .endpoint(let address)): "pid=\(pid) remote=\(address)"
        case .edge(.process(let pid), .network(let address, let bits)): "pid=\(pid) remote:\(address)/\(bits)"
        default: nil
        }
    }

    /// Narrows everything to the selection. Several items are joined with OR.
    func filterToSelection() {
        let parts = selection.compactMap(filterExpression(for:)).sorted()
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

    // MARK: - The log

    private func openLog(path: String?) {
        // Invented traffic is kept out of the real log; a log is only written for a
        // simulation when one is named.
        if simulated, path == nil {
            logNote = "Simulated traffic is not logged."
            return
        }
        guard UserDefaults.standard.object(forKey: "logging") as? Bool ?? true else {
            logNote = "Logging is turned off in Settings."
            return
        }
        do {
            let detail = UserDefaults.standard.string(forKey: "logDetail").flatMap(LogDetail.init(rawValue:)) ?? .standard
            let store = try LogStore(url: path.map { URL(fileURLWithPath: $0) } ?? LogStore.defaultURL(), detail: detail)
            store.excludesLoopback = UserDefaults.standard.bool(forKey: "logSkipLoopback")
            store.onFirstSeen = { [weak self] addresses in
                Task { @MainActor in self?.noteFirstSeen(addresses) }
            }
            self.store = store
            logAvailable = true
        } catch {
            logNote = "The log could not be opened: \(error)"
        }
    }

    private func noteFirstSeen(_ addresses: [IPAddress]) {
        session.controller.markFirstSeen(addresses, time: session.time)
        let flows = latest?.flows ?? []
        let processes = Dictionary(uniqueKeysWithValues: (latest?.processes ?? []).map { ($0.pid, $0) })
        for address in addresses {
            let flow = flows.first { $0.key.remote.address == address }
            firstSeen.insert(FirstSeenRow(
                address: address.description, host: flow?.hostname ?? "",
                process: flow.map { processes[$0.pid]?.name ?? "pid \($0.pid)" } ?? "–", at: Date()), at: 0)
        }
        if firstSeen.count > 200 { firstSeen.removeLast(firstSeen.count - 200) }
    }

    /// Searches the log with the current filter and range. Runs off the main thread;
    /// a newer search overtakes an older one.
    func runLogQuery() {
        guard let store else { return }
        logQuery += 1
        let generation = logQuery
        let filter = self.filter, leavingOnly = !showThisMac
        let range = logRange
        logBusy = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let now = Date().timeIntervalSince1970
            let stats = (try? store.stats()) ?? LogStats()
            let from = range.seconds.map { now - $0 } ?? (stats.oldest ?? now - 3600)
            let result = try? store.query(filter, from: from, to: now, limit: 1000, leavingThisMacOnly: leavingOnly)
            await self?.showLog(result, stats: stats, generation: generation)
        }
    }

    private func showLog(_ result: LogQueryResult?, stats: LogStats, generation: Int) {
        guard generation == logQuery else { return }
        logBusy = false
        logStats = stats
        guard let result else {
            logSummary = "The search failed."
            return
        }
        logRows = result.entries.map { entry in
            let flow = entry.flow
            return LogRow(
                id: flow.id, started: Date(timeIntervalSince1970: flow.firstSeen),
                ended: flow.closedAt.map { Date(timeIntervalSince1970: $0) }, process: entry.process.name, pid: Int(flow.pid),
                remote: flow.hostname ?? flow.key.remote.address.description, port: Int(flow.key.remote.port),
                service: flow.service ?? "–", bytesIn: Double(flow.bytesIn), bytesOut: Double(flow.bytesOut),
                duration: (flow.closedAt ?? flow.lastSeen) - flow.firstSeen)
        }
        logHistogram = result.histogram
        logSpan = result.from...max(result.to, result.from + 1)
        let shown = result.matched > result.entries.count ? ", newest \(result.entries.count) listed" : ""
        logSummary = String(format: "%d connections match%@ · %.0f ms", result.matched, shown, result.milliseconds)
    }

    /// Shows the graph and the tables as the log remembers a past moment.
    func showLogMoment(_ moment: Double) {
        guard let store else { return }
        logMoment = moment
        scrubTime = nil
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let snapshot = try? store.snapshot(at: moment) else { return }
            await self?.present(snapshot, moment: moment)
        }
    }

    private func present(_ past: EngineSnapshot, moment: Double) {
        // The slider may have moved on, or the user gone back to the present.
        guard logMoment == moment else { return }
        snapshot = past
        displayedWallClock = moment
        session.controller.hold(past)
        derive()
    }

    func exportLog(_ format: ExportFormat) {
        guard let store else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "switchboard-log.\(format.rawValue)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let filter = self.filter, redact = redactExports, range = logRange, leavingOnly = !showThisMac
        Task.detached(priority: .userInitiated) { [weak self] in
            let now = Date().timeIntervalSince1970
            let from = range.seconds.map { now - $0 } ?? 0
            let written = try? store.export(
                filter, from: from, to: now, format: format, redactHostnames: redact, to: url, leavingThisMacOnly: leavingOnly)
            await self?.exportFinished(written, url: url)
        }
    }

    private func exportFinished(_ written: Int?, url: URL) {
        logSummary = written.map { "Wrote \($0) connections to \(url.lastPathComponent)" } ?? "The export failed."
    }

    func purgeLog() {
        guard let store else { return }
        let alert = NSAlert()
        alert.messageText = "Erase the whole log?"
        alert.informativeText = "Every recorded connection, DNS answer, and first-seen date will be deleted. This cannot be undone. Recording continues afterwards."
        alert.addButton(withTitle: "Erase")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try? store.purge()
        firstSeen = []
        runLogQuery()
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
            filterText = filterExpression(for: target) ?? ""
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
        // Assigned only when they change, so the views that show them are not redrawn for nothing.
        let isFocused = session.controller.focus != nil
        if focused != isFocused { focused = isFocused }
        let ended = keepEnded ? session.controller.endedCount : 0
        if endedCount != ended { endedCount = ended }
        let busiest = talkers.prefix(3).map { "\($0.name), \(ByteFormat.rate($0.rate))" }.joined(separator: "; ")
        session.setAccessibilitySummary(
            "\(layout.rawValue.capitalized) layout. \(summary.flows) connections, receiving \(ByteFormat.rate(summary.rateIn)), "
                + "sending \(ByteFormat.rate(summary.rateOut)). " + (busiest.isEmpty ? "" : "Busiest: \(busiest)."))
    }

    private func receive(_ snapshot: EngineSnapshot) {
        latest = snapshot
        window.append(snapshot)
        store?.record(snapshot)
        // Old history is trimmed once an hour, off the main thread.
        if let store, Date().timeIntervalSince(lastPrune) > 3600 {
            lastPrune = Date()
            let days = UserDefaults.standard.object(forKey: "logDays") as? Double ?? 30
            let megabytes = UserDefaults.standard.object(forKey: "logMegabytes") as? Double ?? 2000
            Task.detached(priority: .utility) { _ = try? store.prune(maximumAge: days * 86_400, maximumBytes: Int(megabytes * 1_000_000)) }
        }
        // The slider's range moves on once a second; moving it at every snapshot redraws
        // the timeline for a change no one can see.
        if let range = window.range,
           abs(range.upperBound - (timeRange?.upperBound ?? -1e9)) >= 1 || abs(range.lowerBound - (timeRange?.lowerBound ?? -1e9)) >= 1 {
            timeRange = range
        } else if window.range == nil, timeRange != nil {
            timeRange = nil
        }
        if panelTab == .log, logRows.isEmpty, !logBusy, snapshot.time > 3 { runLogQuery() }
        if let back = logMomentRequest, snapshot.time > back + 3 {
            // For screenshots: show a moment from the log once there is one to show.
            logMomentRequest = nil
            showLogMoment(Date().timeIntervalSince1970 - back)
        }
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
        guard scrubTime == nil, logMoment == nil else { return }
        self.snapshot = snapshot
        displayedWallClock = snapshot.wallClock
        // The graph takes every snapshot; the tables once a second. Redrawing a table is
        // the most expensive thing the window does, and figures that change twice a second
        // are harder to read, not easier.
        if Date().timeIntervalSince(lastDerived) >= 0.95 { derive() }
        if Date().timeIntervalSince(menuUpdated) >= 5 {
            menuUpdated = Date()
            menuLines = [statusLine] + talkers.prefix(3).map { "\($0.name)  \(ByteFormat.rate($0.rate))" }
        }
    }

    /// The totals in the top bar, at most once a second, unless the mode has changed.
    private func receiveSummary(_ next: LiveFeed.Summary) {
        guard Date().timeIntervalSince(summaryUpdated) >= 0.95 || "\(next.mode)" != "\(summary.mode)" else { return }
        summaryUpdated = Date()
        summary = next
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
        var dns: [DNSRow] = []
        var ages: [AgeBucket] = []
        var lingering: [ConnectionRow] = []
        var trust: [TrustRow] = []
        var unchecked = 0

        /// Runs off the main thread: on a busy machine this is tens of milliseconds, and
        /// on the main thread that is a dropped frame every second.
        static func make(
            _ snapshot: EngineSnapshot, filter: FlowFilter, showThisMac: Bool = true, rowLimit: Int, wantRows: Bool
        ) -> Derived {
            var derived = Derived()
            let processes = Dictionary(uniqueKeysWithValues: snapshot.processes.map { ($0.pid, $0) })
            let open = snapshot.flows.filter { $0.state != .closed }
            derived.totalFlows = open.count
            let shown = showThisMac ? open : open.filter { !$0.staysOnThisMac }
            let matching = filter.isEmpty
                ? shown : shown.filter { filter.matches($0, process: processes[$0.pid], now: snapshot.time) }
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

            // How long connections have been open, and the ones that have been open a long
            // time while carrying almost nothing: the shape of something phoning home.
            let limits: [(String, Double)] = [("under 10 s", 10), ("10 s – 1 min", 60), ("1 – 10 min", 600), ("10 min – 1 h", 3600), ("1 h – 1 day", 86_400), ("over a day", .infinity)]
            var counts = [Int](repeating: 0, count: limits.count)
            for flow in matching {
                let age = flow.age(at: snapshot.time)
                counts[limits.firstIndex { age < $0.1 } ?? limits.count - 1] += 1
            }
            derived.ages = zip(limits, counts).map { AgeBucket(label: $0.0.0, count: $0.1) }
            derived.lingering = matching
                .filter { $0.age(at: snapshot.time) > 3600 && $0.bytesTotal < 100_000 && !$0.key.remote.address.isLoopback }
                .sorted { $0.firstSeen < $1.firstSeen }
                .prefix(30)
                .map { ConnectionRow($0, process: processes[$0.pid], now: snapshot.time) }

            // Processes on the network that are not Apple's and not from an identified developer.
            let perProcess = Dictionary(grouping: open, by: \.pid).mapValues(\.count)
            for process in snapshot.processes {
                guard let count = perProcess[process.pid] else { continue }
                switch process.signing {
                case .apple, .developerID:
                    continue
                case .unknown:
                    derived.unchecked += 1
                case .adHoc, .unsigned, .invalid:
                    derived.trust.append(TrustRow(
                        pid: Int(process.pid), process: process.name, signing: process.signing, path: process.path ?? "–", connections: count))
                }
            }
            // The most worrying first.
            func rank(_ status: SigningStatus) -> Int { status == .invalid ? 0 : (status == .unsigned ? 1 : 2) }
            derived.trust.sort { (rank($0.signing), $0.process, $0.pid) < (rank($1.signing), $1.process, $1.pid) }

            // Newest first, each with how many connections are using what it resolved to.
            var perAddress: [IPAddress: Int] = [:]
            for flow in open { perAddress[flow.key.remote.address, default: 0] += 1 }
            derived.dns = snapshot.dns.reversed().map { record in
                DNSRow(
                    id: record.id, time: Date(timeIntervalSince1970: snapshot.wallClock - (snapshot.time - record.time)),
                    name: record.name, addresses: record.addresses.map(\.description).joined(separator: ", "),
                    askedBy: record.pid.map { processes[$0]?.name ?? "pid \($0)" } ?? "–",
                    connections: record.addresses.reduce(0) { $0 + (perAddress[$1] ?? 0) })
            }

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
        lastDerived = Date()
        derivation += 1
        let generation = derivation
        let filter = self.filter, showThisMac = self.showThisMac
        // Rows are only built when the table that shows them is on screen.
        let wantRows = showPanel && panelTab == .connections
        Task.detached(priority: .userInitiated) { [weak self] in
            let derived = Derived.make(snapshot, filter: filter, showThisMac: showThisMac, rowLimit: Self.rowLimit, wantRows: wantRows)
            await self?.apply(derived, generation: generation, wantRows: wantRows)
        }
    }

    private func apply(_ derived: Derived, generation: Int, wantRows: Bool) {
        // A newer snapshot or filter has overtaken this one.
        guard generation == derivation else { return }
        // Rows come and go every second; animating each one in and out was most of the
        // main thread's work, and a live table reads better without the motion anyway.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { applyUnanimated(derived, wantRows: wantRows) }
    }

    private func applyUnanimated(_ derived: Derived, wantRows: Bool) {
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
        dns = derived.dns
        ages = derived.ages
        lingering = derived.lingering
        trust = derived.trust
        uncheckedProcesses = derived.unchecked
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
        switch summary.mode {
        case .simulated: "SIMULATED · \(sourceSpec)"
        case .standalone: getuid() == 0 ? "STANDALONE · all users" : "STANDALONE · your processes"
        case .full(let uid): uid == 0 ? "FULL · every account, via the collector" : "FULL · collector running as uid \(uid)"
        }
    }

    /// The collector is feeding the app.
    var fullMode: Bool {
        if case .full = summary.mode { return true }
        return false
    }

    var matchLine: String {
        if filter.isEmpty && showThisMac { return "\(totalFlows) connections" }
        if filter.isEmpty { return "\(totalMatching) of \(totalFlows) leave this Mac" }
        return "\(totalMatching) of \(totalFlows) match"
    }

    /// Facts about a run, gathered from inside the app, for measurement and screenshots.
    /// The log's size on disk, with its write-ahead file.
    func logFileBytes() -> Double {
        guard let url = store?.url else { return 0 }
        return ["", "-wal"].reduce(0.0) { total, suffix in
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path + suffix)[.size] as? NSNumber)?.doubleValue ?? 0
            return total + size
        }
    }

    func writeMeasurement(to path: String, measured: FrameStats.Summary) {
        let processStart = ProcessTable.bsdInfo(of: getpid()).map {
            Double($0.pbi_start_tvsec) + Double($0.pbi_start_tvusec) / 1e6
        }
        let firstData = session.firstDataFrame?.timeIntervalSince1970
        let report: [String: Any] = [
            "version": Switchboard.version,
            "source": sourceSpec,
            "profile": profile.rawValue,
            "layout": layout.rawValue,
            "graphAccessibilityLabel": session.accessibilityLabelOnView ?? "",
            "graphAccessibilityValue": session.accessibilityValueOnView ?? "",
            "kiosk": kiosk,
            "workspace": activeWorkspace ?? "",
            "workspaces": workspaces.map(\.name),
            "fullScreen": mainWindow?.styleMask.contains(.fullScreen) ?? false,
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
            "geoStatus": geoStatus,
            "trustRows": trust.map { "\($0.process):\($0.signing.rawValue)" },
            "unchecked": uncheckedProcesses,
            "signingCounts": Dictionary(grouping: (latest?.processes ?? []), by: \.signing.rawValue).mapValues(\.count),
            "logAvailable": logAvailable,
            "logFlows": logStats.flows,
            "logRows": logRows.count,
            "logSummary": logSummary,
            "logMoment": logMoment ?? -1,
            "ageBuckets": ages.map(\.count),
            "mode": modeLine,
            "sourceLines": summary.sources,
            "keepEnded": keepEnded,
            "showThisMac": showThisMac,
            "endedKept": session.controller.endedCount,
            "scanSockets": scan?.sockets ?? -1,
            "scanProcesses": scan?.processes.count ?? -1,
            "historySeconds": timeRange.map { $0.upperBound - $0.lowerBound } ?? 0,
            "services": services.map(\.name),
            "interfaces": interfaces.map(\.name),
            "namedRows": rows.count { !$0.host.isEmpty },
            "dnsRows": dns.count,
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
