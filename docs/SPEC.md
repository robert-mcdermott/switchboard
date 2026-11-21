# Switchboard — Technical Specification

A real-time network observatory for macOS. Every connection on the machine, who owns it, where it goes, and how hard it is working — drawn as a living graph that an operator can read at a glance and interrogate in seconds.

**Status:** v0.1 draft · **Companion:** [ROADMAP.md](ROADMAP.md)

---

## 1. Product in one page

Switchboard answers three questions, in this order of priority:

1. **What is talking?** Every TCP/UDP socket on the Mac, attributed to a process and a user.
2. **To whom, and how much?** Remote endpoint, service, live rate, lifetime totals, connection age.
3. **Is that normal?** New destinations, unsigned binaries, exposed listeners, long-lived low-volume flows.

It is a monitor, not a firewall. It never sits inline with traffic, never stores payloads, and never talks to the network on its own behalf.

### Pillars

| Pillar | What it means in practice |
|---|---|
| **Truthful** | Every number on screen is traceable to a kernel source. Inferred values (service names, approximate ages, hostnames) carry a visible provenance marker. |
| **Instant** | From launch to a live graph in under two seconds, with no setup. Privilege is an upgrade, not a prerequisite. |
| **Cinematic, but earned** | The look is dark, luminous, and in motion — and every glow, particle, and pulse encodes data. Nothing animates for decoration alone. |
| **Self-contained** | No Apple Developer account, no entitlements, no notarization, no telemetry, no cloud. Builds with the Swift toolchain alone. |

### The five-second test

The product succeeds when an operator can point at any connection and name the responsible process, its user, its destination, and its throughput within five seconds. Every design decision below is in service of that.

---

## 2. Where this spec departs from the research draft

The research document is the source of requirements. This spec keeps its goals and changes several engineering decisions, mostly because of what probing the development Mac turned up (§3).

| Topic | Research draft | This spec | Why |
|---|---|---|---|
| Naming | Mixed "Switchboard" / "Meridian" | **Switchboard** everywhere: `switchboardd`, `sbctl`, `/var/run/switchboard.sock` | One name |
| First run | Collector must be installed as root before anything works | **Standalone mode** works with no privileges; the root collector is an upgrade to **Full mode** | An unprivileged process can already list every socket on the machine with PID and byte counters (§3) |
| Traffic rates | Count every packet through PKTAP/libpcap | **Kernel per-socket byte counters**, sampled | Exact, no drops, negligible CPU at any link speed |
| Packet capture | Primary rate source, `ip or ip6` | **Metadata only**: DNS answers, TLS SNI, SYN/FIN timing, behind a narrow BPF filter | Capture stops being a hot path; a capture failure costs hostnames, not the product |
| nettop | First fallback | **Last-resort** fallback | Parsing another tool's CSV is the most fragile option available |
| IPC encoding | Protobuf or MessagePack | **Hand-written binary codec**, no third-party code | Both ends ship from one package at one version; the root daemon should link nothing it does not have to |
| Dependencies | GRDB, SwiftProtobuf, an mmdb reader | **GRDB only**, and only in the unprivileged app | Smaller supply chain; the MMDB format is small enough to read ourselves |
| Build | `xcodebuild` for the app | **SwiftPM only** plus a bundling script | The Xcode on the dev machine is out of step with the OS (§3); the project should not depend on it |
| Shaders | Unspecified | Metal shader **source compiled at launch** | The offline Metal compiler ships only with full Xcode |
| Graph labels | SwiftUI overlay | **Drawn in Metal** from a CoreText-rasterised atlas | Thousands of SwiftUI text views cannot hold 60 fps |
| Parquet export | v1 | **Dropped** (CSV and JSONL only) | No mature dependency-free Swift writer; DuckDB converts JSONL in one line |
| Verification | Manual and hallway tests | **Simulated source, trace record/replay, headless frame snapshots** | The graph must be testable without a human or root |

---

## 3. Ground truth

Checked on the development machine: macOS 27.2.1 (26B131), Apple Silicon, Swift 6.1.

