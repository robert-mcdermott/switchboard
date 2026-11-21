# Switchboard — Implementation Roadmap

Companion to [SPEC.md](SPEC.md). Section references (§) point there.

## How this roadmap is built

- **Vertical slices.** Every milestone ends with something that runs and can be demonstrated, not a layer waiting for the next layer.
- **Risk first.** The private-interface questions (§3.2) are answered in M0, before anything is built on them.
- **The graph early.** Real data on screen by M2. The root collector comes after, because Standalone mode already sees everything the login user's own processes do.
- **Testable without privilege.** The simulator and trace replay land in M1 so every later milestone can be verified headlessly.
- **Sizes, not dates.** S ≈ a few focused sessions, M ≈ about twice that, L ≈ about twice again. Calendar time depends on who is building.

```
M0 Spikes ─► M1 Engine ─► M2 First light ─► M3 Console ─┬─► M5 Memory ─┬─► M7 Views ─► M8 v1.0
                                                        └─► M4 Collector ─► M6 Enrichment ─┘
```

M4 and M5 are independent of each other and can proceed in parallel once M3 closes.

| | Milestone | Size | Ends with |
|---|---|---|---|
| M0 | Foundations and spikes | M | Every §3.2 question answered in writing |
| M1 | Engine | M | `sbctl top` shows the user's connections, live, unprivileged |
| M2 | First light | L | The Constellation graph running on real traffic |
| M3 | Operator console | L | Passes the five-second test; daily-drivable |
| M4 | Collector and Full mode | M | Hostnames and short-lived flows via the root daemon |
| M5 | Memory | M | Log, Log Explorer, replay, export |
| M6 | Enrichment and trust | M | Geography, ASN, signing trust, tags |
| M7 | Views and wall mode | L | Globe, Sankey, swim lanes, workspaces, kiosk |
| M8 | v1.0 hardening | M | Budgets met, soak passed, documented |

---

## M0 — Foundations and spikes

**Goal:** remove the unknowns and lay down the skeleton.

**Build**
- SwiftPM package with the targets in §5.2, empty but compiling under Swift 6 strict concurrency.
- `scripts/bundle.sh` producing an ad-hoc-signed `Switchboard.app` that opens a window.
- A `docs/spikes/` note for each question below: what was tried, the result, the decision.

**Spikes**

| # | Question | Done when |
|---|---|---|
| S1 | Read and parse `net.inet.tcp.pcblist_n` and `udp.pcblist_n` directly | A probe prints the same rows as `netstat -anv`, with PIDs and byte counters, as a normal user |
| S2 | NetworkStatistics without entitlements | A probe receives flow-added and flow-removed callbacks with counters, as user and as root — or a clear record of why not |
| S3 | PKTAP on macOS 27 | Under `sudo`, a probe prints PID, effective PID, and process name per packet, and extracts one DNS answer and one SNI |
| S4 | SwiftPM app bundle | Menu bar extra, Settings scene, and resource lookup all work from the hand-assembled bundle |
| S5 | Runtime Metal shader compile | Compile time measured; 1,000 animated additive edges hold 60 fps in the bundled app |
| S6 | Unprivileged `proc_pidpath` coverage | Table of which process classes return a path without root |

**Exit:** each spike has a written outcome; SPEC §3 and §6.1 are updated to match; the source priority order is final.

**Needs from the owner:** S3 requires running a probe under `sudo`.

**Status: complete.** All six spikes have outcomes in [spikes/M0-findings.md](spikes/M0-findings.md), and SPEC §3 and §6.1 reflect them.

---

## M1 — Engine

**Goal:** a correct, headless model of the machine's network activity.

**Build**
- Core models (§8) and the `FlowSource` protocol.
- `NStat` adapter as the backbone, promoted from the M0 probe; `LibProc` for process detail; `Nettop` as fallback and optional supplement.
- Settle the NetworkStatistics questions left by M0: what `startAbsoluteTime` means, how reliably flows of 10–100 ms are described, and which sockets it omits compared with the kernel list as root.
- Correlator, lifecycle state machine, rate engine (§6.2–6.4), listener tracking, port-based service table.
- `Simulator` source with scenario presets (quiet desktop, busy developer, 5k-flow stress, beacon, port scan).
- Trace record and replay (`.sbtrace`).
- `sbctl top` (live terminal table), `sbctl dump --json`, `sbctl record`, `sbctl bench`.

