import Foundation
import SwitchboardCore
import SwitchboardSources

/// Spike S6: how much can we learn about processes we do not own, without root?
enum ProcessesProbe {
    private struct Tally {
        var processes = 0
        var withPath = 0
        var withBSDInfo = 0
        var withDescriptors = 0
        var networked = 0
        var networkedWithPath = 0
        var networkedWithDescriptors = 0
    }

    static func run() -> Int32 {
        let me = getuid()
        var networked = Set<pid_t>()
        do {
            for proto in TransportProtocol.allCases {
                networked.formUnion(try KernelSocketList.snapshot(proto).sockets.map(\.pid))
            }
        } catch {
            print("FAILED: \(error)")
            return 1
        }

        var tallies: [String: Tally] = [:]
        var pathless: [String] = []
        for pid in ProcessTable.allPIDs() {
            guard let basic = ProcessTable.basicInfo(of: pid) else { continue }
            let owner = basic.uid == me ? "own user" : (basic.uid == 0 ? "root" : "other accounts")
            let hasPath = ProcessTable.path(of: pid) != nil
            let hasDescriptors = ProcessTable.socketDescriptorCount(of: pid) != nil
            var tally = tallies[owner, default: Tally()]
            tally.processes += 1
            if hasPath { tally.withPath += 1 }
            if ProcessTable.bsdInfo(of: pid) != nil { tally.withBSDInfo += 1 }
            if hasDescriptors { tally.withDescriptors += 1 }
            if networked.contains(pid) {
                tally.networked += 1
                if hasPath { tally.networkedWithPath += 1 }
                if hasDescriptors { tally.networkedWithDescriptors += 1 }
                if !hasPath, pathless.count < 8 { pathless.append("\(basic.name)(\(pid))") }
            }
            tallies[owner] = tally
        }

        print("running as uid \(me)\(me == 0 ? " (root)" : "")")
        print("owner            procs   path   bsdinfo   fd-list   | with sockets   path   fd-list")
        for owner in ["own user", "root", "other accounts"] {
            guard let tally = tallies[owner] else { continue }
            print(
                String(
                    format: "%@ %6d %6d %9d %9d   | %12d %6d %9d",
                    owner.padding(toLength: 15, withPad: " ", startingAt: 0),
                    tally.processes, tally.withPath, tally.withBSDInfo, tally.withDescriptors,
                    tally.networked, tally.networkedWithPath, tally.networkedWithDescriptors))
        }
        let missing = networked.subtracting(Set(ProcessTable.allPIDs()))
        print("socket-owning pids no longer running or not listed: \(missing.count)")
        if !pathless.isEmpty { print("networked processes without a path: \(pathless.joined(separator: ", "))") }
        return 0
    }
}