### 3.1 Verified

| Finding | Evidence | Consequence |
|---|---|---|
| An unprivileged process can list all TCP/UDP sockets system-wide, each with owning PID, cumulative rx/tx bytes, and TCP state | `netstat -anv` as a normal user returned 258 socket rows across 108 processes: 91 owned by the login user, 13 by root, 4 by system accounts | The kernel socket list is the backbone source and needs no root |
| libproc socket enumeration works from Swift with `import Darwin` alone | A 30-line probe using `proc_listallpids` → `PROC_PIDLISTFDS` → `PROC_PIDFDSOCKETINFO` compiled and ran | No C shim needed for libproc |
| libproc without root covers only part of the machine | The same probe found 169 inet sockets against roughly 258 in the kernel list a minute earlier | libproc is the detail source (fd ownership, socket options), not the inventory source, until the collector runs as root |
| `/dev/bpf*` is root-only (`crw------- root wheel`) | `ls -l /dev/bpf0` | Packet capture requires the collector |
| libpcap exports `pcap_set_want_pktap` and `pcap_set_pktap_hdr_v`, but the SDK headers declare neither | Symbols present in `libpcap.A.tbd`; no `pktap` match under `usr/include/pcap` | We declare these ourselves in a small C target |
| `net/pktap.h` is not in the SDK | File absent | The PKTAP header layout must be re-declared from published XNU source and guarded at runtime |
| nettop still emits per-flow CSV unprivileged | `nettop -L 1 -x -n` returned columns `interface,state,bytes_in,bytes_out,rx_dupe,rx_ooo,re-tx,rtt_avg,…` | Viable fallback; also confirms RTT and retransmit counts exist in the kernel statistics path |
| `NetworkStatistics.framework` (the private framework behind nettop) is present on disk and in the SDK | Directory listing | Candidate event-driven source (§3.2) |
| Xcode and the OS are out of step | `xcode-select` points at Xcode 16.3 (SDK 15.4); `xcrun --show-sdk-path` resolves to the Command Line Tools SDK 27.2; `xcodebuild` fails to locate an SDK | Do not depend on `xcodebuild`. `swiftc` built the probe without trouble |

### 3.2 Not yet verified — settled by the M0 spikes

| Question | Why it matters | If the answer is no |
|---|---|---|
| Can we read `net.inet.{tcp,udp}.pcblist_n` directly and parse its records reliably? | It is what `netstat` reads, but the record structs are private and may shift between releases | Fall back to NetworkStatistics, then nettop |
| Is `NetworkStatistics.framework` usable without entitlements, as user and as root? | It delivers flow open/close as events, so short-lived connections are caught without capture, and it carries RTT and retransmits | Short flows are seen only in Full mode, via capture |
| Does PKTAP still deliver PID and effective PID per packet on macOS 27? | Attributes DNS answers and short flows to a process | Match captured packets to sockets by 5-tuple instead |
| Does a SwiftPM-built executable inside a hand-assembled `.app` behave as a first-class app (menu bar extra, Settings scene, resource bundle lookup)? | Decides whether the build stays Xcode-free | Generate an Xcode project as a build artifact, never checked in |
| Does runtime Metal shader compilation cost under ~200 ms at launch? | Launch-to-graph budget | Cache the compiled library on disk |
| Does unprivileged `proc_pidpath` return paths for other users' processes? | Process identity and icons in Standalone mode | Show name and PID only; flag as restricted |

Every source that leans on a private layout sits behind an adapter with a recorded-fixture contract test, so a macOS update that breaks one fails loudly in tests and degrades gracefully at runtime.

---

## 4. Scope