**Verify**
- Unit tests for rates (irregular intervals, counter reset), lifecycle transitions, key reuse.
- Contract tests on recorded NetworkStatistics descriptions and on synthetic kernel-list buffers.
- Integration: start `curl`, `nc`, and `iperf3` flows from a script; assert each appears under the right PID with totals within 1% of `netstat`.

**Exit:** for the login user's processes, `sbctl top` matches `netstat -anv` over a five-minute session; engine under 1% CPU idle on the dev Mac.

**Status: complete, with one criterion partly met.** Attribution is exact to the byte, connection age is exact, short flows are caught, and the engine runs at 0.85% of a core. Inventory coverage against `netstat` is 93–95%, not 100%: NetworkStatistics omits some sockets, for a reason not yet found. Results and the full list of findings are in [spikes/M1-findings.md](spikes/M1-findings.md).

---

## M2 — First light

**Goal:** the hero view, on real data, looking the part.

**Build**
- Find the sockets NetworkStatistics omits (try its `…WithOptions` and `SetFlags` calls), and raise the counter refresh rate while the window is visible.
- Metal engine (§9.5): field, edge ribbons, shader-driven particles, SDF nodes, label atlas, bloom and tone map.
- Barnes–Hut layout on a background thread with radial bias and hash-seeded stable placement.
- Quadtree picking; hover tooltip with the full detail set from §10.1.
- Zoom, pan, pause.
- App icons and names for bundle processes.
- Cinema, Operator, and Still profiles; system Reduce Motion honoured.
- Headless `--snapshot` render from a trace, and golden images for three scenarios.

**Verify**
- Golden snapshots stable across runs.
- `sbctl bench` at 1k and 5k flows: frame times recorded as the baseline.
- Hover tooltip values cross-checked against `sbctl dump` for the same instant.

**Exit:** launch to live graph in under two seconds, no setup; 60 fps at the 5k stress scenario; a first-time viewer can tell which process is busiest without being told how to read it.

**Status: built; two exit criteria need a person.** Launch to first data is 0.6–0.8 s, the live graph runs at 119 fps, and the stress scene averages 110 fps with a worst frame of 25 ms. Golden images are pixel-stable and tooltip values match the engine exactly. Still open: nobody has yet driven the pointer and keyboard by hand, and the first-time-viewer test has not been run. Details in [spikes/M2-findings.md](spikes/M2-findings.md).

**Checkpoint with the owner:** this is the first look at the visual identity. Palette, glow level, and default profile are cheap to change here and expensive later.

---

## M3 — Operator console

**Goal:** from impressive to useful. Pass the five-second test.

**Build**
- Carried from M2: a true 5,000-node stress test and frame pacing, and loopback connections drawn as process-to-process edges.
- Window layout (§10): graph in the centre, inspector on the right, dockable panels below, top bar.
- Inspector for flows, processes, endpoints, clusters.
- Connections table with configurable columns.
- Filter language (§10.4): parser, in-memory evaluator, autocomplete, saved filters; applied to graph and table together.
- Panels: Top Talkers, Throughput, Listeners, Protocol and Port Mix, Interfaces, Health.
- Focus mode, multi-select, context menu actions.
- Endpoint clustering (domain, subnet; ASN arrives in M6) and auto-clustering threshold.
- In-memory time window with keyframes and the timeline scrubber (§10.5).
- Menu bar extra.
- Settings: collection, display, graph.
- Colour-vision validation of the palette and an alternate palette.

**Verify**
- Filter parser property tests; evaluator checked against a brute-force reference on simulator data.
- Scrubber: replaying a recorded trace reproduces the golden snapshot at a given timestamp.
- VoiceOver pass over table, inspector, and panels.
- The five-second test with someone new to the app, on real traffic.

**Exit:** usable all day on the dev Mac in Standalone mode; five-second test passed three times out of three.

**Status: built; the two exit criteria need a person.** Every item above is done except the VoiceOver pass and the five-second test, with three reductions: clustering is by network only, multi-select is ⌘-click without a lasso, and filter completion covers field names but not values. 82 tests pass. Frame pacing improved but the 60 fps floor is not yet held with the console open. Nothing has been driven by hand. Details in [spikes/M3-findings.md](spikes/M3-findings.md).

---

## M4 — Collector and Full mode

**Goal:** the privileged upgrade — hostnames, short flows, complete process detail.

