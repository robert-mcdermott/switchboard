import SwiftUI
import SwitchboardCore
import SwitchboardRender

struct SwitchboardApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Switchboard") {
            ContentView(model: model)
                .frame(minWidth: 900, minHeight: 600)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1280, height: 820)

        MenuBarExtra("Switchboard", systemImage: "point.3.connected.trianglepath.dotted") {
            Text("Switchboard \(Switchboard.version)")
            Text(model.statusLine)
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