### In for v1.0
- Live inventory of all TCP and UDP sockets, IPv4 and IPv6, including listeners.
- Process and user attribution; code-signature trust for each process.
- Per-flow and per-process rates, totals, age, state; RTT and retransmits where the source provides them.
- Hostnames: Off / Passive (DNS + SNI) / Active (adds reverse DNS).
- Offline GeoIP and ASN enrichment.
- The Constellation graph, plus Globe, Sankey, and Swim-lane views.
- Panels: Connections, Top Talkers, Throughput, Listeners, Protocol Mix, First Seen, DNS Activity, Interfaces, Age Histogram, Process Trust, Health.
- Filter language shared by the live view and the log.
- Local SQLite log with retention, a Log Explorer, replay, CSV and JSONL export.
- Workspaces, kiosk mode, menu bar extra.

### Out of v1.0
- Blocking or shaping traffic.
- Payload capture, TLS decryption.
- Alerts, external log streaming, encryption at rest, chord and port-matrix views (v1.1).
- Multi-Mac aggregation, packet peek, web UI (later, if ever).
- ICMP and non-IP protocols.

---

## 5. Architecture

```
┌───────────────────────────── Switchboard.app (logged-in user) ─────────────────────────────┐
│  SwiftUI chrome ── Metal graph engine ── panels ── inspector ── log explorer               │
│        ▲                                                                                   │
│   WorldStore (actor) ── time-windowed model, delta ring buffer, keyframes                  │
│        ▲                         ▲                                                         │
│   Enrichment ── hostnames · GeoIP/ASN · code signature · icons · tags                      │
│   LogStore ── SQLite (WAL)                                                                 │
│        ▲                                                                                   │
│   FlowFeed ─────────────┬───────────────────────────────┐                                  │
│                         │ Standalone                    │ Full                             │
│              in-process FlowEngine           socket client → switchboardd                  │
└─────────────────────────┼───────────────────────────────┼──────────────────────────────────┘
                          │                               │ /var/run/switchboard.sock
                          ▼                               ▼
                 ┌──────────────── FlowEngine (same code in both modes) ────────────────┐
                 │  Sources ─► Correlator ─► Rate engine ─► Lifecycle ─► Delta publisher │
                 │  KernelSocketList · NStat · LibProc · PktapCapture · Nettop · Sim     │
                 └───────────────────────────────────────────────────────────────────────┘
```

### 5.1 Two modes, one engine

| | **Standalone** | **Full** |
|---|---|---|
| Privilege | None | `switchboardd` as root |
| Inventory and rates | All sockets, all users | Same |
| Process detail | Own-user processes fully; others by name and PID | All processes |
| Hostnames | Reverse DNS only | Passive DNS and SNI from capture |
| Short-lived flows | Only if the event-driven source works | Yes |
| Setup | Launch the app | One install command |

The app starts in Standalone, looks for the collector socket, and switches to Full when it appears. The Health panel always states the current mode and what each source is contributing.

`FlowEngine` is one library. In Standalone the app hosts it in-process; in Full the daemon hosts it and the app consumes its deltas over a socket. Everything above `FlowFeed` is identical in both.

### 5.2 Package layout

One SwiftPM package, Swift 6 language mode, strict concurrency, deployment target macOS 15.

| Target | Kind | Contents | Third-party deps |
|---|---|---|---|
| `SwitchboardCore` | library | Models, flow engine, rate maths, filter language, wire codec, service table | none |
| `CDarwinPrivate` | C library | Our declarations of private kernel structs and unexported-header functions | none |
| `SwitchboardSources` | library | Source adapters (kernel list, NStat, libproc, PKTAP, nettop, simulator, trace replay) | none |
| `switchboardd` | executable | Root collector | none |
| `sbctl` | executable | Terminal viewer, diagnostics, trace record/replay | none |
| `SwitchboardStore` | library | SQLite log, retention, export | GRDB |
| `SwitchboardRender` | library | Metal engine, layouts, picking, label atlas | none |
| `SwitchboardApp` | executable | SwiftUI shell, panels, settings | — |

Hard rule: **nothing that runs as root links third-party code.**

---

## 6. Data acquisition

### 6.1 Sources

