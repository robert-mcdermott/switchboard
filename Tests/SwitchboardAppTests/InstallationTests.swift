import Foundation
import Testing

@testable import SwitchboardApp

private func scratchDefaults() -> UserDefaults {
    let name = "switchboard.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@Suite struct SettingsMigrationTests {
    @Test func oldSettingsAreCarriedOverWithoutReplacingNewOnes() {
        let defaults = scratchDefaults()
        defaults.set("amber", forKey: "palette")
        let old: [String: Any] = ["palette": "neon", "layout": "globe", "showThisMac": false]
        #expect(SettingsMigration.carryOver(old, into: defaults) == 2)
        #expect(defaults.string(forKey: "palette") == "amber")
        #expect(defaults.string(forKey: "layout") == "globe")
        #expect(defaults.object(forKey: "showThisMac") as? Bool == false)
    }

    @Test func itRunsOnceSoARemovedSettingStaysRemoved() {
        let defaults = scratchDefaults()
        SettingsMigration.carryOver(["layout": "globe"], into: defaults)
        defaults.removeObject(forKey: "layout")
        #expect(SettingsMigration.carryOver(["layout": "globe"], into: defaults) == 0)
        #expect(defaults.string(forKey: "layout") == nil)
    }

    @Test func nothingToCarryOverStillMarksItDone() {
        let defaults = scratchDefaults()
        #expect(SettingsMigration.carryOver(nil, into: defaults) == 0)
        #expect(defaults.string(forKey: SettingsMigration.marker) == "local.switchboard.app")
    }
}

@Suite struct ScriptOutcomeTests {
    @Test func theSummaryIsTheLastLineWithoutItsArrow() {
        let outcome = ScriptOutcome(succeeded: true, output: "==> Installing\n    Log: /var/log/x\n==> Running. Switchboard switches to Full mode.\n\n")
        #expect(outcome.summary == "Running. Switchboard switches to Full mode.")
    }

    @Test func anEmptyOutputHasAnEmptySummary() {
        #expect(ScriptOutcome(succeeded: false, output: "\n  \n").summary == "")
    }

    @Test func outsideAnAppTheScriptsAreNotFoundAndTheCommandIsShown() {
        // The test runner is not Switchboard.app, so nothing is bundled.
        #expect(BundledScript.installCollector.url == nil)
        #expect(BundledScript.installCollector.command == "sudo scripts/install.sh")
    }
}
