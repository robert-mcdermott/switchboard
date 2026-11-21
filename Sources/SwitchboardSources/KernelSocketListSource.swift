import Foundation
import SwitchboardCore

/// The kernel's own list of sockets, as a source. Only root is given the list
/// (docs/spikes/M0-findings.md), so this runs in the collector, where it catches the
/// sockets NetworkStatistics leaves out.
///
/// Its received-byte counter runs at about twice the true figure
/// (docs/spikes/M1-findings.md), so received bytes are reported as zero rather than as a
/// number known to be wrong. When NetworkStatistics also reports a socket, its figures
/// are the ones used.
public final class KernelSocketListSource: FlowSource, @unchecked Sendable {
    public let name = "kernel"

    private let lock = NSLock()
    private let interval: Double
    private var lastPoll: EngineTime = -.infinity
    private var known = Set<UInt64>()
    private var names: [Int32: String] = [:]
    private var status = "not started"
    private var working = false

    public init(interval: Double = 1.0) {
        self.interval = interval
    }

    public func start() throws {}
    public func stop() {}

    public var health: SourceHealth {
        lock.withLock { SourceHealth(running: working, detail: status) }
    }

    public func poll(now: EngineTime) -> [SourceEvent] {
        lock.lock()
        defer { lock.unlock() }
        guard now - lastPoll >= interval - 0.01 else { return [] }
        lastPoll = now

        var sockets: [KernelSocket] = []
        do {
            for proto in TransportProtocol.allCases {
                sockets.append(contentsOf: try KernelSocketList.snapshot(proto).sockets)
            }
        } catch {
            working = false
            status = "\(error)"
            return []
        }
        guard !sockets.isEmpty else {
            // The kernel answers everyone, but only fills the list in for root.
            working = false
            status = "the kernel returned no sockets (this needs root)"
            return []
        }

        var events: [SourceEvent] = []
        var present = Set<UInt64>()
        for socket in sockets {
            var state: TCPState?
            if let raw = socket.tcpState {
                guard TCPState.allCases.indices.contains(Int(raw)) else { continue }
                state = TCPState.allCases[Int(raw)]
                // The application has closed these; the kernel is only holding the port.
                if state == .timeWait || state == .closed { continue }
            }
            // The socket's kernel address, mixed with its generation so a reused slot is a new socket.
            let id = socket.socketID ^ (socket.generation &* 0x9E37_79B9_7F4A_7C15)
            present.insert(id)
            let name: String
            if let cached = names[socket.pid] {
                name = cached
            } else {
                name = ProcessTable.basicInfo(of: socket.pid)?.name ?? "pid \(socket.pid)"
                names[socket.pid] = name
            }
            events.append(.seen(SocketObservation(
                sourceID: id, proto: socket.proto,
                local: Endpoint(address: socket.localAddress, port: socket.localPort),
                remote: Endpoint(address: socket.remoteAddress, port: socket.remotePort),
                pid: socket.pid, processName: name, rxBytes: 0, txBytes: socket.txBytes,
                rxPackets: socket.rxPackets, txPackets: socket.txPackets, tcpState: state)))
        }
        for id in known.subtracting(present).sorted() { events.append(.removed(sourceID: id)) }
        known = present
        if names.count > 4096 { names.removeAll() }
        working = true
        status = "\(present.count) sockets"
        return events
    }
}
