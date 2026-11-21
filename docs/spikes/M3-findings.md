# M3 findings

The operator console, delivered in two parts. Measured on macOS 27.2.1 (26B131), Apple M4, 120 Hz display, release build.

![The console scrubbed six seconds into the past, with two processes selected](m3-console.jpg)

```bash
scripts/bundle.sh && open build/Switchboard.app
```

## Roadmap items

| Item | State |
|---|---|
| Filter language: parser and in-memory evaluator | Done |
| Filter applied to graph and table together | Done; also to every panel and the inspector |
| Field completion and saved filters | Field names complete as you type; filters can be saved, recalled, and removed. Values do not complete |
| Window layout: top bar, graph, inspector, panels | Done |
| Inspector | Done, for one item or several |
| Connections table with configurable columns | Done: 16 columns, sortable, show/hide and reorder |
| Panels | Top Talkers, Throughput, Protocols, Interfaces, Listening, Health |
| Focus mode | Done |
| Multi-select | ⌘-click adds or removes; the inspector totals the selection. No lasso |
| Context menu | Filter to This, Focus on This, Copy Details, Reveal in Finder, Expand or Collapse a network |
| Destination clustering and automatic threshold | Done, by network (/24 for IPv4, /48 for IPv6). Clustering by domain waits for hostnames in M4 |
| In-memory time window and timeline scrubber | Done, with one difference from the spec (below) |
| Menu bar extra | Top three talkers |
| Settings | Launch profile, colours, clustering, history length. No collection settings yet |
| Colour-vision validation and an alternate palette | Done; the standard palette fails and the alternate passes (below) |
| On-demand scan of all accounts | Done, in the Health panel |
| Loopback connections between processes | Done |
| 5,000-node stress test and frame pacing | Tested; pacing improved but the 60 fps floor is still not held (below) |
| VoiceOver pass; the five-second test | Not done: both need a person |

## Verification

| Check | Result |
|---|---|
| Unit tests | 82 passing |
| Filter against direct evaluation | 300 random expressions agree with evaluating them directly on every flow of a simulated machine |
| Clustering | Addresses in one network merge into one node, only past the threshold in automatic mode, and expand and collapse on request |
| Local connections | A client and server on loopback are drawn as one line between their two processes, bowed toward the centre |
| History | A held moment is shown while the present keeps arriving unseen, and returning to the present shows everything that arrived |
| Time window | Finds the moment at or before a time; forgets what is too old; keeps less when there is more to remember |
| Palette | Both palettes checked under simulated protanopia, deuteranopia, and tritanopia |
| Golden images | Unchanged for quiet and developer; the stress image changed slightly, as intended, when clustering came on |
| The running window | Launched scrubbed four seconds back with two processes selected: the timeline showed the past moment, the inspector read "2 items" with 77 connections, and the Protocols panel ranked services and ports |
| The scan | On this Mac it found 35 sockets in 12 processes belonging to other accounts |

**Still not verified by hand.** The pointer and keyboard have now gone three milestones without a person using them. Everything interactive is wired up, compiles, and has its logic unit-tested; the window is checked by launching the app with its state set from the command line and having it save a picture of itself. Clicking, ⌘-clicking, double-clicking, right-clicking, dragging the timeline, sorting and rearranging columns, the shortcuts, and typing in the filter field have not been tried in use.

## Frame pacing

| Scene | Nodes | Edges | Frames/s | Slowest 1% | Worst frame | GPU mean |
|---|---|---|---|---|---|---|
| Stress, graph only — before | 4,831 | 4,848 | 103.5 | 42.8 ms | 63.2 ms | 7.7 ms |
| Stress, graph only — after | 4,824 | 4,839 | 109.8 | 23.4 ms | 33.7 ms | 8.0 ms |
| Stress with the table open — before | 4,804 | 4,821 | 98.1 | 63.1 ms | 123.3 ms | 4.4 ms |
| Stress with the table open — after | 4,809 | 4,823 | 105.4 | 35.6 ms | 128.6 ms | 4.2 ms |
| Developer scene with the console open | 103 | 102 | 105.5 | 27.4 ms | 120.4 ms | 3.8 ms |

This is the first test at the size the spec budgets for, and the GPU is comfortable at it: 8 ms of a 16.7 ms frame. The stalls were on the CPU, from two causes that are now fixed:

