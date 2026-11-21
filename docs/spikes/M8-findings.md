# M8 findings

Hardening: making Switchboard trustworthy to leave running. Measured on macOS 27.2.1, Apple M4, 5K display, release build, on this Mac's live traffic in Full mode (about 70 open connections, 125 processes, 115 listening sockets) unless a simulation is named.

## The budgets (SPEC §11)

| Budget | Target | Measured | Met |
|---|---|---|---|
| Launch to live graph | ≤ 2 s | 0.5–0.8 s | Yes |
| Event to screen | Opens and closes ≤ 300 ms | Within one feed tick (0.25 s) and a frame, by construction; not timed end to end | Not measured |
| Hover to tooltip | ≤ 1 frame | Worked out on the pointer event itself; not timed | Not measured |
| Frame rate, 5,000 nodes and 2,000 edges | ≥ 60 fps floor | Operator: 60 fps, no frame over 16.7 ms, at 5,129 nodes and 5,147 edges. Cinema: 109 fps mean, slowest 1% 20 ms, limited by the GPU | Operator yes; Cinema no |
| Frame rate, typical | 120 fps on ProMotion | Cinema 120 fps, slowest 1% 9.2 ms, worst 17 ms, panels open | Yes |
| Engine CPU, idle | < 1% | 0.11% of a core, live | Yes |
| Engine CPU, 2,000 sockets | < 3% | 0.28% at 1,810 simulated flows | Yes |
| App CPU, Operator, typical | < 10% | 12–17%, varying with live traffic | **No** |
| Collector memory | < 60 MB | 10–11 MB, flat over 74 minutes | Yes |
| App memory, 1 h window | < 400 MB | 279 MB footprint after five minutes; the one-hour figure is from the soak below | See the soak |
| Network impact, Off and Passive | Zero | The running app holds no internet sockets at all: `lsof` on its process shows one Unix socket (to the collector) and no others among its 68 open files | Yes, by inspection; no packet capture taken |

## What changed

### Drawing on its own thread

The graph was drawn by `MTKView` on the main thread, so every SwiftUI layout pass that ran long was a dropped frame. It is now drawn into a `CAMetalLayer` from a dedicated thread, paced by a display link. Pointer input stays on the main thread and shares the camera with the render thread through a lock.

| Panels open, live traffic | Before | After |
|---|---|---|
| Frames per second | 108 | 120 |
| Slowest 1% of frames | 31 ms | 9.2 ms |
| Worst frame | 138 ms | 17 ms |

### Memory: 630 MB to 279 MB

- **Location databases** were read into memory: 137 MB for DB-IP City and ASN Lite. They are now mapped from disk, and only the pages lookups touch are ever resident.
- **History** kept a full snapshot every second. Older than five minutes it now keeps one every five seconds, which is still fine enough to scrub through, and snapshots share one copy of the process list while it is unchanged.

### CPU in Operator: 26% to 12–17%

- **The menu bar menu** read the live status line in the app's scene. Every change rebuilt the scene and made AppKit redraw the menu bar item: half the main thread's work. The menu now reads its figures in a view of its own, refreshed every five seconds.
- **Operator draws at 60 fps** and Still at 30; Cinema keeps 120. At these speeds the pulses look the same.
- **Tables are rebuilt once a second**, and the readouts that change every tick (totals, frame rate, the timeline's range) update once a second, in views of their own, so the controls around them are not rebuilt.

What is left of the 12–17%: about 6–7% is the main thread, 3% the render thread, 2–3% the feed, and the rest small. Two-thirds of the main thread's share is the Connections table: AppKit animates rows in and out as short-lived connections come and go, and measures each new row's height. Turning off SwiftUI's animation for those updates does not stop AppKit's own. A table that keeps a fixed set of rows and changes their contents, or an AppKit table driven directly, is the likely way under 10%.

### The layout step at thousands of nodes

The step that pushes overlapping nodes apart bucketed them into a dictionary of arrays every frame, which at 5,000 nodes was most of the frame. It now uses a flat hash table. The pictures are identical to the pixel.

## Faults found

- **A crash before the first scene.** The render thread can ask for a frame before any scene exists, which happens when the first snapshot is slow, as with 5,000 simulated connections. Building the label list then formed an invalid range. A test now draws every layout before any scene.
- **macOS's "reopen windows?" alert blocks a launch** after the app was stopped while starting. Measurement runs now pass `-ApplePersistenceIgnoreState YES`. A person sees the alert once and can dismiss it; the guide says so.

## The soak

`Switchboard --soak FILE --hours N` writes the app's memory and CPU, frame pacing, the log's size, and the collector's memory and CPU once a minute, keeps the Mac from idle sleep for its length, and quits.

**Before tonight's fixes** (74 minutes, Cinema, panels open, 15-minute timeline):

| | Start | After 74 minutes |
|---|---|---|
| App memory (resident) | 409 MB | 373 MB, never above 466 MB |
| App CPU | 31% | 17–29% |
| Slowest 1% of frames | 52 ms | 17–37 ms |
| Collector | 10.9 MB, 1.0% CPU | 10.6 MB, 1.1% CPU |
| Log | 3.8 MB | 70 MB |

No memory grew without bound over that time.

**After** (current build, Cinema, panels open, a full hour of timeline): a four-hour run was in progress when this was written; its results are added below when it finishes.

### The log grows faster than expected on this Mac

The log grew about 57 MB an hour. The soak's log held 218,566 connections after 74 minutes, and 86% of them lasted under a second: podman and the `moor` pager connecting to ports on this Mac many times a second. Retention (30 days or 2 GB by default) bounds it, but on this Mac the size limit would be reached in under two days. 72% of the logged connections never left this Mac (156,713 of 220,089). Settings ▸ Log ▸ *Leave out connections within this Mac* now keeps them out of the log; they still show live. It is **off by default**, so nothing changes unless you choose it. Whether it should be on by default is your call.

## Other M8 items

| Item | State |
|---|---|
| About pane listing what is collected and stored | Done: **Switchboard ▸ About Switchboard: What It Collects** |
| README, guide, troubleshooting, what Standalone cannot see | Done: [README](../../README.md), [GUIDE](../GUIDE.md) |
| Release script: unsigned zip, checksums, quarantine instructions | Done: `scripts/release.sh`; built and checked locally, nothing published |
| Accessibility | The graph has a VoiceOver label and a summary that updates each second ("Constellation layout. 71 connections, receiving 3.4 KB/s, sending 23.2 KB/s. Busiest: …"), read back from the running view by `--measure`; every icon-only control has a name. **Not heard through VoiceOver**, and full keyboard navigation has not been checked |
| 72-hour soak | Not run; see above for what was |
| Coexistence: VPN, packet filter, Docker | This Mac runs GlobalProtect, Tailscale, CrowdStrike Falcon, and podman, and every measurement here was taken with them running. No packet-filter firewall run, and nothing was switched on and off to compare |
| Contract fixtures on every available macOS | One macOS version was available |

## Not done, not verified

- App CPU in Operator is 12–17%, over the 10% budget.
- Cinema at 5,000 nodes does not hold a 60 fps floor; the GPU is the limit at this window size.
- Event-to-screen and hover-to-tooltip latencies were not timed.
- No 72-hour soak, and no eight-hour unattended run on a second display (the M7 exit criterion).
- No VoiceOver session, no packet capture to confirm zero packets, no usability test of "time to name the process behind a connection".

## Tests

199 pass. Seven golden images match.
