import Foundation
import SwitchboardCore
import SwitchboardSources

/// End-to-end checks of the live engine against things we know to be true: `netstat`,
/// traffic we generate ourselves, and the clock. This is the M1 exit test.
enum VerifyCommand {
    static func run(_ options: Options) throws -> Int32 {
        let session = try Session(sourceSpec: options.value("--source") ?? "nstat")
        try session.start()
        defer { session.stop() }
        try session.run(for: 2)

        var failures = 0
        func report(_ name: String, _ passed: Bool, _ detail: String) {
            print("\(passed ? "PASS" : "FAIL")  \(name): \(detail)")
            if !passed { failures += 1 }
        }

        let age = try checkAge(session)
        report("connection age", age.passed, age.detail)

        let attribution = try checkAttribution(session)
        report("attribution and byte totals", attribution.passed, attribution.detail)

        for lifetime in [0.010, 0.050, 0.100] {
            let short = try checkShortFlows(session, lifetime: lifetime)
            report("short flows (\(Int(lifetime * 1000)) ms)", short.passed, short.detail)
        }

        let inventory = try checkInventory(session, handshake: options.value("--netstat-handshake"))
        report("inventory against netstat", inventory.passed, inventory.detail)

        for source in session.sources {
            print("source \(source.name): \(source.health.detail)")
            if let sample = (source as? NStatSource)?.rejectedSample { print("  unreadable update: \(sample.prefix(600))") }
        }
        print(failures == 0 ? "RESULT: all checks passed" : "RESULT: \(failures) check(s) failed")
        return failures == 0 ? 0 : 1
    }

    private typealias Outcome = (passed: Bool, detail: String)

    /// Is the source's start time really the moment the socket was created?
    private static func checkAge(_ session: Session) throws -> Outcome {
        guard let listener = Loopback.listen() else { return (false, "could not open a listener") }
        defer { close(listener.fd) }
        let created = session.now
        try session.run(for: 1.5)
        guard let found = session.engine.listeners.values.first(where: { $0.local.port == listener.port }) else {
            return (false, "our own listener on port \(listener.port) was not reported")
        }
        let reported = session.engine.now - found.firstSeen
        let actual = session.engine.now - created
        let error = abs(reported - actual)
        return (error < 0.25, String(format: "socket created %.2f s ago, engine says %.2f s (off by %.0f ms)", actual, reported, error * 1000))
    }

    /// Moves a known number of bytes through `nc` over loopback and checks the engine
    /// credits them to the right process, in the right direction, to the byte.
    private static func checkAttribution(_ session: Session) throws -> Outcome {
        guard let port = Loopback.freePort() else { return (false, "no free port") }
        let bytes: UInt64 = 5_000_000

        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        server.arguments = ["-l", "127.0.0.1", "\(port)"]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        // nc stops as soon as its own input ends, so give it one that never does.
        let serverInput = Pipe()
        server.standardInput = serverInput
        try server.run()
        defer { if server.isRunning { server.terminate() } }
        try session.run(for: 0.6)

        // Hold the connection open after sending so its counters can be read.
        let client = Process()
        client.executableURL = URL(fileURLWithPath: "/bin/sh")
        client.arguments = ["-c", "(head -c \(bytes) /dev/zero; sleep 4) | /usr/bin/nc 127.0.0.1 \(port)"]
        client.standardOutput = FileHandle.nullDevice
        client.standardError = FileHandle.nullDevice
        try client.run()
        defer { if client.isRunning { client.terminate() } }
        try session.run(for: 2)

        let engine = session.engine
        let sender = engine.flows.values.first { $0.key.remote.port == port && $0.key.proto == .tcp }
        let receiver = engine.flows.values.first { $0.key.local.port == port && $0.key.proto == .tcp }
        guard let sender, let receiver else {
            return (false, "the nc connection on port \(port) was not reported (sender \(sender != nil), receiver \(receiver != nil))")
        }
        let senderName = engine.processes[sender.pid]?.name ?? "?"
        let receiverName = engine.processes[receiver.pid]?.name ?? "?"
        let passed = sender.bytesOut == bytes && receiver.bytesIn == bytes && senderName == "nc" && receiverName == "nc"
            && sender.pid != receiver.pid && sender.direction == .outbound && receiver.direction == .inbound
        return (passed, "sent \(bytes) bytes; \(senderName)(\(sender.pid)) \(sender.direction.rawValue) tx=\(sender.bytesOut), \(receiverName)(\(receiver.pid)) \(receiver.direction.rawValue) rx=\(receiver.bytesIn)")
    }

    /// Opens ten connections that each live for `lifetime` and counts how many the engine caught.
    private static func checkShortFlows(_ session: Session, lifetime: Double) throws -> Outcome {
        guard let listener = Loopback.listen() else { return (false, "could not open a listener") }
        defer { close(listener.fd) }
        let attempts = 10
        for _ in 0..<attempts {
            Loopback.flow(to: listener, lifetime: lifetime)
            try session.tick()
        }
        try session.run(for: 1)
        // Count the client side of each connection, including those already closed.
        let caught = session.engine.flows.values.count { $0.key.remote.port == listener.port }
        let closed = session.engine.flows.values.count { $0.key.remote.port == listener.port && $0.state == .closed }
        return (caught >= attempts * 99 / 100, "\(caught) of \(attempts) seen, \(closed) since reported closed")
    }

