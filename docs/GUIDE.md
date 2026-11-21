# Switchboard guide

How to install Switchboard, what each part of it does, and what to do when something looks wrong. For the design behind it, see [SPEC.md](SPEC.md).

## Installing

### From source (recommended)

You need macOS 15 or later and Xcode or its command line tools, with Swift 6.

```bash
git clone https://github.com/robert-mcdermott/switchboard.git
```

```bash
cd switchboard && scripts/bundle.sh
```

```bash
open build/Switchboard.app
```

Nothing is downloaded during the build; Switchboard has no third-party dependencies.

### From a release zip

A release zip is not signed with a Developer ID and not notarised, so macOS blocks it until you clear the quarantine flag your browser added. Check the download, then clear the flag:

```bash
shasum -a 256 -c SHA256SUMS
```

```bash
xattr -dr com.apple.quarantine Switchboard.app bin
```

To make a release zip yourself, run `scripts/release.sh`. It tests, builds, and leaves the zip and its checksum in `build/release`.

## Standalone and Full

Switchboard runs in one of two modes, shown at the top left of the window.

**Standalone** needs nothing installed and no password. It sees the connections of the account you are logged in as. What it cannot see:

- Connections made by other accounts and by system daemons running as root (for example `mDNSResponder`, `syspolicyd`, software-update and security agents).
- Hostnames. Without packet capture there are no DNS answers or TLS handshakes to read names from, so destinations show as addresses unless you turn on active lookups (below).
- A small share of your own sockets, about 5 to 8%, which the system's statistics interface does not report to an unprivileged program.

**Full** adds a small collector, `switchboardd`, that runs as root. With it Switchboard sees every account's connections, reads hostnames from DNS answers and TLS server names, and learns what protocol a connection really speaks. The app notices the collector and switches to Full on its own.

```bash
sudo scripts/install.sh
```

```bash
sudo scripts/uninstall.sh
```

The install script builds the collector as you, copies it to `/usr/local/libexec/switchboardd`, and registers it with launchd. The uninstall script reverses each step. From a release zip, use `sudo scripts/install.sh --binary bin/switchboardd`.

## Location and network owner

Country, city, and network owner come from the free DB-IP Lite databases. Switchboard never downloads them on its own:

```bash
scripts/fetch-geoip.sh
```

Restart Switchboard afterwards. Check one address with `sbctl geo 8.8.8.8`. The data is *IP Geolocation by DB-IP*, licensed CC BY 4.0. DB-IP publishes a new file each month; run the script again whenever you like.

The globe also needs to know where this Mac is. It guesses from the time zone; to set it exactly, open Settings ▸ Globe and enter a latitude and longitude such as `47.61, -122.33`.

## The window

| Part | What it is |
|---|---|
| Top bar | The filter, the layout, the profile, and buttons for traffic within this Mac, keeping ended connections, and showing the panels and inspector |
| Graph | The connections, in one of five layouts |
| Timeline | Drag left to go back through the last 15 minutes (Settings ▸ History, up to an hour); the graph and tables follow. **Space** holds the present moment |
| Panels | Tables: connections, top talkers, throughput, protocols, interfaces, DNS, ages, first seen, trust, listening sockets, the log, health |
| Inspector | Everything about what you clicked |

### Layouts

| Key | Layout | Good for |
|---|---|---|
| **1** | Constellation | The whole machine at a glance |
| **2** | Flow | Where the bytes go: process, then protocol, then whoever owns the far end |
| **3** | Lanes | What happened when: one row per process, a bar per connection |
| **4** | Globe | Where in the world your traffic goes |
| **5** | Hierarchy | Account, process, domain, address, as a tree |

Whatever you select stays selected when you switch.

The globe faces this Mac and sways slowly either side of it. Drag it, or swipe with two fingers, to turn it to any part of the world; let go mid-swipe and it spins on and slows. It stays where you leave it until you press **0**, which turns it back home. ⌥-drag moves the view instead. Its coastlines are Natural Earth's 1:110m, which is in the public domain and built in.

### Reading the graph

- **Line thickness and pulses**: how much traffic, and which way most of it is going.
- **Colour**: what the traffic is. Teal is TLS, violet QUIC, green DNS, amber remote access, orange cleartext.
- **A red ring on a process**: unsigned, or its signature does not check out.
- **An amber ring**: signed by nobody in particular (normal for things you built or installed with Homebrew), or listening where other machines can reach it. The tooltip says which.
- **A bright ring on a destination**: this Mac has never talked to it before, according to the log.

Hover for details, click to pin them in the inspector, ⌘-click to add to the selection, double-click to focus on a neighbourhood, right-click to filter to it, expand a group, or reveal a program in Finder.

### Profiles

**Cinema** draws at up to 120 frames a second with full glow; for walls and demonstrations. **Operator** draws at 60 with less glow and more labels, at about half the CPU; for leaving open all day. **Still** has no motion at all. **P** cycles between them.