**Build**
- `switchboardd`: engine host, socket publisher, peer checks, backpressure (§7).
- Wire codec with round-trip and fuzz tests; `sbctl tap --json`.
- App-side socket client, automatic Standalone ⇄ Full switching, reconnect.
- `PktapCapture`: filtering in our own code (the kernel will not filter PKTAP), `KernelSocketList` as the collector's cross-check, DNS answer parser, TLS ClientHello SNI parser, SYN/FIN timing, PID attribution for short flows.
- Hostname modes Off and Passive; source badges; DNS Activity panel.
- Observed service labels (`TLS`, `QUIC`, `DNS`).
- `scripts/install.sh` and `uninstall.sh`; the in-app "copy install command" sheet.
- Collector section in the Health panel (sources, drops, latency, CPU, memory).

**Verify**
- Parser tests on captured fixtures, including truncated and malformed packets.
- Codec fuzzing: no crash, no unbounded allocation.
- Collector CPU with unfiltered PKTAP delivery under sustained `iperf3` load, and ClientHello sizes from real browser traffic, before the snap length is fixed.
- A burst of 500 connections each under 100 ms: at least 99% attributed.
- Kill the daemon mid-session: app falls back to Standalone within two seconds and returns to Full when it restarts.
- Non-admin user is refused by the socket.

**Exit:** with the collector installed, most HTTPS flows carry a hostname with a visible source; collector within the §11 budget; install and uninstall leave no residue.

**Needs from the owner:** running the install script under `sudo`.

**Status: built and run as root by the owner.** In Full mode on real traffic the collector read 44 DNS answers and 76 TLS server names from 20,583 packets with none dropped, and the app held 117 frames a second. One TLS name in five needed more than one segment. Still unmeasured: the collector's cost under heavy traffic, coverage against `netstat`, and refusal of non-administrators. Packet-derived attribution of very short flows and clustering by domain are not built. Details in [spikes/M4-findings.md](spikes/M4-findings.md).

---

## M5 — Memory

**Goal:** everything seen is queryable later.

**Build**
- `SwitchboardStore`: schema (§8), migrations, batched writes off the main actor.
- Detail levels and retention by age and size.
- Filter AST → SQL compiler, sharing the M3 parser.
- Log Explorer: query bar, timeline histogram, result table, "replay in graph".
- Log-backed replay feeding the same path as the in-memory scrubber.
- CSV and JSONL export of selections and query results; hostname redaction option.
- First Seen panel and the first-seen halo, backed by `endpoint_first_seen`.
- Age Histogram panel.
- One-click purge.

**Verify**
- Every filter in the test corpus returns the same set from memory and from SQL.
- Seven days of simulated data: queries under 200 ms, retention holds the size cap.
- Export round-trips through `sqlite3` and `jq` checks.

**Exit:** "every connection to this address in the last week" answers in under a second and replays in the graph.

**Status: built; exit criterion met.** On seven simulated days (637,499 connections) that query takes 57 ms, and a moment from the log replays in the graph. Ten of eleven benchmark queries are under 200 ms; one is at 253 ms. The log uses the SQLite that ships with macOS rather than GRDB, so the project still has no third-party dependencies. 143 tests pass. The export dialog, the erase confirmation, and the first-seen ring have not been tried by hand. Details in [spikes/M5-findings.md](spikes/M5-findings.md).

---

## M6 — Enrichment and trust

**Goal:** turn addresses into places, organisations, and judgements.

**Build**
- MMDB reader (own implementation) with tests against the published format test data.
- `scripts/fetch-geoip.sh`; GeoIP and ASN on endpoints; cluster by ASN and country.
- Address classification (private, loopback, link-local, multicast, CGNAT).
- Code-signature evaluation (`SecStaticCode`) off the main thread, cached by path and modification time; trust rings; Process Trust panel.
- Active reverse DNS: async, cached, rate-limited, clearly disclosed.
- User tags and tag lists (corporate subnets, known good, watchlist) that colour nodes.
- New filter fields: `country`, `asn`, `org`, `signing`, `tag`, `class`.

**Verify**
- MMDB lookups checked against a reference tool for a sample of addresses.
- Signing results checked against `codesign -dv` for Apple, Developer ID, ad hoc, and unsigned binaries.
- With resolution Off or Passive, a capture shows the app emits zero packets.

**Exit:** `country!=US signing:unsigned` works live and in the log.

