import AppKit
import Observation
import SwitchboardCore
import SwitchboardRender
import SwitchboardSources

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

    @ObservationIgnored private var feed: LiveFeed?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

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
        profile = value("--profile").flatMap(RenderProfile.init(rawValue:)) ?? (reduceMotion ? .still : .cinema)

        let hostName = Host.current().localizedName ?? "This Mac"
        let controller = GraphController(hostLabel: hostName.uppercased())
        session = GraphSession(controller: controller)
        session.profile = profile
        if measurePath != nil { session.capture = FrameCapture() }

        session.onHover = { [weak self] info, point in
            self?.hover = info
            self?.hoverPoint = point
        }
        session.onFailure = { [weak self] message in self?.failure = message }
        session.onKey = { [weak self] key in
            guard let self else { return }
            switch key {
            case .togglePause: togglePause()
            case .cycleProfile: setProfile(profile.next)
            case .resetView: break
            }
        }

        do {
            let epoch = CACurrentMediaTime()
            let feed = try LiveFeed(
                spec: sourceSpec, flows: value("--flows").flatMap(Int.init), controller: controller,
                clock: { Float(CACurrentMediaTime() - epoch) },
                onSummary: { [weak self] summary in
                    Task { @MainActor in self?.summary = summary }
                })
            simulated = feed.simulated
            self.feed = feed
            feed.start()
            feed.setForeground(NSApplication.shared.isActive)
        } catch {
            failure = "\(error)"
        }

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.feed?.setForeground(true) }
        })
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.feed?.setForeground(false) }
        })
    }

    func togglePause() {
        paused.toggle()
        session.controller.paused = paused
    }

    func setProfile(_ next: RenderProfile) {
        profile = next
        session.profile = next
    }

    func refresh() {
        frames = session.stats.summary()
    }

    var statusLine: String {
        "\(summary.flows) connections · ↓ \(ByteFormat.rate(summary.rateIn)) ↑ \(ByteFormat.rate(summary.rateOut))"
    }

    /// Standalone shows the login user's processes only; say so rather than imply more.
    var modeLine: String {
        if simulated { return "SIMULATED TRAFFIC · \(sourceSpec)" }
        return getuid() == 0 ? "STANDALONE · all users" : "STANDALONE · your processes only"
    }

    /// Facts about a run, gathered from inside the app, for scripts/measure.sh.
    func writeMeasurement(to path: String, measured: FrameStats.Summary) {
        let windows = NSApplication.shared.windows.map { "\($0.className)|\($0.title)" }
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
            "nodes": session.nodeCount,
            "edges": session.edgeCount,
            "flows": summary.flows,
            "launchToFirstDataSeconds": (processStart != nil && firstData != nil) ? firstData! - processStart! : -1,
            "screenMaxFPS": NSScreen.main?.maximumFramesPerSecond ?? 0,
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
            "windows": windows,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
