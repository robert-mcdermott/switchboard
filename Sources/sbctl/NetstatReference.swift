import Foundation
import SwitchboardCore

/// `netstat -anv` as ground truth. It is Apple-signed, so it sees every socket whoever runs it.
enum NetstatReference {
    struct Row {
        /// `tcp4`, `udp6`, `tcp46` …
        var protoName: String
        var localPort: UInt16
        var remotePort: UInt16
        var pid: Int32
        var rx: UInt64
        var tx: UInt64
        /// `ESTABLISHED`, `LISTEN` … `nil` for UDP and for TCP sockets with no state shown.
        var state: String?

        var proto: TransportProtocol { protoName.hasPrefix("tcp") ? .tcp : .udp }
    }

    static func run() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        process.arguments = ["-anv"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    static func rows(in output: String) -> [Row] {
        output.split(separator: "\n").compactMap(parse)
    }

    /// One socket line. The process name may contain spaces, so the pid is located by
    /// counting fields from the right.
    static func parse(_ line: Substring) -> Row? {
        guard line.hasPrefix("tcp") || line.hasPrefix("udp") else { return nil }
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 16 else { return nil }
        guard let pidField = fields[fields.count - 9].split(separator: ":").last, let pid = Int32(pidField) else {
            return nil
        }
        func port(_ field: Substring) -> UInt16 {
            guard let last = field.split(separator: ".").last else { return 0 }
            return UInt16(last) ?? 0
        }
        let hasState = UInt64(fields[5]) == nil
        guard let rx = UInt64(fields[hasState ? 6 : 5]), let tx = UInt64(fields[hasState ? 7 : 6]) else { return nil }
        let protoName = String(fields[0])
        return Row(
            protoName: protoName, localPort: port(fields[3]), remotePort: port(fields[4]), pid: pid, rx: rx, tx: tx,
            state: hasState && protoName.hasPrefix("tcp") ? String(fields[5]) : nil)
    }
}