    /// Everything `netstat` lists for this user's processes should be in the engine, with matching totals.
    private static func checkInventory(_ session: Session, handshake: String?) throws -> Outcome {
        try session.run(for: 1)
        try session.tick()
        let engine = session.engine

        // netstat prints no internet sockets when it is launched by an unprivileged,
        // ad-hoc-signed process such as this one, so scripts/verify.sh runs it from the
        // shell instead: we ask by creating `<path>.request` and wait for `<path>`.
        let output: String
        if let handshake {
            FileManager.default.createFile(atPath: handshake + ".request", contents: nil)
            var waited = 0.0
            while !FileManager.default.fileExists(atPath: handshake), waited < 10 {
                Thread.sleep(forTimeInterval: 0.02)
                waited += 0.02
            }
            guard let text = try? String(contentsOfFile: handshake, encoding: .utf8) else {
                return (false, "no netstat output arrived at \(handshake)")
            }
            output = text
        } else {
            guard let text = NetstatReference.run() else { return (false, "could not run netstat") }
            output = text
        }
        guard !NetstatReference.rows(in: output).isEmpty else {
            return (false, "netstat listed no internet sockets, which is what it does when launched from this process. Run scripts/verify.sh instead")
        }

        struct Key: Hashable {
            var proto: TransportProtocol
            var localPort: UInt16
            var remotePort: UInt16
            var pid: Int32
        }

        // Unprivileged, the source only reports our own user's sockets, so compare like with like.
        let me = getuid()
        var ownership: [Int32: Bool] = [:]
        func visible(_ pid: Int32) -> Bool {
            if me == 0 { return true }
            if let known = ownership[pid] { return known }
            let mine = ProcessTable.basicInfo(of: pid)?.uid == me
            ownership[pid] = mine
            return mine
        }

        var reference: [Key: NetstatReference.Row] = [:]
        for row in NetstatReference.rows(in: output) where visible(row.pid) {
            // A TCP socket that is neither connected nor listening is not shown by the engine.
            if row.proto == .tcp, row.remotePort == 0, row.state != "LISTEN" { continue }
            // The application has closed these; the kernel is only holding the port.
            if row.state == "TIME_WAIT" || row.state == "CLOSED" { continue }
            reference[Key(proto: row.proto, localPort: row.localPort, remotePort: row.remotePort, pid: row.pid)] = row
        }

        var ours: [Key: Flow?] = [:]
        for flow in engine.flows.values where flow.state != .closed {
            ours[Key(proto: flow.key.proto, localPort: flow.key.local.port, remotePort: flow.key.remote.port, pid: flow.pid)] = flow
        }
        for listener in engine.listeners.values {
            ours[Key(proto: listener.proto, localPort: listener.local.port, remotePort: 0, pid: listener.pid)] = .some(nil)
        }

        var matched = 0, bytesChecked = 0, bytesClose = 0
        var missing: [String] = []
        var mismatches: [String] = []
        for (key, row) in reference {
            guard let entry = ours[key] else {
                if missing.count < 6 {
                    let name = ProcessTable.basicInfo(of: key.pid)?.name ?? "?"
                    missing.append("\(row.protoName) :\(key.localPort)→:\(key.remotePort) \(name)(\(key.pid)) \(row.state ?? "")")
                }
                continue
            }
            matched += 1
            if let flow = entry {
                bytesChecked += 1
                // Sent bytes only: netstat's received counter runs at about twice the true
                // figure (docs/spikes/M1-findings.md), while the attribution check above
                // confirms ours to the byte. netstat ran a moment after our sample, so
                // allow 1% or a couple of packets.
                let theirs = Double(row.tx), mine = Double(flow.bytesOut)
                if abs(theirs - mine) <= max(theirs * 0.01, 3000) {
                    bytesClose += 1
                } else if mismatches.count < 5 {
                    mismatches.append("\(row.protoName) :\(key.localPort)→:\(key.remotePort) netstat rx=\(row.rx) tx=\(row.tx), engine rx=\(flow.bytesIn) tx=\(flow.bytesOut)")
                }
            }
        }
        let extra = ours.keys.count { reference[$0] == nil }
        let coverage = reference.isEmpty ? 0 : Double(matched) / Double(reference.count)
        let agreement = bytesChecked == 0 ? 1 : Double(bytesClose) / Double(bytesChecked)
        var detail = String(
            format: "netstat lists %d sockets for %@; engine has %d of them (%.1f%%), plus %d netstat lacks; sent bytes within 1%% on %d of %d flows",
            reference.count, me == 0 ? "all users" : "this user", matched, coverage * 100, extra, bytesClose, bytesChecked)
        if !missing.isEmpty { detail += "\n      missing: " + missing.joined(separator: "; ") }
        if !mismatches.isEmpty { detail += "\n      byte mismatches: " + mismatches.joined(separator: "; ") }
        return (coverage >= 0.97 && agreement >= 0.95, detail)
    }
}
