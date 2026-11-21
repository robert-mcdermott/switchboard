import AppKit
import Observation
import SwitchboardCore
import SwitchboardRender

@MainActor
@Observable
final class AppModel {
    let stats = FrameStats()
    /// Present only in spike-report mode, so normal runs keep a framebuffer-only drawable.
    let capture: FrameCapture?
    let edgeCount: Int
    /// When set, the app measures itself for a few seconds, writes a report here, and quits.
    let spikeReportPath: String?

    var rendererInfo: PrototypeRenderer.Info?
    var rendererError: String?
    var summary = FrameStats.Summary()

    init() {
        let arguments = CommandLine.arguments
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        edgeCount = value(after: "--edges").flatMap(Int.init).map { min(max($0, 1), 200_000) } ?? 1000
        spikeReportPath = value(after: "--spike-report")
        capture = spikeReportPath == nil ? nil : FrameCapture()
    }

    var statusLine: String {
        summary.frames == 0 ? "Starting…" : String(format: "%.0f fps · %d edges", summary.framesPerSecond, edgeCount)
    }

    func refresh() {
        summary = stats.summary()
    }

    func rendererReady(_ result: Result<PrototypeRenderer.Info, Error>) {
        switch result {
        case .success(let info): rendererInfo = info
        case .failure(let error): rendererError = "\(error)"
        }
    }

    /// Facts for spikes S4 and S5, gathered from inside the running app.
    func writeSpikeReport(to path: String, measured: FrameStats.Summary) {
        let windows = NSApplication.shared.windows.map {
            ["class": $0.className, "title": $0.title, "visible": $0.isVisible] as [String: Any]
        }
        let screen = NSScreen.main
        let report: [String: Any] = [
            "version": Switchboard.version,
            "bundlePath": Bundle.main.bundlePath,
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "",
            "resourceOrigin": rendererInfo?.resourceOrigin.rawValue ?? "",
            "rendererError": rendererError ?? "",
            "device": rendererInfo?.deviceName ?? "",
            "edges": rendererInfo?.edgeCount ?? 0,
            "shaderCompileMS": rendererInfo?.shaderCompileMS ?? -1,
            "screenMaxFPS": screen?.maximumFramesPerSecond ?? 0,
            "screenScale": screen?.backingScaleFactor ?? 0,
            "windowPixels": NSApplication.shared.windows.first { $0.title == "Switchboard" }.map {
                let size = $0.convertToBacking($0.contentLayoutRect).size
                return "\(Int(size.width))x\(Int(size.height))"
            } ?? "",
            "appIsActive": NSApplication.shared.isActive,
            "frames": measured.frames,
            "fps": measured.framesPerSecond,
            "medianIntervalMS": measured.medianIntervalMS,
            "p99IntervalMS": measured.p99IntervalMS,
            "worstIntervalMS": measured.worstIntervalMS,
            "meanEncodeMS": measured.meanEncodeMS,
            "meanGPUMS": measured.meanGPUMS,
            "p99GPUMS": measured.p99GPUMS,
            "windows": windows,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
