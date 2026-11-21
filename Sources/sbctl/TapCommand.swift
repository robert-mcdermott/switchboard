import Foundation
import SwitchboardCore
import SwitchboardSources

/// Connects to the collector as a client and shows what it publishes. With `--json`, one
/// line per event; otherwise a count each second.
enum TapCommand {
    static func run(_ options: Options) throws -> Int32 {
        let path = options.value("--socket") ?? Switchboard.collectorSocketPath
        let client = try CollectorClient(path: path, clientName: "sbctl tap")
        let who = client.collectorUID == 0 ? "root: every account's sockets" : "uid \(client.collectorUID): that account's sockets only"
        FileHandle.standardError.write(Data(
            "connected to switchboardd \(client.collectorVersion) at \(path), running as \(who)\nsources: \(client.sources.joined(separator: ", "))\n".utf8))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        struct Line: Encodable {
            var source: String
            var event: SourceEvent
        }

        let seconds = options.number("--seconds", default: .infinity)
        let started = Date()
        var totals: [String: (seen: Int, removed: Int)] = [:]
        var lastReport = Date()
        while client.isConnected, Date().timeIntervalSince(started) < seconds {
            for (source, events) in client.pollBatches() {
                for event in events {
                    if options.has("--json") {
                        print(String(decoding: try encoder.encode(Line(source: source, event: event)), as: UTF8.self))
                    }
                    var total = totals[source] ?? (0, 0)
                    if case .seen = event { total.seen += 1 } else { total.removed += 1 }
                    totals[source] = total
                }
            }
            if !options.has("--json"), Date().timeIntervalSince(lastReport) >= 1 {
                lastReport = Date()
                let summary = client.sources.map { "\($0): \(totals[$0]?.seen ?? 0) updates, \(totals[$0]?.removed ?? 0) closed" }
                print(summary.joined(separator: "   ") + (client.resyncs > 0 ? "   resyncs: \(client.resyncs)" : ""))
                for line in client.health { print("  \(line)") }
                totals.removeAll()
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        if !client.isConnected {
            FileHandle.standardError.write(Data("the collector closed the connection\n".utf8))
            return 1
        }
        client.close()
        return 0
    }
}
