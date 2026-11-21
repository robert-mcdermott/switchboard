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

        MenuBarExtra("Switchboard", systemImage: "point.3.connected.trianglepath.dotted") {
            Text("Switchboard \(Switchboard.version)")
            Text(model.statusLine)
            if !model.talkers.isEmpty {
                Divider()
                ForEach(model.talkers.prefix(3)) { talker in
                    Text("\(talker.name)  \(ByteFormat.rate(talker.rate))")
                }
            }
            Divider()
            Button(model.paused ? "Resume" : "Pause") { model.togglePause() }
            Divider()
            Button("Quit Switchboard") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }

        Settings {
            SettingsView()
        }
    }
}

struct SettingsView: View {
    @AppStorage("clustering") private var clustering = "automatic"
    @AppStorage("clusterThreshold") private var clusterThreshold = 300
    @AppStorage("palette") private var palette = "standard"
    @AppStorage("historyMinutes") private var historyMinutes = 15.0
    @AppStorage("profile") private var profile = "cinema"

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
            Section("Graph") {
                Picker("Group destinations by network", selection: $clustering) {
                    Text("When there are many").tag("automatic")
                    Text("Always").tag("subnet")
                    Text("Never").tag("off")
                }
                Stepper("Group once past \(clusterThreshold) destinations", value: $clusterThreshold, in: 50...5000, step: 50)
                    .disabled(clustering != "automatic")
            }
            Section("History") {
                Stepper("Keep \(Int(historyMinutes)) minutes for the timeline", value: $historyMinutes, in: 1...60, step: 1)
                Text("History is held in memory only. A very busy machine keeps less than this, to bound memory use.")
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