**Status: built; exit criterion met in tests, not yet with a real location database.** Signature verdicts agree with `codesign` for 710 of 711 installed programs (the last is one `codesign` cannot read), after fixing three faults that comparison exposed. The MMDB reader is tested on files the tests build, not on DB-IP's: `scripts/fetch-geoip.sh` is written and has to be run by the owner. No capture has confirmed that the app sends nothing with lookups off. 174 tests pass. Details in [spikes/M6-findings.md](spikes/M6-findings.md).

---

## M7 — Views and wall mode

**Goal:** the alternate views and the display modes that make it a wall piece.

**Build**
- Globe: Metal sphere, great-circle arcs, rate-weighted, same particle system.
- Sankey: process → service → organisation over a selected window.
- Swim lanes: per-process connection timelines.
- Hierarchy view.
- Animated transitions between layouts that keep selection.
- Workspaces: save, restore, and the three defaults (NOC Wall, Privacy Audit, Developer).
- Kiosk mode and multi-display placement.
- Remaining settings and JSON import/export of configuration.

**Verify**
- Golden snapshots for each layout.
- Each layout holds 60 fps at the busy-developer scenario.
- Selection survives every layout switch.

**Exit:** NOC Wall workspace runs full screen on a second display for eight hours without intervention.

**Status: part one built; exit criterion not yet met.** The flow (Sankey) and lanes layouts, transitions that keep selection, workspaces with the three defaults, kiosk mode, and five golden images are done; both new layouts draw at the display's 120 Hz on live traffic. The globe and hierarchy view are part two. Display placement and settings import and export are written and untested. Eight simulated hours ran through each layout without a window; the eight real hours on a second display have not been run. 185 tests pass. Details in [spikes/M7-findings.md](spikes/M7-findings.md).

---

## M8 — v1.0 hardening

**Goal:** make it trustworthy to leave running.

**Build and verify**
- Full §11 budget pass with `sbctl bench`; fix whatever misses.
- Draw the graph on its own thread, so the rest of the window cannot delay a frame (carried from M3).
- 72-hour soak: memory, log growth, reconnect behaviour.
- Coexistence runs: VPN, a packet-filter firewall, Docker.
- Contract fixtures recorded on every macOS version available; behaviour on unsupported layouts confirmed to degrade, not crash.
- Accessibility pass: VoiceOver, full keyboard navigation, Still profile.
- About pane listing exactly what is collected and stored.
- README, build and install guide, troubleshooting, a section on what Standalone cannot see.
- Release script: unsigned zip, checksums, quarantine instructions.

**Exit:** every success metric below is met and written down with its measurement.

---

## After v1.0

| Release | Scope |
|---|---|
| **v1.1** | Alert rules (new process, watchlist hit, new exposed listener, threshold, beacon heuristic, unsigned outbound) with local notifications · syslog, JSON, and OTLP streaming · chord and port-matrix views · encryption at rest · collector-side headless logging |
| **Later** | Per-flow packet peek · QUIC SNI extraction · multi-Mac aggregation · optional `pf`-based blocking |

---

## Success metrics for v1.0

| Metric | Target | Measured by |
|---|---|---|
| Time to name the process behind a connection | ≤ 5 s | Usability test (M3, M8) |
| Flows over 1 s attributed to process and user | ≥ 99% | Integration suite |
| Short flows (< 100 ms) attributed in Full mode | ≥ 99% | Burst test (M4) |
| Frame rate at 5,000 nodes / 2,000 active edges | ≥ 60 fps | `sbctl bench` |
| Launch to live graph | ≤ 2 s | Timed launch |
| Collector overhead over 72 h | Within §11 | Soak |
| Packets emitted by the app with resolution Off or Passive | 0 | Capture check (M6) |
| "Would put it on a wall display" | Yes, from a NOC engineer | Review at M7 |

---

## Standing rules for every milestone

1. Nothing that runs as root links third-party code.
2. Every private-interface adapter has a contract test and a runtime fallback before it is used by a feature.
3. Every visual effect maps to a datum; if it cannot be explained in the encoding table (§9.4), it does not ship.
4. A milestone is not closed until its exit criterion has been run and the result recorded.
5. The research document under `product_research/` stays out of version control.

## First steps

1. Owner decisions that shape M0: the identifier prefix and whether NetworkStatistics is acceptable (SPEC §16, items 2 and 4).
2. Package skeleton and `bundle.sh`.
3. Spikes S1, S4, S5 (no privilege needed), then S2, S6, then S3 under `sudo`.
