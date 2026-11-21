import SwiftUI
import SwitchboardCore
import SwitchboardRender

struct SwitchboardApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Switchboard") {
            ContentView(model: model)
                .frame(minWidth: 1000, minHeight: 640)
                .preferredColorScheme(.dark)
                .tint(Color(red: 0.13, green: 0.55, blue: 0.68))
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandMenu("Workspace") {
                ForEach(Array(GraphLayout.allCases.enumerated()), id: \.element) { offset, layout in
                    Button(layout.rawValue.capitalized) { model.setLayout(layout) }
                        .keyboardShortcut(KeyEquivalent(Character("\(offset + 1)")), modifiers: .command)
                }
                Divider()
                ForEach(model.workspaces) { workspace in
                    Button((model.activeWorkspace == workspace.name ? "✓ " : "") + workspace.name) { model.apply(workspace) }
                }
                Divider()
                Button("Save Current as Workspace…") { model.promptToSaveWorkspace() }
                if let active = model.activeWorkspace, WorkspaceStore.saved().contains(where: { $0.name == active }) {
                    Button(Workspace.builtIn.contains { $0.name == active } ? "Restore “\(active)” to Default" : "Delete “\(active)”") {
                        model.deleteWorkspace(named: active)
                    }
                }
                Divider()
                Button(model.kiosk ? "Leave Kiosk Mode" : "Enter Kiosk Mode") { model.setKiosk(!model.kiosk) }
                    .keyboardShortcut("k", modifiers: [.command, .control])
                Button("Move to Next Display") { model.moveToDisplay() }
                    .keyboardShortcut("d", modifiers: [.command, .control])
                Divider()
                Button("Export Settings…") { model.exportConfiguration() }
                Button("Import Settings…") { model.importConfiguration() }
            }
        }

        // The menu's figures are refreshed every few seconds, and read in a view of their own:
        // read here, every change of them rebuilt the whole scene and redrew the menu bar.
        MenuBarExtra("Switchboard", systemImage: "point.3.connected.trianglepath.dotted") {
            StatusMenu(model: model)
        }

        Settings {
            SettingsView()
        }
    }
}

struct StatusMenu: View {
    let model: AppModel

    var body: some View {
        Text("Switchboard \(Switchboard.version)")
        ForEach(model.menuLines, id: \.self) { line in Text(line) }
        Divider()
        Button(model.paused ? "Resume" : "Pause") { model.togglePause() }
        Divider()
        Button("Quit Switchboard") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}

struct SettingsView: View {
    static var guessedHome: String {
        let point = GeoPoint.guess()
        return String(format: "%.2f, %.2f (from the time zone)", point.latitude, point.longitude)
    }

    @AppStorage("clustering") private var clustering = "automatic"
    @AppStorage("clusterThreshold") private var clusterThreshold = 300
    @AppStorage("palette") private var palette = "standard"
    @AppStorage("historyMinutes") private var historyMinutes = 15.0
    @AppStorage("profile") private var profile = "cinema"
    @AppStorage("hostnames") private var hostnames = "passive"
    @AppStorage("logging") private var logging = true
    @AppStorage("tagLists") private var tagLists = ""
    @AppStorage("lanesMinutes") private var lanesMinutes = 10.0
    @AppStorage("homeLocation") private var homeLocation = ""
    @AppStorage("logDetail") private var logDetail = "standard"
    @AppStorage("logDays") private var logDays = 30.0
    @AppStorage("logMegabytes") private var logMegabytes = 2000.0

