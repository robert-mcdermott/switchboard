# Switchboard — Technical Specification

A real-time network observatory for macOS. Every connection on the machine, who owns it, where it goes, and how hard it is working — drawn as a living graph that an operator can read at a glance and interrogate in seconds.

**Status:** v0.4 draft, revised after M0, M1, and M2 · **Companions:** [ROADMAP.md](ROADMAP.md) · [M0 findings](spikes/M0-findings.md) · [M1 findings](spikes/M1-findings.md) · [M2 findings](spikes/M2-findings.md) · [M3 findings](spikes/M3-findings.md) · [M4 findings](spikes/M4-findings.md) · [M5 findings](spikes/M5-findings.md)

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
| First run | Collector must be installed as root before anything works | **Standalone mode** works with no privileges and shows the login user's activity; the root collector is an upgrade to **Full mode** | NetworkStatistics reports the user's own sockets, with counters, to an unprivileged process (§3) |
| Traffic rates | Count every packet through PKTAP/libpcap | **Kernel per-flow byte counters** from NetworkStatistics | Exact, no drops, negligible CPU at any link speed |
| Packet capture | Primary rate source, `ip or ip6` | **Metadata only**: DNS answers, TLS SNI, SYN/FIN timing, filtered in our own code | Capture stops being a hot path; a capture failure costs hostnames, not the product |
| nettop | First fallback | **On-demand scan** in Standalone; fallback if NetworkStatistics fails | It is Apple-signed and is the only unprivileged view of other users' flows, but it uses about 1.4 CPU cores while sampling, so it cannot run continuously |
| IPC encoding | Protobuf or MessagePack | **Hand-written binary codec**, no third-party code | Both ends ship from one package at one version; the root daemon should link nothing it does not have to |
| Dependencies | GRDB, SwiftProtobuf, an mmdb reader | **None.** The log uses the SQLite that ships with macOS | Smaller supply chain; a thin wrapper over system SQLite was enough (M5) |
| Build | `xcodebuild` for the app | **SwiftPM only** plus a bundling script | No project file to maintain, and it builds with any recent Swift toolchain. `xcodebuild` works on the dev machine but nothing requires it |
| Shaders | Unspecified | Metal shader **source compiled at launch** | Keeps the build to plain `swift build` with no separate shader step; a trivial shader compiled in about 200 ms cold on the dev Mac (§3) |
| Graph labels | SwiftUI overlay | **Drawn in Metal** from a CoreText-rasterised atlas | Thousands of SwiftUI text views cannot hold 60 fps |
| Parquet export | v1 | **Dropped** (CSV and JSONL only) | No mature dependency-free Swift writer; DuckDB converts JSONL in one line |
| Verification | Manual and hallway tests | **Simulated source, trace record/replay, headless frame snapshots** | The graph must be testable without a human or root |

---

## 3. Ground truth

Checked on the development machine: macOS 27.2.1 (26B131), Apple M4, Swift 6.2 from Xcode 26.0 beta.

### 3.1 Verified

