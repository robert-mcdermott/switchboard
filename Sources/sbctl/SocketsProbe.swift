import Foundation
import SwitchboardCore
import SwitchboardSources

/// Spike S1: read the kernel socket list directly and check it against `netstat -anv`.
enum SocketsProbe {
    static func run(_ arguments: [String]) -> Int32 {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        // Recorded buffers can stand in for the live sysctl, which the kernel only fills
        // in for privileged or Apple-signed callers (docs/spikes/S1-kernel-socket-list.md).
        func load(_ proto: TransportProtocol, flag: String) throws -> KernelSocketList.Snapshot {
            guard let path = value(after: flag) else { return try KernelSocketList.snapshot(proto) }
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            return try data.withUnsafeBytes { try KernelSocketList.parse($0, proto: proto) }
        }

        do {
            let tcp = try load(.tcp, flag: "--tcp-file")
            let udp = try load(.udp, flag: "--udp-file")
            let sockets = tcp.sockets + udp.sockets
            if sockets.isEmpty {
                print("the kernel returned an empty list: this process is neither root nor Apple-signed")
            }

            print("record layout (kernel-reported length vs this build):")
            for expected in KernelSocketList.expectedRecordLengths {
                let observed = tcp.observedRecordLengths[expected.kind] ?? udp.observedRecordLengths[expected.kind]
                let relation = expected.exact ? "==" : ">="
                print(
                    "  \(expected.name.padding(toLength: 7, withPad: " ", startingAt: 0)) \(observed.map(String.init) ?? "-") \(relation) \(expected.length)"
                )
            }

            let owners = Set(sockets.map(\.pid))
            print("sockets: \(tcp.sockets.count) tcp, \(udp.sockets.count) udp, owned by \(owners.count) processes (uid \(getuid()))")
            print("buffer: \(tcp.bufferBytes + udp.bufferBytes) bytes")

            // Cost of a full sample, to size the polling budget.
            let rounds = 200
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<rounds {
                _ = try KernelSocketList.snapshot(.tcp)
                _ = try KernelSocketList.snapshot(.udp)
            }
            let perSample = Double(DispatchTime.now().uptimeNanoseconds - start) / Double(rounds) / 1e6
            print(String(format: "cost: %.3f ms per full sample (%.2f%% of one core at 4 Hz)", perSample, perSample * 4 / 10))

            if arguments.contains("--list") {
                for socket in sockets.sorted(by: { $0.rxBytes + $0.txBytes > $1.rxBytes + $1.txBytes }).prefix(25) {
                    let name = ProcessTable.basicInfo(of: socket.pid)?.name ?? "?"
                    let local = "\(socket.localAddress):\(socket.localPort)"
                    let remote = "\(socket.remoteAddress):\(socket.remotePort)"
                    print(
                        "  \(socket.proto.rawValue)\(family(socket)) \(local) → \(remote) \(socket.tcpStateName ?? "-") rx=\(socket.rxBytes) tx=\(socket.txBytes) \(name)(\(socket.pid))"
                    )
                }
            }

            if arguments.contains("--verify") {
                let recorded = try value(after: "--netstat-file").map {
                    try String(contentsOf: URL(fileURLWithPath: $0), encoding: .utf8)
                }
                return verify(sockets, netstatOutput: recorded)
            }
            return 0
        } catch {
            print("FAILED: \(error)")
            return 1
        }
    }

    private static func family(_ socket: KernelSocket) -> String {
        switch (socket.isIPv4, socket.isIPv6) {
        case (true, true): "46"
        case (false, true): "6"
        default: "4"
        }
    }

    /// Compares our parse with what `netstat -anv` prints a moment later.
    private static func verify(_ sockets: [KernelSocket], netstatOutput: String?) -> Int32 {
        guard let output = netstatOutput ?? NetstatReference.run() else {
            print("verify: could not run netstat")
            return 1
        }
        var theirs: [String: [NetstatReference.Row]] = [:]
        for row in NetstatReference.rows(in: output) {
            theirs["\(row.protoName)|\(row.localPort)|\(row.remotePort)|\(row.pid)", default: []].append(row)
        }
        let theirTotal = theirs.values.reduce(0) { $0 + $1.count }

        var matched = 0, onlyOurs = 0, bytesEqual = 0, bytesBehind = 0, bytesAhead = 0
        var stateChecked = 0, stateEqual = 0
        var unmatchedExamples: [String] = []
        for socket in sockets {
            let key = "\(socket.proto.rawValue)\(family(socket))|\(socket.localPort)|\(socket.remotePort)|\(socket.pid)"
            guard var candidates = theirs[key], !candidates.isEmpty else {
                onlyOurs += 1
                if unmatchedExamples.count < 5 { unmatchedExamples.append(key) }
                continue
            }
            // Several sockets can share a key; pair with the closest byte count.
            let index = candidates.indices.min { lhs, rhs in
                distance(candidates[lhs].rx, socket.rxBytes) < distance(candidates[rhs].rx, socket.rxBytes)
            }!
            let row = candidates.remove(at: index)
            theirs[key] = candidates
            matched += 1
            // netstat ran after us, so its counters can only be equal or larger.
            if row.rx == socket.rxBytes { bytesEqual += 1 } else if row.rx > socket.rxBytes { bytesBehind += 1 } else { bytesAhead += 1 }
            if let ours = socket.tcpStateName, let state = row.state {
                stateChecked += 1
                if ours == state { stateEqual += 1 }
            }
        }
        let onlyTheirs = theirs.values.reduce(0) { $0 + $1.count }

        print("verify against netstat -anv:")
        print("  ours \(sockets.count), netstat \(theirTotal)")
        print("  matched on (protocol, family, local port, remote port, pid): \(matched)")
        print("  only in ours: \(onlyOurs)   only in netstat: \(onlyTheirs)")
        if !unmatchedExamples.isEmpty { print("  unmatched examples: \(unmatchedExamples.joined(separator: "  "))") }
        print("  rx bytes: \(bytesEqual) identical, \(bytesBehind) grew before netstat ran, \(bytesAhead) lower in netstat")
        print("  tcp state: \(stateEqual) of \(stateChecked) identical")

        let total = max(sockets.count, theirTotal)
        let agreement = total == 0 ? 0 : Double(matched) / Double(total)
        let passed = agreement >= 0.97 && bytesAhead == 0 && stateEqual >= stateChecked - 2
        print(String(format: "  agreement %.1f%% — %@", agreement * 100, passed ? "PASS" : "FAIL"))
        return passed ? 0 : 1
    }

    private static func distance(_ a: UInt64, _ b: UInt64) -> UInt64 { a > b ? a - b : b - a }
}