| Source | Privilege | Role | Cadence | Stability |
|---|---|---|---|---|
| **KernelSocketList** (`pcblist_n` sysctl) | none | Inventory backbone: 5-tuple, state, PID, cumulative bytes | 4 Hz (1–10 Hz configurable) | Private struct layout |
| **NStat** (NetworkStatistics) | to verify | Flow open/close events, RTT, retransmits, per-flow interface | Event-driven | Private framework |
| **LibProc** | none for own user; root for all | Authoritative fd ownership, process path, parent, UID, start time | On first sight, then cached | Public API |
| **PktapCapture** (libpcap) | root | DNS answers, TLS SNI, SYN/FIN timestamps, PID for short flows | Continuous | Private header layout |
| **Nettop** (subprocess CSV) | none | Fallback counters when the kernel list parser fails | 1 Hz | CLI output format |
| **Interfaces** (`getifaddrs`, `NET_RT_IFLIST2`) | none | Interface list, type, totals | 1 Hz | Public API |
| **Simulator** | none | Synthetic traffic for development, demos, benchmarks | Any | Ours |
| **TraceReplay** | none | Replays a recorded delta stream deterministically | Recorded | Ours |

All conform to one `FlowSource` protocol and report a capability set and a health status. The engine composes whatever is available.

### 6.2 Correlation

- **Flow key:** `(protocol, local address, local port, remote address, remote port)`. A flow is owned by one PID; sockets shared across `fork` are attributed to the lowest live PID holding the fd, and the others are listed in the inspector.
- **Attribution priority:** LibProc fd owner → kernel list PID → NStat PID → PKTAP PID. The winning source is recorded on the flow.
- **Lifecycle:** `new → active → idle → closing → closed`. `idle` after 5 s without bytes. `closed` when the socket leaves the kernel list or a FIN/RST is observed. Closed flows stay in the model for a fade window (default 30 s), then leave the live view and remain in the log.
- **Listeners** are tracked separately, never as flows, and marked `exposed` when bound to a non-loopback address.
- **Unconnected UDP sockets** have no remote endpoint in the kernel list. They appear as a socket with totals; per-destination breakdown needs NStat or capture, and the UI says so rather than inventing an edge.

### 6.3 Rates

Counters are cumulative. For each sample, `rate = Δbytes / Δt` using the monotonic clock, never the nominal interval. The display rate is an EWMA (default half-life 1 s); raw deltas are kept for charts and the log. A counter that moves backwards means the flow key was reused: close the old flow and open a new one.

### 6.4 Connection age

| Situation | Method | Shown as |
|---|---|---|
| Opened while Switchboard was watching | First sighting, or SYN timestamp in Full mode | `2h 14m` |
| Already open at startup | Lower bound from engine start, upper bound from process start | `≥ 37m` with an approximate marker |

### 6.5 Service identification

Port table first (IANA plus a curated list), upgraded by observation in Full mode: TLS ClientHello → `TLS`, QUIC long header → `QUIC`, DNS payload → `DNS`. Each label carries its basis: `port`, `heuristic`, or `observed`.

### 6.6 Hostnames

| Mode | Source | Network impact |
|---|---|---|
| Off | — | none |
| Passive (default in Full) | DNS answers and TLS SNI seen in capture | none |
| Active | Passive plus `getnameinfo`, cached, rate-limited | Emits PTR queries; the toggle says so |

Standalone mode has no passive source, so its default is Off with a one-click prompt to enable Active. Each hostname shows its source badge (`DNS`, `SNI`, `PTR`). SNI is read from TCP TLS only in v1; QUIC flows get names through DNS correlation. The UI states plainly when encrypted DNS, ECH, or Private Relay is limiting what can be seen.

### 6.7 Capture discipline (Full mode)

- Snap length 256 bytes. Packets are parsed in memory and discarded; nothing is written.
- The default BPF filter admits only what the parsers need: port 53, TCP SYN/FIN/RST, and the opening segments of TLS flows. Rates never depend on capture.
- Kernel drop counts are surfaced in Health.

---

## 7. Collector daemon

`switchboardd` is `FlowEngine` plus a publisher. It has no configuration that changes system state and exposes no commands beyond subscribe.

