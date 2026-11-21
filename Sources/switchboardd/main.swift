import Foundation
import SwitchboardCore
import SwitchboardSources

// The collector. Runs the sources that need privilege and publishes what they report to
// local clients over a Unix domain socket. It reads nothing but a client's hello, opens no
// network listener, changes nothing on the system, and links no third-party code.
//
//   sudo switchboardd                          serve /var/run/switchboard.sock
//   switchboardd --socket /tmp/sb.sock         unprivileged, for development

let arguments = CommandLine.arguments
func value(_ flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}

if arguments.contains("--help") || arguments.contains("-h") {
    print("usage: switchboardd [--socket PATH]\nDefault socket: \(Switchboard.collectorSocketPath) (needs root).")
    exit(0)
}

// Kept global so the signal handler, which cannot capture anything, can remove it.
nonisolated(unsafe) var socketPath = value("--socket") ?? Switchboard.collectorSocketPath

func log(_ message: String) {
    FileHandle.standardError.write(Data("switchboardd: \(message)\n".utf8))
}

// NetworkStatistics first: it has true counters, RTT, and events. The kernel's own list
// second: complete, and only readable by root.
let sources: [any FlowSource] = [NStatSource(counterInterval: 1.0), KernelSocketListSource()]
let server = CollectorServer(path: socketPath, sources: sources, resolver: LibProcResolver())

do {
    try server.start()
} catch {
    log("\(error)")
    if geteuid() != 0, value("--socket") == nil { log("the default socket needs root: run with sudo, or pass --socket PATH") }
    exit(1)
}

for name in [SIGINT, SIGTERM] {
    signal(name) { _ in
        unlink(socketPath)
        _exit(0)
    }
}

log("version \(Switchboard.version) serving \(socketPath) as uid \(geteuid())\(geteuid() == 0 ? "" : " (not root: only this account's sockets will be seen)")")

let started = DispatchTime.now().uptimeNanoseconds
var tick = 0
while true {
    let now = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
    server.tick(now: now, includeHealth: tick % 4 == 0)
    tick += 1
    Thread.sleep(forTimeInterval: 0.25)
}