- **The scene rebuild held the lock the renderer needs.** With ten thousand flows a rebuild takes tens of milliseconds, four times a second, and any frame that arrived during one waited for it. The rebuild now works on a copy and takes the lock only to swap the result in.
- **Table data was computed on the main thread,** even when no table was showing. It is now computed in the background, and rows are only built while the Connections table is on screen.

**The 60 fps floor is still not held.** What remains is SwiftUI laying out the tables and inspector when new data arrives each second, on the same thread that draws the graph. That costs 25–35 ms about once a second, and over 100 ms occasionally. The lasting fix is to draw the graph on its own thread, so nothing the rest of the window does can delay a frame. That is a contained change to the renderer and is scheduled for M8.

## Colour vision

The smallest difference between any two service colours, in CIELAB units, after simulating each deficiency. Around 10 is where two colours stop being easy to tell apart at a glance.

| Palette | Normal | Protanopia | Deuteranopia | Tritanopia |
|---|---|---|---|---|
| Standard | 34.2 | 20.0 | 12.6 | **8.3** |
| Colour-safe | 44.8 | 20.7 | 17.7 | 16.1 |

The standard palette does not pass: under tritanopia its cyan (TLS) and green (DNS) nearly merge, and under deuteranopia its amber and orange are close. The colour-safe palette, after Okabe and Ito with a darker grey for "other", stays above 16 in every case. It is one setting away, and the test that produced these numbers runs with the rest.

The first draft of the colour-safe palette was no better than the standard one: its purple and its grey came within 9.0 under deuteranopia. Measuring caught that; choosing by eye would not have.

## Differences from the spec

| SPEC said | Built | Why |
|---|---|---|
| A ring buffer of deltas with a keyframe every 10 s | One whole snapshot per second | Far simpler, and any moment can be shown without replaying. The cost is memory, so the window is bounded by flow records as well as age: a very busy machine keeps less than the configured minutes |
| A one-hour window by default | 15 minutes by default, up to 60 in Settings | Follows from the above |
| Clustering by domain, ASN, country, or subnet | By network only | The others need hostnames (M4) and GeoIP (M6) |
| Lasso selection | ⌘-click only | Not built |

## Design decisions

**Pausing and scrubbing are the same thing.** Pause holds the current moment; dragging the timeline holds an earlier one. Either way the graph and every table show that moment, collection continues unseen, and LIVE returns to the present.

**A filter that does not parse changes nothing.** The field turns red with the reason and the last good filter stays in force.

**A flow with no measurement satisfies no comparison on it.** `rtt<50` and `rtt>=0` are both false for a flow with no round-trip time.

**Loopback connections join two processes when we can tell which two.** If some process is listening on the port a loopback connection goes to, the line runs from the connecting process to that one, through the middle of the ring. If not, the traffic counts toward the process and nothing more is drawn. There is never a "127.0.0.1" node.

**The scan is a button, not a mode.** `nettop` sees every account but uses a full CPU core while it runs (M1). The Health panel offers one three-second scan and reports what Standalone mode is not showing.

**The table holds at most 1,500 rows,** the busiest, with a notice when the cap applies.

## Using it

| Do this | To |
|---|---|
| Type in the filter field, or press `/` | Narrow everything to matching connections |
| Click the star beside the filter | Save, recall, or remove filters |
| Click a node, a line, or a table row | Pin it in the inspector |
| ⌘-click | Add to, or remove from, what is pinned |
| Double-click a node or line | Focus on its neighbourhood. Esc releases |
| Right-click a node or line | Filter, focus, copy, reveal in Finder, expand or collapse a network |
| Drag the timeline, or press space | Go back in time, or hold this moment. LIVE returns |
| Click a column header; right-click the header | Sort; show, hide, and reorder columns |
| `I`, `B`, `P`, `0` | Inspector, panels, profile, reset view |

## Carried forward

| Item | To |
|---|---|
| A person uses the pointer and keyboard; VoiceOver pass; the five-second test | Before M4 if possible |
| Draw the graph on its own thread to hold the 60 fps floor | M8 |
| Clustering by domain | M4, with hostnames |
| Clustering by ASN and country | M6 |
| Value completion in the filter; lasso selection; collection settings | Backlog |