    var body: some View {
        Form {
            Section("Display") {
                Picker("Profile at launch", selection: $profile) {
                    Text("Cinema").tag("cinema")
                    Text("Operator").tag("operator")
                    Text("Still").tag("still")
                }
                Picker("Colours", selection: $palette) {
                    Text("Standard").tag("standard")
                    Text("Colour-safe").tag("colorSafe")
                }
                Text("Colour-safe uses hues that stay distinct with the common colour-vision deficiencies.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Hostnames") {
                Picker("Label destinations with", selection: $hostnames) {
                    Text("Hostnames where known").tag("passive")
                    Text("Hostnames, looking up the rest").tag("active")
                    Text("Addresses only").tag("off")
                }
                Text(hostnames == "active"
                    ? "Switchboard will ask your DNS resolver for the name of each address nothing else has named. Those lookups are network traffic of its own, visible to your resolver, at most five a second."
                    : "Names come from DNS answers and TLS handshakes the collector sees. Switchboard sends nothing itself.")
                    .font(.caption)
                    .foregroundStyle(hostnames == "active" ? .orange : .secondary)
            }
            Section("Graph") {
                Picker("Group destinations by network", selection: $clustering) {
                    Text("When there are many").tag("automatic")
                    Text("Always").tag("subnet")
                    Text("Never").tag("off")
                    Text("By network owner instead").tag("owner")
                    Text("By country instead").tag("country")
                }
                Stepper("Group once past \(clusterThreshold) destinations", value: $clusterThreshold, in: 50...5000, step: 50)
                    .disabled(clustering != "automatic")
            }
            Section("Your address lists") {
                TextEditor(text: $tagLists)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(height: 70)
                Text("One list per line, a colour optional:  office #5CF2A5: 10.0.0.0/8, 192.168.1.0/24\nDestinations on a list take its colour, and the filter field tag: finds them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Location and network owner") {
                Text("Country, city, and network owner come from database files in\n~/Library/Application Support/Switchboard/GeoIP. Switchboard never downloads them; run scripts/fetch-geoip.sh to fetch the free DB-IP Lite databases (IP Geolocation by DB-IP, CC BY 4.0), then restart.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Globe") {
                TextField("Where this Mac is", text: $homeLocation, prompt: Text(Self.guessedHome))
                Text(GeoPoint(homeLocation) != nil || homeLocation.isEmpty
                    ? "Latitude and longitude, such as 47.61, -122.33. Left empty, it is guessed from the time zone; Switchboard never asks the network where it is."
                    : "Not a latitude and longitude. Write it as 47.61, -122.33.")
                    .font(.caption)
                    .foregroundStyle(GeoPoint(homeLocation) != nil || homeLocation.isEmpty ? Color.secondary : Color.orange)
            }
            Section("Lanes layout") {
                Picker("Time shown", selection: $lanesMinutes) {
                    Text("1 minute").tag(1.0)
                    Text("5 minutes").tag(5.0)
                    Text("10 minutes").tag(10.0)
                    Text("30 minutes").tag(30.0)
                    Text("1 hour").tag(60.0)
                }
                Text("Connections that ended before Switchboard was showing the lanes are not drawn unless “keep ended connections” is on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("History") {
                Stepper("Keep \(Int(historyMinutes)) minutes for the timeline", value: $historyMinutes, in: 1...60, step: 1)
                Text("History is held in memory only. A very busy machine keeps less than this, to bound memory use.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Log") {
                Toggle("Record connections to a local log", isOn: $logging)
                Picker("Detail", selection: $logDetail) {
                    Text("Connections only").tag("summary")
                    Text("Connections, DNS answers, listeners").tag("standard")
                    Text("All of that, and a byte count each second").tag("detailed")
                }
                .disabled(!logging)
                Stepper("Keep \(Int(logDays)) days", value: $logDays, in: 1...365, step: 1).disabled(!logging)
                Stepper("Keep at most \(Int(logMegabytes)) MB", value: $logMegabytes, in: 100...20_000, step: 100).disabled(!logging)
                Text("The log stays on this Mac, in Application Support. Turning logging on or off, or changing the detail, takes effect the next time Switchboard starts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("About") {
                LabeledContent("Version", value: Switchboard.version)
                LabeledContent("Collector socket", value: Switchboard.collectorSocketPath)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }
}