**Security posture**
- Runs as root; opens no network listeners.
- Unix socket at `/var/run/switchboard.sock`, mode `0660`, group `admin`. Peer UID checked with `getpeereid`; non-admin peers are refused. Network activity for every user on the machine is sensitive, so access is deliberately limited to administrators.
- All input from clients is length-checked and bounded. The only client message after the handshake is a subscription mask.
- Zero third-party code.

**Wire protocol**
- Length-prefixed frames: `u32 length · u8 type · payload`. Little-endian, varint integers, length-prefixed UTF-8.
- `Hello{protocol, client}` → `Welcome{version, mode, capabilities}`; a protocol mismatch is refused with a readable error.
- `Snapshot` on connect, then `FlowDelta{opened, updated, closed}` at 4–20 Hz, plus `ProcessDelta`, `ListenerDelta`, `DnsObservation`, `InterfaceStats`, `Health`.
- Backpressure: a slow client gets coalesced deltas and a `coalesced` counter. The engine never blocks on a client.
- `sbctl tap --json` decodes the stream to JSON lines for debugging; `sbctl record` writes a `.sbtrace` file that `TraceReplay` can play back.

**Install**
- Ad hoc: `sudo .build/release/switchboardd`.
- Persistent: `sudo scripts/install.sh` copies the binary to `/usr/local/libexec/`, writes a LaunchDaemon, and bootstraps it. `scripts/uninstall.sh` reverses every step.
- The app never requests a password. When the collector is missing it offers the install command to copy.

---

## 8. Data model

```
Flow      id, key(proto, local, remote), pid, procStart, direction, interface, state,
          firstSeen, lastSeen, ageExact, bytesIn/Out, packetsIn/Out, rateIn/Out,
          rttMs?, retransmits?, service, serviceBasis, hostname?, hostnameSource?, attribution
Process   pid, startTime, ppid, name, path?, bundleID?, uid, username,
          signing(apple | developerID | adHoc | unsigned | invalid | unknown), teamID?, restricted
Endpoint  address, hostnames[], asn?, org?, country?, city?, lat?, lon?, classes[], tags[]
Listener  pid, proto, address, port, exposed
```

A process is identified by `(pid, startTime)` so PID reuse never merges two programs. Address classes: private, loopback, link-local, multicast, CGNAT, public.

### Log schema

SQLite in WAL mode under `~/Library/Application Support/Switchboard/`, written only by the app.

```sql
CREATE TABLE process (
  pid INTEGER, start_time REAL, ppid INTEGER, name TEXT, path TEXT, bundle_id TEXT,
  uid INTEGER, username TEXT, signing TEXT, team_id TEXT,
  PRIMARY KEY (pid, start_time)
);
CREATE TABLE flow (
  id INTEGER PRIMARY KEY, pid INTEGER, proc_start REAL,
  proto TEXT, l_ip TEXT, l_port INTEGER, r_ip TEXT, r_port INTEGER,
  direction TEXT, iface TEXT, service TEXT, service_basis TEXT,
  hostname TEXT, hostname_src TEXT, attribution TEXT,
  first_seen REAL, last_seen REAL, closed_at REAL, age_exact INTEGER,
  bytes_in INTEGER, bytes_out INTEGER, pkts_in INTEGER, pkts_out INTEGER
);
CREATE TABLE flow_sample   (flow_id INTEGER, ts REAL, bytes_in INTEGER, bytes_out INTEGER);
CREATE TABLE dns_obs       (ts REAL, name TEXT, ip TEXT, ttl INTEGER, pid INTEGER);
CREATE TABLE listener_event(ts REAL, pid INTEGER, proto TEXT, l_ip TEXT, l_port INTEGER, event TEXT);
CREATE TABLE endpoint_first_seen(ip TEXT PRIMARY KEY, ts REAL);
CREATE INDEX flow_time   ON flow(first_seen);
CREATE INDEX flow_remote ON flow(r_ip);
CREATE INDEX flow_pid    ON flow(pid, proc_start);
```

