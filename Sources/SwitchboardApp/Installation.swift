import Foundation
import SwitchboardCore

/// Settings saved under the identifier builds before 0.1.0 used, carried over once.
enum SettingsMigration {
    /// Where older builds kept their settings.
    static let previousDomain = Switchboard.previousIdentifierPrefix + ".app"
    /// Set once the carry-over has run, so a setting removed later is not brought back.
    static let marker = "settingsCarriedOverFrom"

    /// Copies each old setting that has no value yet. Returns how many were copied.
    @discardableResult
    static func carryOver(_ old: [String: Any]?, into defaults: UserDefaults) -> Int {
        guard defaults.object(forKey: marker) == nil else { return 0 }
        var copied = 0
        for (key, value) in old ?? [:] where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
            copied += 1
        }
        defaults.set(previousDomain, forKey: marker)
        return copied
    }

    /// Runs at launch, before anything reads a setting.
    static func runAtLaunch() {
        carryOver(UserDefaults.standard.persistentDomain(forName: previousDomain), into: .standard)
    }
}

/// The scripts `scripts/bundle.sh` puts inside the app, so a release needs no copy of the
/// repository: the collector's installer and uninstaller, and the location-data download.
enum BundledScript: String {
    case installCollector = "install-collector"
    case removeCollector = "uninstall-collector"
    case fetchLocationData = "fetch-geoip"

    /// Its place in the app, or `nil` when running outside one (`swift run`).
    var url: URL? {
        guard let url = Bundle.main.url(forResource: rawValue, withExtension: "sh"),
              FileManager.default.isExecutableFile(atPath: url.path)
        else { return nil }
        return url
    }

    /// How to run the same step by hand from a clone of the repository.
    var command: String {
        switch self {
        case .installCollector: "sudo scripts/install.sh"
        case .removeCollector: "sudo scripts/uninstall.sh"
        case .fetchLocationData: "scripts/fetch-geoip.sh"
        }
    }
}

/// What a script printed and how it ended.
struct ScriptOutcome: Sendable, Equatable {
    var succeeded: Bool
    /// The person dismissed the password dialog.
    var cancelled = false
    var output: String

    /// The last line worth showing: scripts end with what they did, or why they stopped.
    var summary: String {
        output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }.map { $0.hasPrefix("==> ") ? String($0.dropFirst(4)) : $0 } ?? ""
    }
}

enum ScriptRunner {
    /// Runs `script` as root. macOS shows its own password dialog; the app never sees the
    /// password. The path goes to AppleScript as an argument, never inside the source text.
    static func runAsAdministrator(_ script: URL) async -> ScriptOutcome {
        let source = [
            "on run argv",
            "do shell script (quoted form of item 1 of argv) & \" 2>&1\" with administrator privileges without altering line endings",
            "end run",
        ]
        let arguments = source.flatMap { ["-e", $0] } + [script.path]
        let outcome = await run(URL(fileURLWithPath: "/usr/bin/osascript"), arguments)
        // osascript reports a dismissed dialog as error -128.
        if !outcome.succeeded, outcome.output.contains("(-128)") {
            return ScriptOutcome(succeeded: false, cancelled: true, output: "Cancelled.")
        }
        return outcome
    }

    /// Runs `script` as the logged-in user.
    static func run(_ script: URL) async -> ScriptOutcome {
        await run(URL(fileURLWithPath: "/bin/bash"), [script.path])
    }

    private static func run(_ executable: URL, _ arguments: [String]) async -> ScriptOutcome {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
            } catch {
                return ScriptOutcome(succeeded: false, output: "\(error)")
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return ScriptOutcome(
                succeeded: process.terminationStatus == 0,
                output: String(decoding: data, as: UTF8.self))
        }.value
    }
}
