import AppKit
import Foundation
import SwitchboardCore
import SwitchboardRender

/// A named arrangement of the window: which layout, how lively, what filter, which panels
/// (docs/SPEC.md §10.6).
struct Workspace: Codable, Identifiable, Equatable, Sendable {
    var name: String
    var layout = "constellation"
    var profile = "cinema"
    var filter = ""
    var panel = "connections"
    var showPanel = true
    var showInspector = true
    var keepEnded = false
    var clustering = "automatic"
    /// Full screen with nothing but the graph.
    var kiosk = false

    var id: String { name }

    /// The three that are always there. A saved workspace with the same name replaces one.
    static let builtIn: [Workspace] = [
        Workspace(name: "NOC Wall", layout: "constellation", profile: "cinema", showPanel: false, showInspector: false, kiosk: true),
        Workspace(
            name: "Privacy Audit", layout: "flow", profile: "operator", filter: "class:public", panel: "firstSeen",
            keepEnded: true),
        Workspace(name: "Developer", layout: "constellation", profile: "operator", panel: "connections"),
    ]
}

/// Everything a user can carry to another Mac: their workspaces and their settings.
struct Configuration: Codable {
    var version = 1
    var workspaces: [Workspace] = []
    var settings: [String: String] = [:]

    /// The settings that travel. The log's location and the window's size do not.
    static let keys = [
        "clustering", "clusterThreshold", "palette", "historyMinutes", "profile", "hostnames", "logging", "tagLists",
        "logDetail", "logDays", "logMegabytes", "layout", "lanesMinutes", "keepEnded", "homeLocation",
    ]

    static func current(workspaces: [Workspace], defaults: UserDefaults = .standard) -> Configuration {
        var configuration = Configuration(workspaces: workspaces)
        for key in keys {
            guard let value = defaults.object(forKey: key) else { continue }
            configuration.settings[key] = "\(value)"
        }
        return configuration
    }

    /// Writes the settings back, each as the type its reader expects.
    func apply(to defaults: UserDefaults = .standard) {
        let numbers: Set = ["clusterThreshold", "historyMinutes", "logDays", "logMegabytes", "lanesMinutes"]
        let switches: Set = ["logging", "keepEnded"]
        for (key, value) in settings where Self.keys.contains(key) {
            if numbers.contains(key) {
                if let number = Double(value) { defaults.set(key == "clusterThreshold" ? Int(number) as Any : number as Any, forKey: key) }
            } else if switches.contains(key) {
                defaults.set(value == "1" || value == "true", forKey: key)
            } else {
                defaults.set(value, forKey: key)
            }
        }
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

/// The user's saved workspaces, kept in the app's preferences.
enum WorkspaceStore {
    static let key = "workspaces"

    static func saved(in defaults: UserDefaults = .standard) -> [Workspace] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Workspace].self, from: data)) ?? []
    }

    static func save(_ workspaces: [Workspace], in defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(workspaces), forKey: key)
    }

    /// The built-in ones, each replaced by a saved one of the same name, then the rest.
    static func all(in defaults: UserDefaults = .standard) -> [Workspace] {
        let saved = saved(in: defaults)
        let replaced = Workspace.builtIn.map { original in saved.first { $0.name == original.name } ?? original }
        return replaced + saved.filter { candidate in !Workspace.builtIn.contains { $0.name == candidate.name } }
    }
}

extension AppModel {
    var mainWindow: NSWindow? { NSApplication.shared.windows.first { $0.title == "Switchboard" } }

    func setLayout(_ next: GraphLayout) {
        guard next != layout else { return }
        layout = next
        session.controller.layout = next
        // Each layout has its own shape; a zoom chosen for one is wrong for the next.
        session.resetView()
        UserDefaults.standard.set(next.rawValue, forKey: "layout")
    }

    /// What the window is showing now, as a workspace.
    func currentWorkspace(named name: String) -> Workspace {
        Workspace(
            name: name, layout: layout.rawValue, profile: profile.rawValue, filter: filter.text, panel: panelTab.rawValue,
            showPanel: showPanel, showInspector: showInspector, keepEnded: keepEnded,
            clustering: UserDefaults.standard.string(forKey: "clustering") ?? "automatic", kiosk: kiosk)
    }