Detail levels: **Summary** (flows) · **Standard** (plus DNS and listeners) · **Detailed** (plus 1 s samples). Retention by age (30 days) and size (2 GB), pruned in the background. One-click purge.

---

## 9. Visual design

The reference is the control-room display from a film: a dark field, luminous lines, motion that reads as traffic. The discipline is that an operator must be able to stare at it for a shift.

### 9.1 Principles

1. **Brightness is activity.** Idle things are dim. Anything bright is moving bytes right now. A quiet machine looks quiet.
2. **Motion is direction and volume.** Particles travel the way the bytes travel, and their density follows rate on a log scale.
3. **Red is reserved.** Warm colours mean something needs attention. They never appear as decoration.
4. **Position is memory.** A destination appears in the same region of the field on every launch, so the layout becomes familiar.
5. **Nothing blocks the answer.** Hover is instant, selection never rearranges the graph, and no animation delays a readout.

### 9.2 Palette and type

| Role | Colour |
|---|---|
| Field | `#05080F` with a faint grid at `#0E1A2B` |
| Primary signal (TLS/HTTPS) | Cyan `#37E6FF` |
| QUIC | Violet `#9B8CFF` |
| DNS | Green `#5CF2A5` |
| SSH and remote access | Amber `#FFC857` |
| Cleartext HTTP | Orange `#FF8A3D` |
| Other | Slate `#7C8DA6` |
| Attention (unsigned, exposed, watchlisted) | Signal red `#FF3B5C` |
| Chrome text | `#C9D6E8`, secondary `#6B7C93` |

Data is set in SF Mono, chrome in SF Pro. Panels are flat with hairline borders and no drop shadows. Protocol hues are a starting point: the final set is validated for the three common colour-vision deficiencies before M3 closes, and an alternate palette ships alongside it.

### 9.3 Presentation profiles

| Profile | For | Rendering |
|---|---|---|
| **Cinema** (default) | Wall displays, demos | Full bloom, particles, pulses, EDR highlights on capable displays, subtle grain |
| **Operator** | Long sessions | Reduced bloom, sparse particles, no grain, higher label density |
| **Still** | Reduce Motion, battery | No particles or pulses; rate shown by thickness and brightness alone |

Still is selected automatically when the system Reduce Motion setting is on. One key cycles profiles.

### 9.4 Encoding

| Channel | Encodes |
|---|---|
| Edge thickness (log) | Current rate |
| Edge brightness | Recency of activity |
| Particle direction, density | Traffic direction, throughput |
| Edge hue | Service |
| Dash pattern | Idle or closing |
| Node size (log) | Bytes over the selected window |
| Node ring | Trust: none for signed, amber for ad hoc, red for unsigned or invalid |
| Halo | First time this endpoint has ever been seen |
| Pulse | Connection opened |

### 9.5 Render pipeline

An `MTKView` hosted in SwiftUI, drawing to a 16-bit float target.

1. **Field** — procedural grid and vignette in one fullscreen pass.
2. **Edges** — instanced quadratic Bézier ribbons, tessellated in the vertex shader, additive blending.
3. **Particles** — instanced; position is a pure function of edge, phase, and time, computed in the vertex shader. There is no per-particle CPU work.
4. **Nodes** — instanced signed-distance shapes; app icons from a texture atlas.
5. **Labels** — strings rasterised with CoreText into an LRU atlas, drawn as instanced quads, culled by zoom and priority.
6. **Post** — bright-pass, dual-filter bloom chain, composite, tone map, optional grain.

Layout runs off the main thread at a fixed timestep (Barnes–Hut, θ ≈ 0.8); the renderer interpolates between the last two layout states. Picking uses the layout's own quadtree, so hover costs microseconds and needs no GPU readback.

---

## 10. Views

The main window puts the graph in the centre, the inspector on the right, and dockable panels along the bottom. The top bar holds the filter field, layout switcher, pause control, timeline scrubber, hostname-resolution toggle, and a health indicator that shows the current mode.

