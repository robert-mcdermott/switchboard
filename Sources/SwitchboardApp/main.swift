import AppKit

// `--snapshot` and `--diff` render or compare images and exit without opening a window.
// Everything else is the app.
if let code = HeadlessCommand.run(CommandLine.arguments) {
    exit(code)
}
// AppKit reads the command line as "-key value" pairs, and takes anything left over as a
// document to open; an app launched to open a document opens no window of its own. A flag
// without a value, such as --kiosk or --hide-this-mac, shifts the pairs by one and leaves a
// later value over, and the window never appeared. Switchboard opens no documents.
UserDefaults.standard.register(defaults: ["NSTreatUnknownArgumentsAsOpen": "NO"])
SwitchboardApp.main()