    func apply(_ workspace: Workspace) {
        if let next = GraphLayout(rawValue: workspace.layout) { setLayout(next) }
        if let next = RenderProfile(rawValue: workspace.profile) { setProfile(next) }
        filterText = workspace.filter
        applyFilter()
        if let tab = PanelTab(rawValue: workspace.panel) { panelTab = tab }
        showPanel = workspace.showPanel
        showInspector = workspace.showInspector
        setKeepEnded(workspace.keepEnded)
        UserDefaults.standard.set(workspace.clustering, forKey: "clustering")
        applySettings()
        setKiosk(workspace.kiosk)
        activeWorkspace = workspace.name
    }

    func saveWorkspace(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var saved = WorkspaceStore.saved().filter { $0.name != trimmed }
        saved.append(currentWorkspace(named: trimmed))
        WorkspaceStore.save(saved)
        workspaces = WorkspaceStore.all()
        activeWorkspace = trimmed
    }

    /// Removes a saved workspace. A built-in one goes back to how it shipped.
    func deleteWorkspace(named name: String) {
        WorkspaceStore.save(WorkspaceStore.saved().filter { $0.name != name })
        workspaces = WorkspaceStore.all()
        if activeWorkspace == name { activeWorkspace = nil }
    }

    func promptToSaveWorkspace() {
        let alert = NSAlert()
        alert.messageText = "Save this arrangement as a workspace"
        alert.informativeText = "The layout, profile, filter, and panels as they are now. Using an existing name replaces it."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = activeWorkspace ?? ""
        field.placeholderString = "Name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn { saveWorkspace(named: field.stringValue) }
    }

    // MARK: - Kiosk

    /// Full screen, nothing but the graph, pointer hidden, display kept awake.
    func setKiosk(_ on: Bool) {
        guard on != kiosk else { return }
        kiosk = on
        guard let window = mainWindow else { return }
        let isFullScreen = window.styleMask.contains(.fullScreen)
        if on {
            enteredFullScreenForKiosk = !isFullScreen
            if !isFullScreen { window.toggleFullScreen(nil) }
            if wakeLock == nil {
                wakeLock = ProcessInfo.processInfo.beginActivity(
                    options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Switchboard is on display")
            }
        } else {
            if isFullScreen, enteredFullScreenForKiosk { window.toggleFullScreen(nil) }
            if let wakeLock { ProcessInfo.processInfo.endActivity(wakeLock) }
            wakeLock = nil
            NSCursor.setHiddenUntilMouseMoves(false)
        }
    }

    /// Moves the window to the next display, or to a numbered one, keeping full screen.
    func moveToDisplay(_ number: Int? = nil) {
        guard let window = mainWindow else { return }
        let screens = NSScreen.screens
        guard screens.count > 1 || number != nil else { return }
        let currentIndex = screens.firstIndex { $0 == window.screen } ?? 0
        let wanted = number.map { min(max($0, 1), screens.count) - 1 } ?? (currentIndex + 1) % screens.count
        guard wanted != currentIndex else { return }
        let wasFullScreen = window.styleMask.contains(.fullScreen)
        let place = { [weak window] in
            guard let window else { return }
            let visible = screens[wanted].visibleFrame
            let size = NSSize(width: min(window.frame.width, visible.width), height: min(window.frame.height, visible.height))
            window.setFrame(NSRect(origin: NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2), size: size), display: true)
        }
        if wasFullScreen {
            // A full-screen window cannot be moved; leave, move, and go back.
            window.toggleFullScreen(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                place()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak window] in window?.toggleFullScreen(nil) }
            }
        } else {
            place()
        }
    }

    // MARK: - Carrying settings elsewhere

    func exportConfiguration() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "switchboard-settings.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Configuration.current(workspaces: WorkspaceStore.saved()).encoded().write(to: url)
        } catch {
            failure = "Could not write settings: \(error.localizedDescription)"
        }
    }

    func importConfiguration() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let configuration = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: url))
            importConfiguration(configuration)
        } catch {
            failure = "That file is not Switchboard settings: \(error.localizedDescription)"
        }
    }

    func importConfiguration(_ configuration: Configuration) {
        configuration.apply()
        // Workspaces in the file are added to the ones here; the same name is replaced.
        var saved = WorkspaceStore.saved().filter { existing in !configuration.workspaces.contains { $0.name == existing.name } }
        saved.append(contentsOf: configuration.workspaces)
        WorkspaceStore.save(saved)
        workspaces = WorkspaceStore.all()
        applySettings()
    }
}
