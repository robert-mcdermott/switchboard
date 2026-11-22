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
| App memory, 1 h window | < 400 MB | 314 MB resident with the hour full (median over 2.5 hours, peaks to 369 MB), still rising about 9 MB an hour; see the soak | Yes over 2.5 hours; not shown flat |
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
- **New connections' traffic went missing, in both modes.** Found by the owner: `ollama pull` downloading at 78–90 MB/s showed almost nothing received while it ran, then, once it finished, a spike of nearly 3 GB/s that added up to the whole download, and throughout a little *sent* traffic about 1% of the download's size. Measured with a loopback transfer at a known rate (a local HTTP server streaming to `curl`) and a small harness that subscribes to NetworkStatistics directly:
  - *NetworkStatistics tells an ordinary user about another process's new socket only when it closes.* A subscription running as the login user never reported `curl`'s connection while it was open, whether `curl` started 5 seconds or 75 seconds after it subscribed; it reported it at the close, with every byte at once. Its own process's new sockets are reported live, and so is every socket that already existed when it subscribed, with counters that keep updating. As root (the collector) most new connections are reported as they open, but not all: four of five in one test, about 77% of established connections in the collector's own count. Calling `AddAllTCP` again on the same subscription adds nothing; other query calls make no difference. `nettop` holds a private entitlement and is not limited this way. Standalone mode has always had this blind spot: earlier coverage checks counted sockets at a moment, and short tests started the transfer before the subscription, so they saw it.
  - *The engine let whichever source reported a socket first own it for life.* The collector's kernel socket list reports received bytes as zero (its counter runs at two to three times the truth, per M1) and counts the acknowledgements a download sends back as sent. Connections it reported first, or alone, showed nothing received and a little sent. The spike at the end was the full count arriving at the close.
  - *Fixed:* NetworkStatistics now subscribes afresh every 5 seconds as a user and every 10 seconds as root, since a new subscription reports every open socket and keeps it current. Each socket is published under an ID made from the socket itself (protocol, process, local port, creation time), so a connection continues across subscriptions instead of closing and reopening; during the 1.5-second handover only the newest subscription's report of a socket is used, and its counters are never allowed to go backwards. In the engine, sources rank by how far their counters can be trusted, and NetworkStatistics takes over a connection the kernel list reported first. The collector compares its two sources every 30 seconds for the Health tab.
  - *Measured:* three 8-second downloads by `curl`, 20 to 58 seconds into a recording as the login user, each reported live from its first second, under one ID, received bytes climbing from 0 to 85 MB without going backwards. A test against the real framework has `nc` open a connection 8 seconds after subscribing and requires a live report before it closes; with renewal switched off it fails as the owner's download did. The recorder, source and engine together used 2.5% of a core; renewal re-describes the sockets the once-a-second counter refresh already touches, so it adds a fraction of that.
  - *Measured through the collector* once reinstalled, as root with packet capture on and the app connected. Three 8-second downloads by `curl` were run, each starting at a different point in the 10-second cycle. Each was reported within a second, under one ID, its received bytes climbing about 10 MB a second without going backwards. The kernel list's reports of the same connections carried nothing received, as intended. Midway through a fourth download the engine showed it at 10.7 MB/s received and nothing sent, against `curl`'s cap of 10 MiB/s. The collector's own check found 70 of 71 established connections reported, where before the fix it found 42 to 52 of 54 to 72. Over a quiet minute the collector used 2.2% of a core and 12 MB of memory. Not yet confirmed with a real `ollama pull`.
  - *Found while measuring:* two of the three `curl` connections read `synSent` for up to 3.6 seconds while data was already arriving, until the next renewal described it again as `established`. Counter updates repeat the TCP state from a socket's last description. As root, a socket is first described as it appears, before it has opened. Byte counts and closing were not affected; the inspector's "TCP state" row and `sbctl top` showed the stale state. *Fixed:* a TCP socket whose last state was opening is described again on each counter refresh until it is not. As the login user, the framework describes a process's own connections only after they open, so a test there cannot reproduce this. Measured through the collector instead with five more downloads by `curl`. Four began between renewals: each had two reports saying `synSent`, the first description and the first counter update, which asks for the new description. Every report after that said `established`, by 1.3 to 2.1 seconds after `curl` started. The fifth began just after a renewal and read `established` from its first report.
- **A flag with no value could stop the window opening.** AppKit reads the command line as `-key value` pairs and takes anything left over as a document to open, and an app launched to open a document opens no window of its own. `--kiosk`, `--keep-ended`, or `--hide-this-mac` before another option shifted the pairs and left a value over, so the app ran with no window. Found when a measurement with `--hide-this-mac` never finished. The app now registers `NSTreatUnknownArgumentsAsOpen = NO`; it opens no documents.
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

**After tonight's performance work, with the leak below** (76 minutes, Cinema, panels open, a full hour of timeline):

