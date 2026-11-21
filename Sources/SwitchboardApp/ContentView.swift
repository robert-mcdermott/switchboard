import SwiftUI
import SwitchboardCore
import SwitchboardRender

struct ContentView: View {
    @Bindable var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(red: 5 / 255, green: 8 / 255, blue: 15 / 255).ignoresSafeArea()

            GraphPrototypeView(edgeCount: model.edgeCount, stats: model.stats, capture: model.capture) { result in
                model.rendererReady(result)
            }
            .ignoresSafeArea()

            hud.padding(16)
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                model.refresh()
            }
        }
        .task {
            guard let path = model.spikeReportPath else { return }
            await runSpikeReport(path: path)
        }
    }

    private var hud: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SWITCHBOARD")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .kerning(3)
                .foregroundStyle(Color(red: 0.216, green: 0.902, blue: 1.0))
            Text("M0 render prototype · synthetic data")
                .foregroundStyle(Color(red: 0.42, green: 0.49, blue: 0.58))

            if let error = model.rendererError {
                Text("renderer failed: \(error)").foregroundStyle(Color(red: 1.0, green: 0.231, blue: 0.361))
            } else if let info = model.rendererInfo {
                ForEach(readouts(for: info), id: \.self) { line in
                    Text(line).foregroundStyle(Color(red: 0.79, green: 0.84, blue: 0.91))
                }
            }
        }
        .font(.system(size: 11, design: .monospaced))
    }

    private func readouts(for info: PrototypeRenderer.Info) -> [String] {
        let summary = model.summary
        let timing = String(
            format: "%.0f fps · frame p99 %.1f ms · gpu %.2f ms",
            summary.framesPerSecond, summary.p99IntervalMS, summary.meanGPUMS)
        let startup = String(format: "shaders compiled in %.0f ms", info.shaderCompileMS)
        return [
            "\(info.edgeCount) edges · \(info.deviceName)",
            timing,
            "\(startup) · resources: \(info.resourceOrigin.rawValue)",
        ]
    }

    /// Lets the window settle, measures five seconds of frames, saves one frame, checks
    /// that the Settings scene opens, writes the report, and quits.
    private func runSpikeReport(path: String) async {
        try? await Task.sleep(for: .seconds(2))
        model.stats.reset()
        try? await Task.sleep(for: .seconds(5))
        let measured = model.stats.summary()
        model.capture?.request(savingTo: URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("png"))
        try? await Task.sleep(for: .milliseconds(500))
        openSettings()
        try? await Task.sleep(for: .seconds(1))
        model.writeSpikeReport(to: path, measured: measured)
        NSApplication.shared.terminate(nil)
    }
}
