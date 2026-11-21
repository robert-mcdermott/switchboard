import SwiftUI
import SwitchboardCore
import SwitchboardStore

/// What Switchboard collects, keeps, and sends, stated plainly (docs/SPEC.md §12).
struct AboutView: View {
    private var logPath: String { LogStore.defaultURL().path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
    private var geoPath: String { AppModel.geoDirectory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("SWITCHBOARD").font(.mono(16, .semibold)).kerning(4).foregroundStyle(Color.signal)
                    Text("Version \(Switchboard.version)").font(.mono(11)).foregroundStyle(Color.dim)
                    Text("A live picture of every network connection on this Mac. It watches; it never blocks or changes anything.")
                        .font(.system(size: 12))
                }
                section("What it reads", [
                    "The list of open sockets: which program, which addresses and ports, how many bytes each way, round-trip time, TCP state.",
                    "For each program: its name, path, account, parent, start time, and who signed it.",
                    "With the collector installed: the headers of packets, to learn names from DNS answers and the server name in TLS handshakes, and what protocol a connection really speaks. At most 2,048 bytes of each packet are looked at, and no packet contents are kept or written anywhere.",
                ])
                section("What it keeps", [
                    "A log of connections, on this Mac only, at \(logPath): process, account, path, addresses, ports, bytes, times, hostnames, country and network owner, and signature. How much and for how long is set in Settings ▸ Log, and the Log panel can erase it.",
                    "The last few minutes in memory, for the timeline. Gone when the app quits.",
                    "Its settings and workspaces, in the app's preferences.",
                    "Location databases, if you fetched them, in \(geoPath).",
                ])
                section("What it sends", [
                    "Nothing. No telemetry, no crash reports, no update checks, no account.",
                    "The one exception is a setting you must choose: \"Hostnames, looking up the rest\" asks your DNS resolver for the name of each address nothing else has named, at most five a second. It is off unless you turn it on.",
                    "It never asks the network where this Mac is; the globe's home is guessed from the time zone or set by you.",
                ])
                section("What runs with privilege", [
                    "Only the optional collector, switchboardd, installed with sudo scripts/install.sh and removed with scripts/uninstall.sh. It reads sockets and packet headers, publishes them on a socket only administrators can open, opens no network listener, changes nothing, and links no third-party code.",
                    "The app itself never runs as root and never asks for a password.",
                ])
                section("Interfaces Apple does not document", [
                    "NetworkStatistics, the kernel's socket list, and PKTAP packet capture. Each is optional at run time and reported on the Health tab, so a macOS update that breaks one costs detail rather than the app.",
                ])
                section("Data from others", [
                    "IP Geolocation by DB-IP (db-ip.com), licensed CC BY 4.0, when you have fetched it.",
                    "The globe's coastlines: Natural Earth (naturalearthdata.com), 1:110m, public domain, built in.",
                ])
            }
            .padding(24)
            .frame(maxWidth: 620, alignment: .leading)
        }
        .frame(minWidth: 520, idealWidth: 620, minHeight: 480, idealHeight: 720)
        .background(Color.field)
        .preferredColorScheme(.dark)
    }

    private func section(_ title: String, _ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.mono(10, .semibold)).kerning(1.5).foregroundStyle(Color.dim)
            ForEach(lines, id: \.self) { line in
                HStack(alignment: .top, spacing: 8) {
                    Text("·").foregroundStyle(Color.signal)
                    Text(line).font(.system(size: 12)).foregroundStyle(Color.readout).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