| Finding | Evidence | Consequence |
|---|---|---|
| The kernel socket list is withheld from unprivileged, ad-hoc-signed processes, and given to root | The `pcblist_n` sysctl returned ~136 KB to Apple-signed callers (`netstat`, `sysctl`, Xcode's Python) and 48 bytes, an empty list, to an ad-hoc-signed C program and to `sbctl`, same user and moment As root, `sbctl` read 267 sockets and matched `netstat` on all of them | It cannot be the Standalone backbone (an earlier draft assumed it could, because `netstat` works unprivileged). It is a complete inventory for the collector |
| Our kernel socket list parser is exact | Recorded buffers parsed by `sbctl` matched `netstat -anv` on 268 of 268 sockets: PIDs, byte counters, and all 213 TCP states | The declarations in `CDarwinPrivate.h` are right for macOS 27.2; usable wherever the kernel will fill the list |
| NetworkStatistics works unprivileged and unentitled | Loaded with `dlopen`; 170 sources across 92 processes (91 owned by the login user) against 278 sockets in `netstat`; 52 keys per flow including bytes, packets, RTT, retransmits, TCP state, and start time; open and close delivered as events As root: 250 sources across 116 processes, 99 owned by other accounts, against 267 sockets in the kernel list | It is the primary source in both modes. Unprivileged it covers the login user's processes; as root nearly everything, with the kernel list beside it to catch the remainder |
| PKTAP delivers process metadata on macOS 27.2 | As root on `pktap,all`: header length 156 on 821 of 821 packets, matching our declaration; PID on 95%; the probe's own DNS lookup appeared as `mDNSResponder for sbctl`; 4 of 4 TLS server names read and attributed; no drops | Capture can tie DNS answers and short flows to the requesting process |
| PKTAP cannot be filtered in the kernel | `pcap_compile` fails: "Apple DLT_PKTAP link-layer type filtering not implemented" | The collector filters after delivery (§6.7) |
| libproc socket enumeration works from Swift with `import Darwin` alone | A 30-line probe using `proc_listallpids` → `PROC_PIDLISTFDS` → `PROC_PIDFDSOCKETINFO` compiled and ran | No C shim needed for libproc |
| libproc without root covers the login user's processes only | Descriptor lists and `PROC_PIDTBSDINFO` succeeded for 858 of 858 own processes and 0 of 273 others | libproc is a detail source (fd ownership, parent, start time), not an inventory source |
| Executable paths are readable for every process without root | `proc_pidpath` succeeded for 182 of 182 root processes and 91 of 91 owned by other accounts | Icons, bundle names, and code-signature trust work in Standalone mode |
| `/dev/bpf*` is root-only (`crw------- root wheel`) | `ls -l /dev/bpf0` | Packet capture requires the collector |
| libpcap exports `pcap_set_want_pktap` and `pcap_set_pktap_hdr_v`, but the SDK headers declare neither | Symbols present in `libpcap.A.tbd`; no `pktap` match under `usr/include/pcap` | We declare these ourselves in a small C target |
| `net/pktap.h` is not in the SDK | File absent | The PKTAP header layout must be re-declared from published XNU source and guarded at runtime |
| nettop still emits per-flow CSV unprivileged | `nettop -L 1 -x -n` returned columns `interface,state,bytes_in,bytes_out,rx_dupe,rx_ooo,re-tx,rtt_avg,…` | Viable fallback; also confirms RTT and retransmit counts exist in the kernel statistics path |
| The toolchain is one release behind the OS but sufficient | Active Xcode is 26.0 beta (Swift 6.2, macOS 26.0 SDK); the Command Line Tools carry the 27.2 SDK. A SwiftPM package built and ran, and a file importing SwiftUI, Charts, and MetalKit compiled against both SDKs | Pin the deployment target in `Package.swift` rather than relying on toolchain defaults |
| The default SDK lookup is mixed | `xcrun --show-sdk-path` returns the Command Line Tools SDK, which the Xcode 26 linker cannot read: a plain `cc` link fails. `xcrun --sdk macosx` resolves cleanly, and `swift build` is unaffected | Scripts that call the C compiler pass `-isysroot` explicitly |
| Metal shaders compile from source at runtime, quickly | The prototype's shader file: 51 ms on the first launch of a build, 1 ms afterwards | Runtime compilation stays; re-measure as the shader set grows |
| The render approach has headroom | Instanced Bézier ribbons with shader-computed pulses: 118 fps at 1,000 edges and 119 fps at 5,000, in a 5120 × 2756 window on a 120 Hz display; 85 fps at 20,000 | The §9.5 pipeline design stands |
| A SwiftPM executable in a hand-assembled bundle is a first-class app | Main window, menu bar extra, and Settings scene all present; strict signature verification passes | No Xcode project. SwiftPM's `Bundle.module` looks in the wrong place inside an app, so resources are located by our own lookup |

### 3.2 Still open

M1 settled two of M0's leftovers: a flow's start time from NetworkStatistics is its true creation time (on the continuous Mach clock), and flows of 10–100 ms are caught reliably (30 of 30). It also found that `netstat`'s receive counter runs at two to three times the true figure, so the kernel socket list is never used for received bytes. Details in [M1 findings](spikes/M1-findings.md). What remains:

| Question | Why it matters | Settled in |
|---|---|---|
| Does root see the 5–8% of sockets NetworkStatistics withholds from us? | Standalone cannot: M2 tried every option and flag the framework exports and none revealed them, so `nettop`'s entitlement is the likely gate | M4 |
| How often does a browser's TLS ClientHello run past its first segment? | Sets the snap length and whether capture must reassemble two segments | M4 |
| What does unfiltered PKTAP delivery cost under sustained heavy traffic? | The collector's CPU budget | M4 |

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
| Inventory and rates | The login user's processes, about 93–95% of their sockets (§3.2) | All processes, all users |
| Process detail | Full for own processes; path, name, and trust for all | Full for all |
| Hostnames | Reverse DNS only | Passive DNS and SNI from capture |
| Short-lived flows | Most; sub-millisecond flows can be missed | Yes, with capture |
| Setup | Launch the app | One install command |

The app starts in Standalone, looks for the collector socket, and switches to Full when it appears. The Health panel always states the current mode and what each source is contributing, and in Standalone it says plainly that system daemons and other users' processes are not shown.

`FlowEngine` is one library, and as built in M4 it always runs in the app. In Standalone it is fed by sources inside the app; in Full it is fed by the collector, which runs the privileged sources and forwards what they observe over a socket. Everything above the sources is the same code in both modes, and the root process gathers and forwards without interpreting ([M4 findings](spikes/M4-findings.md)).

### 5.2 Package layout

One SwiftPM package, Swift 6 language mode, strict concurrency, deployment target macOS 15.

| Target | Kind | Contents | Third-party deps |
|---|---|---|---|
| `SwitchboardCore` | library | Models, flow engine, rate maths, filter language, wire codec, service table | none |
| `CDarwinPrivate` | C library | Our declarations of private kernel structs and unexported-header functions | none |
| `SwitchboardSources` | library | Source adapters (kernel list, NStat, libproc, PKTAP, nettop, simulator, trace replay) | none |
| `switchboardd` | executable | Root collector | none |
| `sbctl` | executable | Terminal viewer, diagnostics, trace record/replay | none |
| `SwitchboardStore` | library | SQLite log, retention, export | none (system SQLite) |
| `SwitchboardRender` | library | Metal engine, layouts, picking, label atlas | none |
| `SwitchboardApp` | executable | SwiftUI shell, panels, settings | — |

Hard rule: **nothing that runs as root links third-party code.**

---

## 6. Data acquisition

### 6.1 Sources

| Source | Privilege | Role | Cadence | Stability |
|---|---|---|---|---|
| **NStat** (NetworkStatistics) | none for the login user's flows; root for nearly all | Backbone: flow open/close events, 5-tuple, PID, counters, RTT, retransmits, interface, start time | Event-driven; counters refreshed at 1 Hz (up to 4 Hz configurable), since asking is the cost | Private framework, loaded with `dlopen` |
| **KernelSocketList** (`pcblist_n` sysctl) | root | Complete inventory in the collector: cross-check for which sockets exist, never for received bytes, which it over-reports | 1 Hz | Private struct layout, parser verified |
| **LibProc** | none for own user; root for all | Authoritative fd ownership, process path, parent, UID, start time | On first sight, then cached | Public API |
| **PktapCapture** (libpcap) | root | DNS answers, TLS SNI, SYN/FIN timestamps, PID for short flows | Continuous | Private header layout |
| **Nettop** (subprocess CSV) | none | On-demand scan of every user's flows in Standalone; fallback if NStat fails. Too costly to run continuously | 1 Hz while running | CLI output format |
| **Interfaces** (`getifaddrs`, `NET_RT_IFLIST2`) | none | Interface list, type, totals | 1 Hz | Public API |
| **Simulator** | none | Synthetic traffic for development, demos, benchmarks | Any | Ours |
| **TraceReplay** | none | Replays a recorded delta stream deterministically | Recorded | Ours |

All conform to one `FlowSource` protocol and report a capability set and a health status. The engine composes whatever is available.

### 6.2 Correlation

- **Flow key:** `(protocol, local address, local port, remote address, remote port)`. A flow is owned by one PID; sockets shared across `fork` are attributed to the lowest live PID holding the fd, and the others are listed in the inspector.
- **Attribution priority:** LibProc fd owner → NStat PID → kernel list PID → PKTAP PID. The winning source is recorded on the flow.
- **Lifecycle:** `new → active → idle → closing → closed`. `idle` after 5 s without bytes. `closed` when the source reports the flow removed or a FIN/RST is observed. Closed flows stay in the model for a fade window (default 30 s), then leave the live view and remain in the log.
- **Keeping ended flows** is an optional display mode, off by default: closed flows stay on the graph, subdued, instead of fading out, up to 3,000 of them. It changes what is drawn, not what the engine tracks.
- **Listeners** are tracked separately, never as flows, and marked `exposed` when bound to a non-loopback address.
- **Unconnected UDP sockets** have no single remote endpoint. They appear as a socket with totals; a per-destination breakdown needs capture, and the UI says so rather than inventing an edge.

### 6.3 Rates

Counters are cumulative. For each sample, `rate = Δbytes / Δt` using the monotonic clock, never the nominal interval. The display rate is an EWMA (default half-life 1 s); raw deltas are kept for charts and the log. A counter that moves backwards means the flow key was reused: close the old flow and open a new one.

### 6.4 Connection age

| Situation | Method | Shown as |
|---|---|---|
| Opened while Switchboard was watching | First sighting, or SYN timestamp in Full mode | `2h 14m` |
| Already open at startup | The flow's own start time from NetworkStatistics, verified exact in M1 | `2h 14m` |
| Already open at startup, no start time available | Lower bound from engine start, upper bound from process start | `≥ 37m` with an approximate marker |

### 6.5 Service identification

Port table first (IANA plus a curated list), upgraded by observation in Full mode: TLS ClientHello → `TLS`, QUIC long header → `QUIC`, DNS payload → `DNS`. Each label carries its basis: `port`, `heuristic`, or `observed`.

### 6.6 Hostnames

| Mode | Source | Network impact |
|---|---|---|
| Off | — | none |
| Passive (default in Full) | DNS answers and TLS SNI seen in capture | none |
| Active | Passive plus `getnameinfo`, cached, rate-limited | Emits PTR queries; the toggle says so |

As built in M4, a name from a TLS handshake belongs to its one connection and wins over DNS for it; a DNS answer names an address for the process that asked and, failing that, for anyone. Standalone mode has no passive source and Active lookups arrive in M6, so until then it shows addresses. Each hostname shows its source badge (`DNS`, `SNI`, `PTR`). SNI is read from TCP TLS only in v1; QUIC flows get names through DNS correlation. The UI states plainly when encrypted DNS, ECH, or Private Relay is limiting what can be seen.

### 6.7 Capture discipline (Full mode)

- Snap length 256 bytes for everything except TLS handshakes. Current browsers send ClientHellos larger than one segment with shuffled extensions, so the opening segments of a TLS flow are captured whole. Measured in M4 on real traffic: 16 of 76 server names needed more than one segment, so the capture snap length is 2,048 bytes and handshakes are reassembled across segments. Packets are parsed in memory and discarded; nothing is written.
- PKTAP cannot be filtered in the kernel, so every packet's first bytes reach the collector, which immediately discards all but what the parsers need: port 53, TCP SYN/FIN/RST, and the opening segments of TLS flows. Rates never depend on capture. The cost of this under sustained heavy traffic is measured in M4.
- Kernel drop counts are surfaced in Health.

---

## 7. Collector daemon

`switchboardd` runs the privileged sources and publishes their observations. It has no configuration that changes system state and accepts no commands: a client says hello and then only listens.

**Security posture**
- Runs as root; opens no network listeners.
- Unix socket at `/var/run/switchboard.sock`, mode `0660`, group `admin`. Peer UID checked with `getpeereid`; non-admin peers are refused. Network activity for every user on the machine is sensitive, so access is deliberately limited to administrators.
- All input from clients is length-checked and bounded. The only client message after the handshake is a subscription mask.
- Zero third-party code.

**Wire protocol**
- Length-prefixed frames: `u32 length · u8 type · payload`. Little-endian, varint integers, length-prefixed UTF-8.
- `hello{protocol, client}` → `welcome{protocol, version, uid, sources}`; a protocol mismatch is refused with a readable reason.
- On connect, `reset` and the complete current state; then `events{source, …}` four times a second, `process` records as processes are first seen, and `health` each second.
- Backpressure: a client more than 8 MB behind has its backlog dropped and is sent `reset` and the current state again. Collection never waits for a client.
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

SQLite in WAL mode under `~/Library/Application Support/Switchboard/`, written only by the app. As built in M5 the process's name, user, and path are stored in each connection's row rather than in a separate table; the listing below is the original design, and the schema in use is in `SwitchboardStore`.

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

As built in M2 ([M2 findings](spikes/M2-findings.md)): pulses are computed in the edge fragment shader rather than as a separate particle pass, and the final target is 8-bit, with EDR output still to come.

Placement is computed rather than simulated. Every node has an anchor that is a pure function of its name or address: processes are spaced evenly around a ring in an order fixed by their names, and each destination sits in the sector of the process that uses it most. A short relaxation separates overlapping nodes and then stops. This is what makes position stable across launches and makes rendering deterministic for the golden images. Picking is a linear scan, which at a few thousand nodes costs microseconds.

---

## 10. Views

The main window puts the graph in the centre, the inspector on the right, and dockable panels along the bottom. The top bar holds the filter field, layout switcher, pause control, timeline scrubber, hostname-resolution toggle, and a health indicator that shows the current mode.

### 10.1 Constellation (hero)

- **Centre:** this Mac, with interface sub-nodes on demand.
- **Inner ring:** processes, grouped by user, sized by bytes, badged with icon and trust ring.
- **Outer field:** remote endpoints, clustered by domain, ASN, country, or subnet. Clusters collapse to a counted node and expand on demand; auto-clustering engages past a configurable node count.
- **Stable placement:** a process's bearing comes from a hash of its name, and an endpoint's from its address within its process's sector.
- **Loopback** connections count toward their process and its line to the centre but get no node of their own.

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

As built in M3: a filter that does not parse is reported and the last good filter stays in force, and a flow with no measurement for a field satisfies no comparison on it. Completion and saved filters are not built yet.

### 10.5 Time

The app keeps a rolling window of the recent past: one snapshot of the model per second, 15 minutes by default and up to 60, bounded also by the number of flow records held so a very busy machine keeps less. The scrubber shows any moment in that window in the graph and in every table; pausing is holding the present moment. Beyond the window, the Log Explorer reconstructs a range from SQLite and hands it to the same replay path.

### 10.6 Workspaces and display

Named workspaces save layout, panels, filters, and profile; three ship by default (**NOC Wall**, **Privacy Audit**, **Developer**). Kiosk mode goes full screen across displays. The menu bar extra shows a live rate sparkline and the top three talkers.

---

## 11. Budgets

| Area | Budget |
|---|---|
| Launch to live graph | ≤ 2 s (measured 0.6–0.8 s) |
| Event to screen | Opens and closes ≤ 300 ms; byte counts ≤ 1 s |
| Hover to tooltip | ≤ 1 frame |
| Frame rate | 60 fps floor, 120 fps on ProMotion, at 5,000 nodes and 2,000 active edges. Measured in M2 at 2,051 nodes and 2,050 edges: 110 fps mean, worst frame 25 ms, so the floor is not yet held |
| Engine CPU | < 1% idle (measured 0.85% with ~150 sockets at the 1 Hz default); < 3% with 2,000 sockets |
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
| NetworkStatistics changes or becomes entitlement-gated in a macOS update | Lose the backbone source; Standalone would have nothing but `nettop` | Loaded with `dlopen`, so absence is detected, not fatal; `nettop` subprocess fallback; the collector's other sources in Full mode; a probe (`sbctl probe nstat`) to run on every new macOS |
| Standalone cannot see system daemons | A user may assume the picture is complete | Stated in Health and on the graph; one-step upgrade to Full mode |
| Kernel-list struct layout shifts in a macOS update | Lose a collector cross-check | Runtime checks on record kinds and lengths; contract tests per OS |
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
4. **Private framework use.** NetworkStatistics is private API and, after M0, the only way an unprivileged build can see flows with counters. The spec now depends on it. Without it, Switchboard needs the root collector from first launch.
