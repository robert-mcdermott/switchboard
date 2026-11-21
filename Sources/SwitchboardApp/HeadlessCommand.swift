import Foundation
import SwitchboardCore
import SwitchboardRender
import SwitchboardSources

/// Windowless modes of the app binary, used by scripts/snapshots.sh.
///
///     Switchboard --snapshot out.png --source sim:developer --at 20 [--size 2400x1500] [--profile cinema]
///     Switchboard --snapshot out.png … --describe process:2010      also print that node's tooltip
///     Switchboard --diff a.png b.png [--tolerance 1.0]
@MainActor
enum HeadlessCommand {
    /// Returns an exit code if the arguments asked for a headless mode, otherwise `nil`.
    static func run(_ arguments: [String]) -> Int32? {
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }

        if let index = arguments.firstIndex(of: "--diff") {
            guard arguments.indices.contains(index + 2) else {
                print("usage: --diff <a.png> <b.png> [--tolerance N]")
                return 2
            }
            let tolerance = value("--tolerance").flatMap(Double.init) ?? 1.0
            do {
                let result = try HeadlessRenderer.difference(
                    URL(fileURLWithPath: arguments[index + 1]), URL(fileURLWithPath: arguments[index + 2]))
                let same = result.mean <= tolerance
                print(String(
                    format: "%@  mean difference %.3f of 255 (tolerance %.2f), largest %d, %.2f%% of pixels changed",
                    same ? "MATCH " : "DIFFER", result.mean, tolerance, result.maximum, result.changedFraction * 100))
                return same ? 0 : 1
            } catch {
                print("error: \(error)")
                return 2
            }
        }

        guard let output = value("--snapshot") else { return nil }
        let spec = value("--source") ?? "sim:developer"
        let at = value("--at").flatMap(Double.init) ?? 20
        let size = (value("--size") ?? "2400x1500").split(separator: "x").compactMap { Int($0) }
        let profile = value("--profile").flatMap(RenderProfile.init(rawValue:)) ?? .cinema
        guard size.count == 2, size[0] > 0, size[1] > 0 else {
            print("--size must look like 2400x1500")
            return 2
        }

        do {
            let resolved = try SourceSpec.make(spec, flows: value("--flows").flatMap(Int.init))
            guard resolved.simulated else {
                print("--snapshot needs a sim: or trace: source, so the result is reproducible")
                return 2
            }
            let engine = FlowEngine(resolver: SourceSpec.resolver(for: resolved))
            // Simulated addresses get invented places, and home is fixed, so the picture is
            // the same on every machine and in every time zone.
            engine.enricher = SimulatedGeography()
            let controller = GraphController()
            controller.home = GeoPoint(latitude: 47.61, longitude: -122.33)
            if let layout = value("--layout") {
                guard let chosen = GraphLayout(rawValue: layout) else {
                    print("--layout must be one of: \(GraphLayout.allCases.map(\.rawValue).joined(separator: ", "))")
                    return 2
                }
                controller.layout = chosen
                controller.lanesWindow = value("--lanes-window").flatMap(Double.init) ?? 60
            }
            if let view = value("--space-view") {
                // Degrees round, degrees up, and distance: where the cyberspace camera looks from.
                let parts = view.split(separator: ",").compactMap { Float($0) }
                guard parts.count == 3 else {
                    print("--space-view takes yaw,pitch,distance, such as 20,30,3000")
                    return 2
                }
                controller.pointSpaceCamera(yaw: parts[0] * .pi / 180, pitch: parts[1] * .pi / 180, distance: parts[2])
            }
            if let name = value("--palette") {
                guard let theme = PaletteScheme(rawValue: name) else {
                    print("--palette must be one of: \(PaletteScheme.allCases.map(\.rawValue).joined(separator: ", "))")
                    return 2
                }
                controller.palette = theme
            }
            // Same ticks, same times, same picture, every run.
            SteppedRun.run(sources: resolved.sources, engine: engine, until: at) { time in
                controller.update(engine.snapshot(), time: Float(time))
                for _ in 0..<15 { controller.step() }
            }
            try HeadlessRenderer.render(
                controller, time: Float(at), width: size[0], height: size[1], profile: profile,
                to: URL(fileURLWithPath: output))
            print("wrote \(output): \(engine.flows.count) flows at t=\(at) s, \(size[0])x\(size[1]), \(profile.rawValue)")

            if let describe = value("--describe") {
                let target: PickTarget?
                if describe == "host" {
                    target = .node(.host)
                } else if describe.hasPrefix("process:"), let pid = Int32(describe.dropFirst(8)) {
                    target = .node(.process(pid))
                } else if describe.hasPrefix("endpoint:"), let address = IPAddress(String(describe.dropFirst(9))) {
                    target = .node(.endpoint(address))
                } else {
                    target = nil
                }
                guard let target, let info = controller.info(for: target) else {
                    print("nothing to describe for \(describe)")
                    return 1
                }
                print("\(info.title) — \(info.subtitle)")
                for row in info.rows { print("  \(row.label): \(row.value)") }
            }
            return 0
        } catch {
            print("error: \(error)")
            return 1
        }
    }
}
