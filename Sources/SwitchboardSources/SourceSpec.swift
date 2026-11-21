import Foundation
import SwitchboardCore

/// Turns a source description such as `nstat`, `nstat+nettop`, `sim:developer`, or
/// `trace:file.sbtrace` into running sources. Shared by the app and `sbctl`.
public enum SourceSpec {
    public struct Resolved {
        public var sources: [any FlowSource]
        /// The traffic is synthetic or recorded, so its processes do not exist on this machine.
        public var simulated: Bool
        /// Set when the sources come from the collector, which also knows the processes.
        public var collector: CollectorClient?
    }

    public enum SpecError: Error, CustomStringConvertible {
        case unknown(String)

        public var description: String {
            switch self {
            case .unknown(let text):
                let scenarios = SimulatorSource.Scenario.allCases.map(\.rawValue).joined(separator: "|")
                return "unknown source '\(text)'. Use nstat, nettop, nstat+nettop, collector[:socket], sim:<\(scenarios)>, or trace:<file>"
            }
        }
    }

    public static func make(_ spec: String, flows: Int? = nil, counterInterval: Double = 1.0) throws -> Resolved {
        var sources: [any FlowSource] = []
        var simulated = false
        var collector: CollectorClient?
        for part in spec.split(separator: "+") {
            switch part {
            case "nstat":
                sources.append(NStatSource(counterInterval: counterInterval))
            case "nettop":
                sources.append(NettopSource())
            case let text where text == "collector" || text.hasPrefix("collector:"):
                let path = text == "collector" ? Switchboard.collectorSocketPath : String(text.dropFirst(10))
                let client = try CollectorClient(path: path, clientName: "switchboard")
                collector = client
                sources.append(contentsOf: CollectorSource.all(for: client))
            case let text where text.hasPrefix("sim:"):
                guard let scenario = SimulatorSource.Scenario(rawValue: String(text.dropFirst(4))) else {
                    throw SpecError.unknown(spec)
                }
                sources.append(SimulatorSource(scenario: scenario, flows: flows))
                simulated = true
            case let text where text.hasPrefix("trace:"):
                let trace = try TraceFile.read(URL(fileURLWithPath: String(text.dropFirst(6))))
                sources.append(TraceReplaySource(records: trace.records))
                simulated = true
            default:
                throw SpecError.unknown(spec)
            }
        }
        guard !sources.isEmpty else { throw SpecError.unknown(spec) }
        return Resolved(sources: sources, simulated: simulated, collector: collector)
    }

    /// Simulated and replayed processes do not exist, so there is nothing to look up.
    public static func resolver(for resolved: Resolved) -> any ProcessResolver {
        if let collector = resolved.collector { return collector }
        return resolved.simulated ? PassthroughProcessResolver() : LibProcResolver()
    }
}
