import Foundation
import Testing

@testable import SwitchboardApp

/// Preferences of their own, so a test never touches the app's.
private func scratchDefaults() -> UserDefaults {
    let name = "switchboard.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@Suite struct WorkspaceTests {
    @Test func theThreeDefaultsAreAlwaysThereAndCanBeReplaced() {
        let defaults = scratchDefaults()
        #expect(WorkspaceStore.all(in: defaults).map(\.name) == ["NOC Wall", "Privacy Audit", "Developer"])
        #expect(WorkspaceStore.all(in: defaults).first?.kiosk == true)

        var mine = Workspace(name: "NOC Wall", layout: "globe", profile: "operator")
        mine.kiosk = false
        WorkspaceStore.save([mine, Workspace(name: "Mine", layout: "lanes")], in: defaults)
        let all = WorkspaceStore.all(in: defaults)
        #expect(all.map(\.name) == ["NOC Wall", "Privacy Audit", "Developer", "Mine"])
        #expect(all[0].layout == "globe" && all[0].kiosk == false)

        // Deleting a saved one with a built-in name brings the original back.
        WorkspaceStore.save([Workspace(name: "Mine", layout: "lanes")], in: defaults)
        #expect(WorkspaceStore.all(in: defaults)[0].layout == "constellation")
    }

    @Test func aDamagedListOfWorkspacesIsIgnored() {
        let defaults = scratchDefaults()
        defaults.set(Data("not json".utf8), forKey: WorkspaceStore.key)
        #expect(WorkspaceStore.saved(in: defaults).isEmpty)
        #expect(WorkspaceStore.all(in: defaults).count == 3)
    }
}

@Suite struct ConfigurationTests {
    @Test func settingsAndWorkspacesSurviveTheTripToAnotherMac() throws {
        let here = scratchDefaults(), there = scratchDefaults()
        here.set("owner", forKey: "clustering")
        here.set(450, forKey: "clusterThreshold")
        here.set(42.0, forKey: "historyMinutes")
        here.set(false, forKey: "logging")
        here.set(true, forKey: "logSkipLoopback")
        here.set("office #5CF2A5: 10.0.0.0/8", forKey: "tagLists")
        here.set("47.61, -122.33", forKey: "homeLocation")
        here.set("/somewhere/else", forKey: "notASetting")
        let workspaces = [Workspace(name: "Desk", layout: "hierarchy", filter: "user:root")]

        let data = try Configuration.current(workspaces: workspaces, defaults: here).encoded()
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("notASetting"))
        let read = try JSONDecoder().decode(Configuration.self, from: data)
        read.apply(to: there)

        #expect(there.string(forKey: "clustering") == "owner")
        #expect(there.object(forKey: "clusterThreshold") as? Int == 450)
        #expect(there.object(forKey: "historyMinutes") as? Double == 42)
        #expect(there.object(forKey: "logging") as? Bool == false)
        #expect(there.bool(forKey: "logSkipLoopback"))
        #expect(there.string(forKey: "tagLists") == "office #5CF2A5: 10.0.0.0/8")
        #expect(there.string(forKey: "homeLocation") == "47.61, -122.33")
        #expect(there.object(forKey: "notASetting") == nil)
        #expect(read.workspaces == workspaces)
    }

    @Test func aFileFromSomewhereElseCannotSetAnythingElse() throws {
        let name = "switchboard.tests.\(UUID().uuidString)"
        let there = UserDefaults(suiteName: name)!
        defer { there.removePersistentDomain(forName: name) }
        let hostile = Configuration(version: 1, workspaces: [], settings: ["NSQuitAlwaysKeepsWindows": "1", "clusterThreshold": "lots"])
        hostile.apply(to: there)
        // Only what the import itself wrote counts; the system's own preferences show through any suite.
        let written = there.persistentDomain(forName: name) ?? [:]
        #expect(written["NSQuitAlwaysKeepsWindows"] == nil)
        #expect(written["clusterThreshold"] == nil)
        #expect(written.isEmpty)
    }
}
