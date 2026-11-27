# Switchboard guide

How to install Switchboard, what each part of it does, and what to do when something looks wrong. For the design behind it, see [SPEC.md](SPEC.md).

## Installing

Switchboard needs a Mac with Apple silicon (M1 or later) and macOS 15 or later. It has only been tested on macOS 27.

### With the installer (recommended)

```bash
curl -fsSL https://github.com/robert-mcdermott/switchboard/releases/latest/download/install.sh | bash
```

The installer:

1. checks this is an Apple silicon Mac on macOS 15 or later;
2. downloads the release's zip and checks it against the SHA-256 written into the installer, so it installs nothing that differs from what was released;
3. puts Switchboard.app in /Applications, quitting and replacing a copy already there;
4. asks whether to install the collector ([Full mode](#standalone-and-full)), with `sudo`, which asks for your password; a collector already installed is updated without asking, so it matches the app;
5. asks whether to download the location databases, unless you have them;
6. opens Switchboard.

Run it again to update. To read it before running it, download it with `curl -fsSL <the address above> -o install.sh`, read it, then `bash install.sh`. Options, after `bash -s --` when piping:

| Option | Does |
|---|---|
| `--collector`, `--no-collector` | Install or update the collector, or leave it alone, without asking |
| `--geoip`, `--no-geoip` | Download the location databases, or not, without asking |
| `--yes` | Ask nothing: install the app, and update a collector already installed |
| `--dir DIR` | Put the app in DIR, such as `~/Applications`, instead of /Applications |
| `--no-open` | Do not open the app afterwards |
| `--zip FILE` | Install from a zip already downloaded; it is still checked against the release |
| `--uninstall` | Remove the collector and the app, and ask before removing your log, databases, and settings |

The installer downloads with `curl`, which does not mark files as quarantined, so macOS opens the app without the warning described in [From the zip](#from-the-zip).

### From the zip

Download `Switchboard-<version>-arm64.zip` from the [releases page](https://github.com/robert-mcdermott/switchboard/releases), open it, and drag Switchboard.app to Applications. Switchboard is signed ad hoc, not with a Developer ID, and is not notarised, so the first time you open it macOS says it cannot check it. Open System Settings ▸ Privacy & Security, scroll to Security, and click **Open Anyway**; you are asked once. To check the zip first, compare `shasum -a 256 Switchboard-<version>-arm64.zip` with the release's `SHA256SUMS`.

Everything else is in the app: the Health tab installs the collector and Settings ▸ Location downloads the location data.

### From source

You need Xcode or its command line tools, with Swift 6.

```bash
git clone https://github.com/robert-mcdermott/switchboard.git
```

```bash
cd switchboard && scripts/bundle.sh
```

```bash
open build/Switchboard.app
```

Nothing is downloaded during the build; Switchboard has no third-party dependencies. `scripts/release.sh` tests and builds a release in `build/release`: the zip, `install.sh` with the zip's checksum filled in, and `SHA256SUMS`. With `--publish` it creates the GitHub release from them, from a clean `main` that has been pushed.

### What goes where

| What | Where |
|---|---|
| The app, with the collector, `sbctl`, and the scripts it runs inside it | `/Applications/Switchboard.app` |
| The collector, once installed | `/usr/local/libexec/switchboardd`, started by `/Library/LaunchDaemons/io.github.robert-mcdermott.switchboard.collector.plist`, logging to `/var/log/switchboardd.log` |
| The log and the location databases | `~/Library/Application Support/Switchboard` |
| Settings and workspaces | The app's preferences, `io.github.robert-mcdermott.switchboard.app` |

Builds before 0.1.0 used the identifier `local.switchboard`. The first launch of 0.1.0 carries their settings over, and installing the collector replaces the old one.

## Standalone and Full

Switchboard runs in one of two modes, shown at the top left of the window.

**Standalone** needs nothing installed and no password. It sees the connections of the account you are logged in as. What it cannot see:

- Connections made by other accounts and by system daemons running as root (for example `mDNSResponder`, `syspolicyd`, software-update and security agents).
- Hostnames. Without packet capture there are no DNS answers or TLS handshakes to read names from, so destinations show as addresses unless you turn on active lookups ([Troubleshooting](#troubleshooting) says how).
- A small share of your own sockets, about 5 to 8%, which the system's statistics interface does not report to an unprivileged program.
- New connections for their first few seconds. The system reports other programs' new connections to an ordinary program only when they close, so Switchboard asks afresh every 5 seconds: a new connection appears within that time and is live from then on, and one that lasts less than that appears only once it has ended.

**Full** adds a small collector, `switchboardd`, that runs as root. With it Switchboard sees every account's connections, reads hostnames from DNS answers and TLS server names, and learns what protocol a connection really speaks. The app notices the collector and switches to Full on its own.

To install it, press **Install Collector…** on the Health tab, or answer yes when the installer asks. macOS asks for an administrator's password; Switchboard never sees it. The same tab has **Remove Collector…**, and **Update Collector…** when the collector is a different version from the app. From a clone:

```bash
sudo scripts/install.sh
```

```bash
sudo scripts/uninstall.sh
```

Installing copies the collector to `/usr/local/libexec/switchboardd`, owned by root, and registers it with launchd; from a clone it builds the collector first, as you, and the app installs the copy it carries. Removing reverses each step.

## Location and network owner

Country, city, and network owner come from the free DB-IP Lite databases, about 130 MB. Switchboard downloads them only when you ask: press **Download Location Data** in Settings ▸ Location, or answer yes when the installer asks. The app uses them as soon as they arrive. DB-IP publishes new ones a day or two into each month; press **Download Again** whenever you like. From a clone, `scripts/fetch-geoip.sh` does the same, and the app reads the files at its next start.

Check one address with `sbctl geo 8.8.8.8`. The data is *IP Geolocation by DB-IP*, licensed CC BY 4.0.

The globe also needs to know where this Mac is. It guesses from the time zone; to set it exactly, open Settings ▸ Globe and enter a latitude and longitude such as `47.61, -122.33`.

## The window

| Part | What it is |
|---|---|
| Top bar | The filter, the layout, the profile, and buttons for traffic within this Mac, keeping ended connections, and showing the panels and inspector |
| Graph | The connections, in one of six layouts |
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
| **6** | Cyberspace | The address space as a floor, in 3D, to fly through |

Whatever you select stays selected when you switch.

### Cyberspace

The floor is the address space. IPv4 is the square on the left and IPv6's global addresses (2000::/3) the one on the right. Addresses run along a Hilbert curve, which keeps neighbouring addresses together, so each block of addresses is a block of floor. The grid divides each square into 16 × 16 blocks: an IPv4 /8 apiece, labelled where something stands in it (`52/8`), or an IPv6 /11 (`2600::/11`). Link-local and unique-local IPv6 addresses stand in the gap between the squares, under this Mac.

- **A tower** stands on each destination's address. Height is the bytes it has carried, brightness its current rate, colour the kind of traffic, and pulses climb it as fast as the traffic goes. A bright ring at the top means never seen before.
- **This Mac** floats over the gap, with a pillar of light to the floor, and its processes in a ring below it. **Beams** arc from each process to each tower it is talking to.
- Where many towers crowd one block, each is drawn thinner and fainter, and very dense scenes get less bloom, so a busy block reads as a cluster rather than a white column.

| Do | To |
|---|---|
| Nothing | It orbits once every five minutes (not in Still) |
| Drag, or swipe with two fingers | Orbit; let go mid-swipe and it carries on and slows |
| Scroll, or pinch | Move in and out |
| W A S D, or the arrows | Fly across the floor |
| Double-click a tower | Fly to it, and focus on it |
| 0 | Back to the starting view; the orbit resumes |

Hover, click, right-click, and the filter work as in every other layout.

The globe faces this Mac and sways slowly either side of it. Drag it, or swipe with two fingers, to turn it to any part of the world; let go mid-swipe and it spins on and slows. It stays where you leave it until you press **0**, which turns it back home. ⌥-drag moves the view instead. Its coastlines are Natural Earth's 1:110m, which is in the public domain and built in.

### Reading the graph

- **Line thickness and pulses**: how much traffic, and which way most of it is going.
- **Colour**: what the traffic is. Teal is TLS, violet QUIC, green DNS, amber remote access, orange cleartext.
- **A red ring on a process**: unsigned, or its signature does not check out.
- **An amber ring**: signed by nobody in particular (normal for things you built or installed with Homebrew), or listening where other machines can reach it. The tooltip says which.
- **A bright ring on a destination**: this Mac has never talked to it before, according to the log.

Scroll or pinch to zoom. Zooming in spreads things apart much faster than it enlarges them, the way markers on a map stay small: at ten times the zoom, distances are ten times larger but dots and lines only about twice the size, so a crowded patch opens up instead of just getting bigger. **0** zooms back out.

Hover for details, click to pin them in the inspector, ⌘-click to add to the selection, double-click to focus on a neighbourhood, right-click to filter to it, expand a group, or reveal a program in Finder.

### Profiles

**Cinema** draws at up to 120 frames a second with full glow; for walls and demonstrations. **Operator** draws at 60 with less glow and more labels, at about half the CPU; for leaving open all day. **Still** has no motion at all. **P** cycles between them.

### Themes

**T** cycles through six colour themes, and Settings ▸ Display ▸ Theme picks one. The choice is kept, and travels with exported settings.

| Theme | Looks like |
|---|---|
| Standard | Cyan, violet, and green on deep navy |
| Neon | Magenta and cyan on deep violet |
| Phosphor | A green phosphor terminal |
| Amber | An amber terminal |
| Ice | Pale blues and whites on blue-black; the quietest |
| Colour-safe | Hues that stay distinct with the common colour-vision deficiencies |

Every theme keeps a colour of its own for each kind of traffic, a red ring for a program whose signature fails, and warm colours for remote access and cleartext. All are dark: the graph adds light to its background, as a radar screen does. The panels and controls stay as they are.

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

This only changes what is shown. Whether these connections are written to the log at all is a separate setting, in [The log](#the-log).

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
| 1 to 6 | Layout |
| Space | Hold or release the present moment |
| / | Jump to the filter |
| P | Next profile |
| E | Keep ended connections on screen |
| B, I | Show or hide the panels, the inspector |
| K | Kiosk mode |
| L | Show or hide traffic within this Mac |
| T | Next colour theme |
| W A S D, arrows | Fly, in the cyberspace layout |
| 0 | Reset zoom and pan, and turn the globe back home |
| Esc | Leave focus or kiosk mode |

## Troubleshooting

**The installer says the download does not match the release's checksum.** The 0.1.0 installer said this whenever the check could not run, not only when the download was wrong. Two things stopped it running: an Intel-only `shasum` left in `/usr/local/bin` by an old Homebrew, which cannot run on a Mac without Rosetta, and Perl settings such as `PERL5LIB`, which can break macOS's own `shasum`. Run the install command again to get the current installer, which uses only macOS's own tools. If it still finds a difference, it shows what arrived instead. A few kilobytes of HTML means a proxy or web filter on your network replaced the download: try another network, or install [from the zip](#from-the-zip).

**It says Standalone, but the collector is installed.** Check it is running: `sudo launchctl print system/io.github.robert-mcdermott.switchboard.collector`. Its log is `/var/log/switchboardd.log`. Reinstalling from the Health tab, or with `sudo scripts/install.sh`, restarts it. Switchboard checks for the collector every few seconds and switches on its own.

**No hostnames, only addresses.** Hostnames come from the collector's packet capture, so Standalone has none. In Full mode, some names are never visible on the wire: encrypted DNS (DoH, DoT), Encrypted Client Hello, and iCloud Private Relay all hide them, and QUIC connections are named only through DNS. Settings ▸ Hostnames ▸ *looking up the rest* fills gaps with reverse lookups, which do send queries to your DNS resolver.

**No countries or owners.** Press **Download Location Data** in Settings ▸ Location. Settings and the Health tab say which databases are loaded. Private addresses never have a country.

**The globe puts everything under "no location".** The same: no location database loaded, or these are addresses the database does not know.

**The graph is blank.** The Health tab names the Metal device and any error. Switchboard needs a Mac with Metal, which every Mac that runs macOS 15 has.

**macOS asks whether to reopen windows.** This happens after Switchboard was stopped while starting up. Choose either; it is harmless.

**A download shows little received traffic, then a spike when it ends.** Builds before 21 November 2026 did this: the system tells an ordinary program about other programs' new connections only when they close. Switchboard now asks afresh every few seconds, so a new connection appears within about 5 seconds (10 with the collector) and is live from then on. In Full mode, update the collector from the Health tab to get the fix there too. The Health tab's NetworkStatistics line shows how often it renews, and in Full mode how many of the connections the kernel lists it is reporting.

**It uses more CPU than I would like.** Switch to the Operator profile (**P**), which draws half as often. Hiding the panels (**B**) saves a little more.

**After a macOS update something is missing.** Switchboard reads some interfaces Apple does not document. The Health tab shows each source and whether it is working; a broken one costs detail, not the whole app. Please report it with the Health tab's contents.

## Privacy

Switchboard sends nothing anywhere: no telemetry, no crash reports, no update checks. The one exception is active hostname lookups, which are off unless you choose them. **Switchboard ▸ About Switchboard: What It Collects** lists exactly what is read, kept, and where.