### 10.1 Constellation (hero)

- **Centre:** this Mac, with interface sub-nodes on demand.
- **Inner ring:** processes, grouped by user, sized by bytes, badged with icon and trust ring.
- **Outer field:** remote endpoints, clustered by domain, ASN, country, or subnet. Clusters collapse to a counted node and expand on demand; auto-clustering engages past a configurable node count.
- **Stable placement:** an endpoint's bearing is seeded from a hash of its cluster key.

Interaction:

| Gesture | Result |
|---|---|
| Hover | Tooltip: 5-tuple, process (name, path, PID, parent), user, trust, hostname and source, ASN, location, age, totals, 60 s sparkline, service and basis |
| Click | Pin to inspector |
| Double-click | Focus: isolate the neighbourhood, dim the rest |
| ⌘-click, lasso | Multi-select |
| Pinch, scroll, drag | Zoom, pan |
| `/` | Jump to filter bar |
| Space | Pause/resume the view (collection continues) |
| Right-click | Copy as text or JSON, filter to this, hide, tag, reveal in Finder, look up (opens the browser; never automatic) |

### 10.2 Other layouts

| Layout | Milestone | Shows |
|---|---|---|
| Globe | v1.0 | Great-circle arcs from here to endpoint locations |
| Sankey | v1.0 | Process → service → destination organisation by volume |
| Swim lanes | v1.0 | Per-process connection timelines |
| Hierarchy | v1.0 | User → process → domain → address |
| Chord, port matrix | v1.1 | Process ↔ ASN; process × remote port |

### 10.3 Panels

Dockable, resizable, all optional: Connections table · Top Talkers · Throughput · Protocol and Port Mix · Listeners (exposed ones highlighted) · First Seen · DNS Activity · Interfaces · Age Histogram · Process Trust · Health.

The Connections table is the fallback for everything: if the graph is ever unclear, the same data is one keystroke away, sortable and filterable.

### 10.4 Filter language

One language for the live view, the table, and the log.

```
query   := or
or      := and ( "OR" and )*
and     := unary ( ["AND"] unary )*
unary   := ["NOT"] ( "(" query ")" | term )
term    := field op value | bareword
op      := ":" | "=" | "!=" | ">" | ">=" | "<" | "<="
```

```
process:Slack country!=US rate_out>100KB/s
user:root service:SSH
r_port:443 NOT hostname:*.apple.com
age>1h bytes_total<10KB
```

Values understand units (`KB/s`, `MB`, `h`, `m`), globs, and CIDR. A bare word matches process, hostname, and address. The same AST evaluates in memory against live flows and compiles to SQL for the log. Fields and values autocomplete; filters can be saved.

### 10.5 Time

The app keeps a rolling window (default 1 h) as a ring buffer of deltas with a keyframe every 10 s. The scrubber replays any moment in that window in the graph. Beyond the window, the Log Explorer reconstructs a range from SQLite and hands it to the same replay path.

### 10.6 Workspaces and display

Named workspaces save layout, panels, filters, and profile; three ship by default (**NOC Wall**, **Privacy Audit**, **Developer**). Kiosk mode goes full screen across displays. The menu bar extra shows a live rate sparkline and the top three talkers.

---

## 11. Budgets

| Area | Budget |
|---|---|
| Launch to live graph | ≤ 2 s |
| Event to screen | ≤ 1 s; ≤ 300 ms target |
| Hover to tooltip | ≤ 1 frame |
| Frame rate | 60 fps floor, 120 fps on ProMotion, at 5,000 nodes and 2,000 active edges |
| Engine CPU | < 1% idle; < 3% with 2,000 sockets at 4 Hz |
| App CPU | < 10% in Operator profile at typical load |
| Memory | Collector < 60 MB; app < 400 MB with a 1 h window |
| Network impact | Zero in Off and Passive modes |

Budgets are measured by `sbctl bench` and the simulator, not by eye, and are checked at every milestone.

---

## 12. Security and privacy

