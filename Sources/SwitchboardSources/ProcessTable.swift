import Darwin

/// Process facts from libproc and the process sysctl.
public enum ProcessTable {
    public static func allPIDs() -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 16_384)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [] }
        return pids.prefix(Int(count)).filter { $0 > 0 }
    }

    /// Owner and short name from the process sysctl. Readable for every process without privileges.
    public static func basicInfo(of pid: pid_t) -> (uid: uid_t, name: String)? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let name = withUnsafeBytes(of: info.kp_proc.p_comm) { cString($0) }
        return (info.kp_eproc.e_ucred.cr_uid, name)
    }

    /// Full executable path from libproc.
    public static func path(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return buffer.withUnsafeBytes { cString($0) }
    }

    /// Parent, start time and ownership from libproc.
    public static func bsdInfo(of pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }

    /// Number of sockets among the process's open file descriptors, or `nil` when they cannot be listed.
    public static func socketDescriptorCount(of pid: pid_t) -> Int? {
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return nil }
        var descriptors = [proc_fdinfo](
            repeating: proc_fdinfo(), count: Int(needed) / MemoryLayout<proc_fdinfo>.size)
        let got = descriptors.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        guard got > 0 else { return nil }
        return descriptors.prefix(Int(got) / MemoryLayout<proc_fdinfo>.size)
            .count { $0.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) }
    }

    private static func cString(_ bytes: UnsafeRawBufferPointer) -> String {
        let end = bytes.firstIndex(of: 0) ?? bytes.count
        return String(decoding: bytes[..<end], as: UTF8.self)
    }
}
