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
    var body: some View {
        Form {
            LabeledContent("Version", value: Switchboard.version)
            LabeledContent("Collector socket", value: Switchboard.collectorSocketPath)
            Text("Settings arrive with the operator console (M3).")
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding()
    }
}
