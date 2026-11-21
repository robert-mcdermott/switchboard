import Darwin
import Foundation
import SwitchboardCore

/// Process detail from libproc and the process sysctl.
///
/// Path, owner, and name are readable for every process. Parent and start time are only
/// readable for our own processes unless we are root; when they are missing the record is
/// marked `restricted` (docs/spikes/M0-findings.md, S6).
public struct LibProcResolver: ProcessResolver {
    public init() {}

    public func resolve(pid: Int32, name: String, uniqueID: UInt64?) -> ProcessRecord {
        var record = ProcessRecord(pid: pid, uniqueID: uniqueID, name: name)

        if let path = ProcessTable.path(of: pid) {
            record.path = path
            // The kernel's short name is cut at 16 characters; the path has all of it.
            let full = URL(fileURLWithPath: path).lastPathComponent
            if !full.isEmpty { record.name = full }
        }
        if let basic = ProcessTable.basicInfo(of: pid) {
            record.uid = basic.uid
            record.username = Self.username(for: basic.uid)
            if record.path == nil, name.isEmpty || name == "?" { record.name = basic.name }
        }
        if let info = ProcessTable.bsdInfo(of: pid) {
            record.parentPID = Int32(info.pbi_ppid)
            record.startTime = Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1e6
        } else {
            record.restricted = true
        }
        return record
    }

    static func username(for uid: uid_t) -> String? {
        var entry = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 1024)
        guard getpwuid_r(uid, &entry, &buffer, buffer.count, &result) == 0, result != nil, let name = entry.pw_name
        else { return nil }
        return String(cString: name)
    }
}
