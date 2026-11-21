import AppKit

// `--snapshot` and `--diff` render or compare images and exit without opening a window.
// Everything else is the app.
if let code = HeadlessCommand.run(CommandLine.arguments) {
    exit(code)
}
SwitchboardApp.main()