1. **Local only.** No telemetry, crash upload, or update check. The app makes no network connection unless Active resolution is on, and then only PTR queries through the system resolver.
2. **Least privilege.** Root is confined to a dependency-free daemon with a read-only job. The app never runs as root and never asks for a password.
3. **No payloads.** Capture is snap-limited and filtered; packets are parsed and dropped.
4. **Guarded IPC.** Admin-only socket, peer UID check, bounded parsing, versioned protocol.
5. **Honest about private interfaces.** The kernel socket list, NetworkStatistics, and PKTAP are not public API. Each is isolated, contract-tested, optional at runtime, and reported in Health.
6. **Transparency.** An About pane lists exactly what is collected and where it is stored. Exports can redact hostnames.

---

## 13. Build and packaging

```bash
swift build -c release
```

```bash
scripts/bundle.sh
```

```bash
open build/Switchboard.app
```

`bundle.sh` assembles the `.app` (executable, `Info.plist`, icon, resources) and signs it ad hoc with `codesign -s -`. There is no Xcode project in the repository. Releases, if any, are unsigned zips with checksums and a documented `xattr` step; building from source is the primary path.

GeoIP data is not bundled. `scripts/fetch-geoip.sh` is run by the user to download DB-IP Lite (CC BY, no account) and the app reads whatever `.mmdb` files it finds in Application Support.

---

## 14. Verification

| Layer | Method |
|---|---|
| Parsers and maths | Unit tests: rate engine, correlator, lifecycle, filter parser, wire codec (round-trip and fuzz), DNS and SNI parsers against captured fixtures, MMDB reader |
| Private-layout adapters | Contract tests against recorded kernel-list buffers, PKTAP headers, and nettop output per macOS version |
| Engine end to end | Scripted traffic (`curl` loops, `nc`, `iperf3`, bursts of short connections) with asserted attribution and totals, compared against `netstat` |
| Rendering | Headless `--snapshot` renders a trace to PNG at a fixed time; images are compared against goldens with a tolerance |
| Performance | `sbctl bench` drives the simulator at 1k / 5k / 20k flows and reports engine CPU and frame times |
| Soak | 72 h run: memory growth, log size, reconnects |
| Coexistence | VPN clients, Little Snitch or LuLu, Docker bridges |
| Usability | The five-second test, with someone who has not seen the app |

The simulator and trace replay exist so that every view can be developed, demonstrated, and regression-tested with no privileges and no real traffic.

---

## 15. Risks

| Risk | Effect | Response |
|---|---|---|
| Kernel-list struct layout shifts in a macOS update | Lose the backbone source | Runtime sanity checks on record kinds and lengths; NStat then nettop fallback; contract tests per OS |
| NetworkStatistics unusable without entitlement | No event-driven opens in Standalone | Poll faster; state the short-flow limitation in Health; capture covers it in Full |
| PKTAP header changes | Lose PID on captured packets | Match by 5-tuple; hostnames still work |
| SwiftPM app bundle misbehaves | Build story gets heavier | Generated Xcode project as a fallback artifact |
| Encrypted DNS, ECH, Private Relay | Fewer hostnames | PTR mode, ASN and organisation as the fallback identity, clear messaging |
| Graph unreadable on a busy machine | Fails the five-second test | Auto-clustering, focus mode, level of detail, the table one key away |
| Cinematic effects fatigue operators | Rejected for daily use | Operator and Still profiles; effects always encode data |
| Root daemon | Attack surface | Read-only, no listeners, no dependencies, admin-only socket |

---

## 16. Decisions needed from the owner

1. **Licence and visibility.** MIT, Apache-2.0, or GPL; public from the start or private until v1.0. Blocks nothing until the first release.
2. **Identifier prefix.** Bundle ID and LaunchDaemon label. Placeholder: `local.switchboard`.
3. **Default profile.** This spec defaults to Cinema. Operator is the safer default for daily use.
4. **Private framework use.** NetworkStatistics is the best event source available but is private API. The spec assumes it is acceptable behind an adapter; say so if it is not.