| | Median | Range |
|---|---|---|
| App memory (resident) | 296 MB | 246–389 MB, rising as the hour of history filled |
| App footprint at 66 minutes | 574 MB | of which about 290 MB is GPU memory for a 2548 × 2880 pixel window |
| App CPU | 24% | 11–26% |
| Frames per second | 118 | 109–120 |
| Slowest 1% of frames | 14.6 ms | 9–16 ms |
| Collector | 10.7 MB, 1.1% CPU | 10.3–11.2 MB |

The worst frames, 162 ms at minute 11 and 2.7 s at minute 68, are my own doing: `sample` and `heap` pause the process they inspect, and both were run then. Other copies of the app were also running for measurements during part of this soak.

### A leak, found by the soak

`heap` on the soaking app showed **79,076 live `NSError` objects**, growing at about 20 a second. The feed thread runs for the life of the app and never drained its autoreleased objects. Four times a second it asked again about the signatures of the processes it could not read, and each failed file check left an error behind. The loop now has its own autorelease pool, and each process is asked about once. A fresh instance held 2 errors, unchanged over two minutes. The collector's loop follows the same pattern and now has a pool too; its memory was flat for over two hours, so it did not show the problem.

The same heap listing shows where the hour of history goes: 1,083 lists of connections, 83 MB in all, and 928 lists of processes (17.5 MB) that were meant to be shared between snapshots. An unchanged "still unknown" signature verdict counted as a change four times a second; it no longer does, but processes coming and going still make most lists distinct.

**Fixed build** (2.5 hours from 04:25, Cinema, panels open, a full hour of timeline, nothing else measuring it). The display turned itself off at 06:37 when another program's keep-awake timer ran out; the soak keeps the Mac awake but not the display. Drawing stopped with it, which is correct, so the table splits there:

| | Display on (5–132 min) | Display off (134–151 min) |
|---|---|---|
| App memory (resident), median | 314 MB | 299 MB |
| App memory, range | 200–369 MB | 243–319 MB |
| App CPU | 24.5% median, 19–28% | 7.5% median, 7–8% |
| Frames per second | 118 median, 116.5–118.8 | none drawn |
| Slowest 1% of frames | 14.6 ms median, 10–16 ms | |
| Worst frame in each minute | 41 ms median, 17–67 ms | |
| Collector | 11.2 MB, 1.1% CPU; 10.4–15.5 MB | the same |
| Log | 4.1 MB at the start | 136.5 MB at the end: 53 MB an hour |

Memory while the hour of history fills, then after (median of each ten minutes):

| Minutes | 5–15 | 25–35 | 55–65 | 70–80 | 85–95 | 100–110 | 115–126 |
|---|---|---|---|---|---|---|---|
| Resident | 253 MB | 272 MB | 307 MB | 314 MB | 316 MB | 318 MB | 321 MB |

What this shows:

- **Within the 400 MB budget** for a one-hour window: the median is 314 MB once the hour is full. Short peaks reach 369 MB.
- **Not yet flat.** After the hour filled, resident memory still rose about 9 MB an hour, from 314 to 321 MB over 50 minutes. That is a tenth of the leak's rate, and could be caches that stop growing (names and addresses seen so far), but 2.5 hours cannot tell that apart from a slow leak. At that rate a 72-hour run would cross 400 MB after about nine more hours. Comparing two `heap` listings an hour apart is the next step, and a 72-hour soak the real answer.
- **CPU with nothing drawn is 7.5%.** That is the feed, the history, and the panels' tables, which keep updating while the display is off. The tables could stop updating while the window is not visible.
- **One frame each minute takes about 40 ms**, while the slowest 1% stay under 16 ms. Something periodic stalls the render thread for two or three frames; not found yet.
- **AppKit warned 1,930 times** that the app "performed a reentrant operation in its NSTableView delegate", about once every five seconds, and says this will become an assertion. It comes from SwiftUI's `Table` updating rows while AppKit is asking about them. The same tables are most of the main thread's CPU, so replacing them would fix both.

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
- App memory still rose about 9 MB an hour after the hour of history filled; whether it levels off is unknown.
- One frame a minute takes about 40 ms; the cause is not found.
- SwiftUI's tables trigger an AppKit warning about reentrant table updates every few seconds.
- Cinema at 5,000 nodes does not hold a 60 fps floor; the GPU is the limit at this window size.
- Event-to-screen and hover-to-tooltip latencies were not timed.
- No 72-hour soak, and no eight-hour unattended run on a second display (the M7 exit criterion).
- No VoiceOver session, no packet capture to confirm zero packets, no usability test of "time to name the process behind a connection".

## Tests

204 pass. Seven golden images match. The app target now has tests of its own: workspaces (the three defaults, replacing and restoring them, a damaged list) and settings export and import (a round trip, and a file that tries to set anything other than Switchboard's own settings).
