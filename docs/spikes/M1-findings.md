# M1 findings

What building and verifying the engine established, on macOS 27.2.1 (26B131), Apple M4, as an unprivileged user unless stated. Everything here can be re-measured:

```bash
scripts/verify.sh
```

```bash
swift build -c release && .build/release/sbctl bench && .build/release/sbctl bench --live
```

## Exit criteria

| Criterion (ROADMAP M1) | Result |
|---|---|
| `sbctl top` matches `netstat -anv` for the login user's processes | **Partly.** 93–95% of sockets from NetworkStatistics alone; 100% with the `nettop` supplement, which is too expensive to leave on |
| Each generated flow appears under the right PID, totals within 1% | **Met.** Exact to the byte |
| Engine under 1% CPU idle | **Met** at the new default: 0.85% of a core with ~150 sockets |

## Verification results

| Check | Result |
|---|---|
| Connection age | A socket created 1.52 s earlier was reported as 1.52 s old |
| Attribution and totals | 5,000,000 bytes sent through `nc` over loopback: sender `nc` outbound `tx=5000000`, receiver `nc` inbound `rx=5000000`, two different PIDs |
| Flows lasting 10 ms | 10 of 10 seen, all later reported closed |
| Flows lasting 50 ms | 10 of 10 |
| Flows lasting 100 ms | 10 of 10 |
| Inventory against `netstat` | 137–142 of 148–150 sockets (92.6–94.7%); sent bytes within 1% on 55 of 56 flows |
| Unit and contract tests | 41 passing |

## What M0 left open, now answered

**`startAbsoluteTime` is the socket's creation time, on the continuous clock.** The first attempt compared it with `mach_absolute_time` and got nothing usable, because on a Mac that has slept since boot the two Mach clocks disagree and every start time lands in the future. Against `mach_continuous_time` the reported age matches the true age to the millisecond. Connection age is therefore exact for every flow NetworkStatistics reports, including those that predate Switchboard. The "≥ 37m" approximation is only needed for flows from sources that carry no start time, such as `nettop`.

**Flows of 10–100 ms are caught reliably.** Thirty of thirty. The partial result in M0 was specific to sub-millisecond loopback connections, which do not occur over a real network.

**Which sockets NetworkStatistics omits is still not explained.** Roughly 5–8% of the login user's sockets appear in `netstat` and in `nettop` but are never delivered to us. They are ordinary established TCP connections to port 443, owned by the user's own apps (Outlook, Word, PowerPoint, a browser helper), often long-lived. None are rejected by our decoder: one update in several hundred is unreadable, and that one is an empty placeholder. Since `nettop` uses the same framework and does see them, the likely cause is its `com.apple.private.network.statistics` entitlement or an API option we are not passing. The framework exports `NStatManagerAddAllTCPWithOptions` and `NStatManagerSetFlags`, which are the first things to try.

## New findings

### `nettop` cannot be an always-on supplement

M0 proposed running `nettop` beside NetworkStatistics to see other users' flows without root. It works, and closes the inventory gap completely (152 of 152, plus 42 sockets belonging to other users). But ten one-second samples cost 12.4 seconds of CPU:

```
real 9.02   user 2.94   sys 9.48
```

That is about 1.4 cores while it runs. `nettop` is usable for a one-off "scan everything now", not as a continuous source. Seeing system daemons continuously still needs the root collector.

### The cost of NetworkStatistics is asking, not listening

| Counter refresh | CPU, ~180 sockets |
|---|---|
| 4 Hz | 2.66% of a core |
| 2 Hz | 1.52% |
| 1 Hz | 0.88% |

Cost is linear in how often we ask the kernel to describe every socket, about 0.6% of a core per refresh per second here. Sockets opening and closing arrive as events regardless and cost almost nothing. Decoding was a quarter of the original cost: bridging each 52-key dictionary to a Swift dictionary took the 4 Hz figure from 3.3% to 2.3% once replaced with direct lookups.

**Decision.** Counters refresh at 1 Hz by default, configurable up to 4 Hz. Opens and closes stay immediate. The engine still ticks at 4 Hz so lifecycle changes show promptly. M2 can raise the rate while the window is frontmost and drop it when hidden.

The engine itself is cheap: 0.29 ms per tick at 850 flows, 1.3 ms at 4,500, 8.6 ms at 18,000. At the SPEC budget of 2,000 sockets it is well under 0.5% of a core.

### `netstat` over-reports received bytes

After sending exactly 3,000,000 bytes through `nc`, `netstat -anv` showed `tx=3000000` on the sender and `rx=6068796` on the receiver. Across real flows its receive counter runs at two to three times ours, while its send counter agrees with ours to the byte on almost every flow. NetworkStatistics reports the true payload in both directions, as the 5,000,000-byte test shows. Verification therefore compares sent bytes with `netstat` and relies on the known-traffic test for received bytes.

This also affects the collector: the kernel socket list is where `netstat` gets these numbers, so it must not be used as a source of receive counters.

### The socket-list restriction follows the launching process

M0 found that the kernel hands an empty socket list to an unprivileged, ad-hoc-signed process. It goes further: `netstat` itself, Apple-signed and entitled, prints no internet sockets when `sbctl` launches it, though it prints all of them when the shell does. `nettop` launched the same way works normally.

So Switchboard cannot obtain the socket list by running `netstat` as a helper, and the verification script has to run `netstat` from the shell. `sbctl verify` signals the moment it has taken its own sample and `scripts/verify.sh` runs `netstat` then.

### Sockets the kernel is only holding

`netstat` lists connections in `TIME_WAIT` and `CLOSED` for a while after the application has closed them. NetworkStatistics reports them removed at once. The engine follows NetworkStatistics, and verification excludes those rows.

## What was built

| Piece | Where |
|---|---|
| Models, flow engine, lifecycle, rates, service table | [`Sources/SwitchboardCore`](../../Sources/SwitchboardCore) |
| Simulator with five scenarios; trace record and replay | [`Simulator.swift`](../../Sources/SwitchboardCore/Simulator.swift), [`Trace.swift`](../../Sources/SwitchboardCore/Trace.swift) |
| NetworkStatistics, libproc, and `nettop` sources | [`Sources/SwitchboardSources`](../../Sources/SwitchboardSources) |
| `sbctl top`, `dump`, `record`, `bench`, `verify` | [`Sources/sbctl`](../../Sources/sbctl) |

The engine is deterministic: a trace replayed through it reproduces the original model byte for byte, which is tested. Traces record what the sources said, not what the engine concluded, so a trace is a regression test of the engine as well as a demo.

## Carried forward

| Item | To |
|---|---|
| Find the sockets NetworkStatistics omits: try `…WithOptions` and `SetFlags` | M2, before the graph's completeness matters |
| Raise the counter rate while the window is visible | M2 |
| Root coverage of the engine (250 of 267 in M0) and the kernel socket list as cross-check for existence only, never for receive counters | M4 |
| A `nettop`-backed "scan everything once" action for Standalone mode | M3 |