## Filtering

The filter field narrows the graph, the tables, and the log search at once.

```
process:Slack rate_out>100KB/s
user:root service:SSH
r_port:443 NOT host:*.apple.com
age>1h bytes<10KB
class:public country!=US signing=unsigned
remote:10.0.0.0/8 OR tag:office
```

`field:value` means contains, `=` and `!=` mean equals, and `<`, `>` compare numbers. Values take units (`KB/s`, `MB`, `h`), `*` wildcards, and networks in CIDR form. Combine terms with `AND`, `OR`, `NOT`, and brackets. A bare word matches process, hostname, service, and address. The **?** beside the field lists every field.

Note that a destination with no known country matches `country!=US`. Write `class:public country!=US` to leave out private addresses.

### Traffic within this Mac

Many connections never leave the machine: containers, development servers, databases, and editors talking to each other over loopback or this Mac's own address. On a developer's Mac they can be most of what there is. The laptop button in the top bar, or **L**, switches them:

- **On** (the default): everything, including traffic within this Mac.
- **Off**: only traffic to and from other machines. The graph, the tables, and the log search all leave the rest out, and a line at the top left says so.

This only changes what is shown. Whether these connections are written to the log at all is a separate setting, below.

## The log

Every connection is written to a SQLite file at `~/Library/Application Support/Switchboard/log.sqlite`. The Log panel searches it with the same filter; drag its slider to show a past moment in the graph. Settings ▸ Log sets how much detail is kept and for how long; the Log panel can erase it. *Leave out connections within this Mac* stops them being written to the log at all, which keeps it much smaller on a developer's Mac (development tools and containers can open hundreds a minute). They still show live. It is off by default; to hide them from view instead, use the laptop button (**L**). From the command line:

```bash
sbctl log query "process:Safari bytes>1MB" --since 7d
```

## Workspaces and wall displays

The **Workspace** menu holds named arrangements of layout, profile, filter, and panels. Three come with Switchboard:

- **NOC Wall**: the constellation in Cinema, full screen, nothing else.
- **Privacy Audit**: the flow layout, public destinations only, the First Seen panel open, ended connections kept.
- **Developer**: the constellation in Operator with the connections table.

Choose *Save Current as Workspace…* to add your own. *Export Settings…* and *Import Settings…* in the same menu carry workspaces and settings to another Mac as one JSON file.

**Kiosk mode** (**K**, or ⌃⌘K; **Esc** leaves) goes full screen, hides everything but the graph and the pointer, and keeps the display awake. To start a wall display that way:

```bash
/Applications/Switchboard.app/Contents/MacOS/Switchboard --workspace "NOC Wall" --display 2
```

## Keys

| Key | Does |
|---|---|
| 1 to 5 | Layout |
| Space | Hold or release the present moment |
| / | Jump to the filter |
| P | Next profile |
| E | Keep ended connections on screen |
| B, I | Show or hide the panels, the inspector |
| K | Kiosk mode |
| L | Show or hide traffic within this Mac |
| 0 | Reset zoom and pan, and turn the globe back home |
| Esc | Leave focus or kiosk mode |

## Troubleshooting

**It says Standalone, but the collector is installed.** Check it is running: `sudo launchctl print system/local.switchboard.collector`. Its log is `/var/log/switchboardd.log`. Reinstalling with `sudo scripts/install.sh` restarts it. Switchboard checks for the collector every few seconds and switches on its own.

**No hostnames, only addresses.** Hostnames come from the collector's packet capture, so Standalone has none. In Full mode, some names are never visible on the wire: encrypted DNS (DoH, DoT), Encrypted Client Hello, and iCloud Private Relay all hide them, and QUIC connections are named only through DNS. Settings ▸ Hostnames ▸ *looking up the rest* fills gaps with reverse lookups, which do send queries to your DNS resolver.

**No countries or owners.** Run `scripts/fetch-geoip.sh` and restart. Settings and the Health tab say which databases are loaded. Private addresses never have a country.

**The globe puts everything under "no location".** The same: no location database loaded, or these are addresses the database does not know.

**The graph is blank.** The Health tab names the Metal device and any error. Switchboard needs a Mac with Metal, which every Mac that runs macOS 15 has.

**macOS asks whether to reopen windows.** This happens after Switchboard was stopped while starting up. Choose either; it is harmless.

**It uses more CPU than I would like.** Switch to the Operator profile (**P**), which draws half as often. Hiding the panels (**B**) saves a little more.

**After a macOS update something is missing.** Switchboard reads some interfaces Apple does not document. The Health tab shows each source and whether it is working; a broken one costs detail, not the whole app. Please report it with the Health tab's contents.

## Privacy

Switchboard sends nothing anywhere: no telemetry, no crash reports, no update checks. The one exception is active hostname lookups, which are off unless you choose them. **Switchboard ▸ About Switchboard: What It Collects** lists exactly what is read, kept, and where.
