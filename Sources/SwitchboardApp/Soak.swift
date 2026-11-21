import AppKit
import Foundation
import SwitchboardCore
import SwitchboardRender

/// A long unattended run that writes down, once a minute, what it costs: memory, CPU,
/// frames, the log's size, and the collector's own memory and CPU.
///
///   Switchboard --soak soak.csv --hours 8
///
/// The run keeps the Mac from idle sleep (not the display) for its length, then quits.
@MainActor
final class SoakRecorder {
    private let url: URL
    private let end: Date
    private let model: AppModel
    private var lastCPU = SoakRecorder.processCPU()
    private var lastCollectorCPU: Double?
    private var lastSample = Date()
    private let started = Date()
    private var activity: NSObjectProtocol?

    init(path: String, hours: Double, model: AppModel) {
        url = URL(fileURLWithPath: path)
        end = Date().addingTimeInterval(hours * 3600)
        self.model = model
    }

    static let header = "elapsed_min,app_rss_mb,app_cpu_pct,fps,p99_frame_ms,worst_frame_ms,open_flows,processes,listeners,log_mb,collector_rss_mb,collector_cpu_pct,mode"

    func start() {
        try? (Self.header + "\n").write(to: url, atomically: true, encoding: .utf8)
        activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled], reason: "Switchboard soak run")
        Task { @MainActor in
            while Date() < end {
                try? await Task.sleep(for: .seconds(60))
                sample()
            }
            if let activity { ProcessInfo.processInfo.endActivity(activity) }
            NSApplication.shared.terminate(nil)
        }
    }

    private func sample() {
        let now = Date()
        let wall = now.timeIntervalSince(lastSample)
        lastSample = now
        let cpu = Self.processCPU()
        let appCPU = (cpu - lastCPU) / wall * 100
        lastCPU = cpu
        let frames = model.session.stats.summary()
        model.session.stats.reset()

        var collectorRSS = "", collectorCPU = ""
        if let (rss, time) = Self.collector() {
            collectorRSS = String(format: "%.1f", rss / 1_048_576)
            if let last = lastCollectorCPU { collectorCPU = String(format: "%.2f", (time - last) / wall * 100) }
            lastCollectorCPU = time
        }
        let snapshot = model.latest
        let line = [
            String(format: "%.1f", now.timeIntervalSince(started) / 60),
            String(format: "%.1f", Self.residentBytes() / 1_048_576),
            String(format: "%.2f", appCPU),
            String(format: "%.1f", frames.framesPerSecond),
            String(format: "%.1f", frames.p99IntervalMS),
            String(format: "%.1f", frames.worstIntervalMS),
            "\(snapshot?.flows.count { $0.state != .closed } ?? 0)",
            "\(snapshot?.processes.count ?? 0)",
            "\(snapshot?.listeners.count ?? 0)",
            String(format: "%.1f", model.logFileBytes() / 1_048_576),
            collectorRSS, collectorCPU, "\(model.summary.mode)",
        ].joined(separator: ",")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data((line + "\n").utf8))
            try? handle.close()
        }
    }

    static func processCPU() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
    }

    static func residentBytes() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.resident_size) : 0
    }

    /// The collector's resident memory in bytes and CPU time in seconds, from `ps`, which
    /// may read any process's figures without privilege.
    static func collector() -> (Double, Double)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "rss=,time=,comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where line.hasSuffix("switchboardd") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3, let rss = Double(parts[0]) else { continue }
            // CPU time as [[dd-]hh:]mm:ss.ss
            var seconds = 0.0
            for (index, piece) in parts[1].split(separator: ":").reversed().enumerated() {
                let value = Double(piece.split(separator: "-").last ?? "0") ?? 0
                seconds += value * [1, 60, 3600][min(index, 2)]
            }
            return (rss * 1024, seconds)
        }
        return nil
    }
}
