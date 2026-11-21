import Foundation
import SwitchboardCore
import SwitchboardSources

enum SBCtl {
    static let usage = """
        sbctl \(Switchboard.version) — Switchboard diagnostics

        usage:
          sbctl top [--source S] [--once] [--seconds N]    live connections, busiest first
          sbctl dump [--source S]                          the engine's model as JSON
          sbctl record <file> [--source S] [--seconds N]   save source events to a trace
          sbctl bench [--flows N] | --live                 engine cost, simulated or on this machine
          sbctl verify                                     check the live engine against netstat and known traffic
          sbctl tap [--socket PATH] [--json] [--seconds N] watch what the collector publishes
          sbctl log stats | query | export | prune | purge  read and maintain the log (sbctl log for details)
          sbctl geo <address>…                             location and network owner, from the local databases
          sbctl trust <program>…                           who signed a program

          sources: nstat (default), nettop, nstat+nettop, collector[:socket], sim:<scenario>, trace:<file>
          scenarios: quiet, developer, stress, beacon, portscan

          sbctl probe sockets [--list] [--verify]   kernel socket list (empty unless root)
          sbctl probe processes                     process identity coverage (no privileges)
          sbctl probe nstat                         NetworkStatistics framework (no privileges)
          sbctl probe pktap [--seconds N]           packet capture with process metadata (needs sudo)
          sbctl probe all                           every probe in turn
          sbctl version
        """

    static func run(_ arguments: [String]) -> Int32 {
        let options = Options(arguments: Array(arguments.dropFirst()))
        do {
            switch arguments.first {
            case "top": return try TopCommand.run(options)
            case "dump": return try DumpCommand.run(options)
            case "record": return try RecordCommand.run(options)
            case "bench": return try BenchCommand.run(options)
            case "verify": return try VerifyCommand.run(options)
            case "tap": return try TapCommand.run(options)
            case "log": return try LogCommand.run(Array(arguments.dropFirst()))
            case "geo": return EnrichCommand.geo(Array(arguments.dropFirst()))
            case "trust": return EnrichCommand.trust(Array(arguments.dropFirst()))
            default: break
            }
        } catch {
            print("error: \(error)")
            return 1
        }
        switch arguments.first {
        case "probe":
            let rest = Array(arguments.dropFirst(2))
            switch arguments.dropFirst().first {
            case "all":
                // Every probe in turn. Run under sudo to answer the root-only questions.
                var failures: Int32 = 0
                for (title, arguments) in [
                    ("sockets", ["probe", "sockets", "--verify"]),
                    ("processes", ["probe", "processes"]),
                    ("nstat", ["probe", "nstat"]),
                    ("pktap", ["probe", "pktap"]),
                ] {
                    print("=== \(title) (uid \(getuid())) ===")
                    if run(arguments) != 0 { failures += 1 }
                    print("")
                }
                return failures
            case "sockets": return SocketsProbe.run(rest)
            case "processes": return ProcessesProbe.run()
            case "nstat":
                let result = NStatProbe.run()
                result.lines.forEach { print($0) }
                print(result.usable ? "RESULT: usable" : "RESULT: not usable")
                return result.usable ? 0 : 1
            case "pktap":
                var seconds = 8.0
                if let index = rest.firstIndex(of: "--seconds"), rest.indices.contains(index + 1),
                   let value = Double(rest[index + 1])
                {
                    seconds = min(max(value, 1), 120)
                }
                let result = PktapProbe.run(seconds: seconds)
                result.lines.forEach { print($0) }
                print(result.ok ? "RESULT: ok" : "RESULT: failed")
                return result.ok ? 0 : 1
            default:
                print(usage)
                return 2
            }
        case "version":
            print(Switchboard.version)
            return 0
        default:
            print(usage)
            return arguments.isEmpty ? 0 : 2
        }
    }
}
