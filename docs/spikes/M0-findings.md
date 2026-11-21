# M0 spike findings

Results of the six spikes in [ROADMAP.md](../ROADMAP.md), run on macOS 27.2.1 (26B131), Apple M4, Swift 6.2 from Xcode 26.0 beta. Every probe is kept in the tree as an `sbctl probe` subcommand, so it can be rerun on any macOS version.

```bash
swift build && .build/debug/sbctl probe all
```

## Summary

| # | Question | Answer | Status |
|---|---|---|---|
| S1 | Can we read the kernel socket list directly? | The parser is exact. The kernel returns an **empty list** to an unprivileged, ad-hoc-signed process and the **full list to root** | Verified |
| S2 | Is NetworkStatistics usable without entitlements? | **Yes.** Unprivileged it reports the login user's sockets; as root, nearly all of them. Counters, RTT, and open/close events either way | Verified |
| S3 | Does PKTAP still carry process metadata? | **Yes.** Header layout matches, 95% of packets carry a PID, and delegated lookups name the real requester. Kernel-side filtering is not available | Verified |
| S4 | Does a SwiftPM-built, hand-assembled `.app` behave as a real app? | **Yes**, with one resource-lookup workaround | Verified |
| S5 | Runtime shader compilation and 1,000 animated edges at 60 fps? | **Yes.** 118 fps at 1,000 edges, 119 fps at 5,000, on a 14-megapixel window | Verified |
| S6 | What can we learn about other users' processes without root? | Path and name for every process; parent, start time, and descriptors only for our own. Root gets everything | Verified |

The headline: **the assumption that Standalone mode can see the whole machine was wrong.** It rested on `netstat -anv` working unprivileged, and `netstat` works because Apple signed it. An ad-hoc-signed binary asking the same question gets nothing. Standalone mode is still viable, through NetworkStatistics, but it sees the login user's processes rather than everything.

---

## S1 — Kernel socket list

**Question.** Read `net.inet.tcp.pcblist_n` and `net.inet.udp.pcblist_n` directly and get the same rows as `netstat -anv`.

**What was built.** [`KernelSocketList`](../../Sources/SwitchboardSources/KernelSocketList.swift) with our own struct declarations in [`CDarwinPrivate.h`](../../Sources/CDarwinPrivate/include/CDarwinPrivate.h), written against the published XNU source. The structs are packed to 4 bytes, which is not what natural alignment would give. Every record's kernel-reported length is checked against `sizeof` before it is read.

**Result: the parser is correct.** Against buffers recorded at the same instant as a `netstat -anv` run:

```
record layout (kernel-reported length vs this build):
  socket  104 == 104      stats   136 == 136
  rcvbuf   32 == 32       inpcb   104 == 104
  sndbuf   32 == 32       tcpcb   204 >= 44
ours 268, netstat 268
matched on (protocol, family, local port, remote port, pid): 268
rx bytes: 268 identical
tcp state: 213 of 213 identical
```

**Result: the live read is gated by who is asking.** The same `sysctlbyname` call, same user, same moment:

| Caller | Signature | Bytes returned |
|---|---|---|
| `/usr/sbin/netstat` | Apple, with `com.apple.private.network.statistics` | full list |
| `/usr/sbin/sysctl` | Apple | 135,568 |
| Xcode's `python3` via `ctypes` | Apple | 136,184 |
| A 20-line C program | ad hoc | **48** (header and trailer only) |
| `sbctl` | ad hoc | **48** |

The size query still reports the full size to everyone; only the contents are withheld. Buffer size makes no difference. M1 later found the restriction also follows the launching process: `netstat` itself prints no internet sockets when `sbctl` starts it ([M1 findings](M1-findings.md)). The recorded buffers above were captured through the Apple-signed Python and then parsed by `sbctl`.

**Result: root lifts the restriction.** Run under `sudo`, the live read returned 267 sockets across 109 processes and matched `netstat -anv` on all 267, with 266 byte counters identical (one grew in between) and 210 of 210 TCP states identical.

**Decision.** The kernel socket list cannot be the Standalone backbone, but it is a complete, cheap inventory for the collector. There it serves as the cross-check and safety net behind NetworkStatistics.

**Cost.** One full live TCP+UDP sample as root took 1.26 ms of CPU, about 0.5% of a core at 4 Hz, so it is polled at 1 Hz rather than 4.

---

## S2 — NetworkStatistics

**Question.** Does the private framework behind `nettop` work for a process with no entitlements, and does it report flows as events?

**What was built.** [`NStatProbe`](../../Sources/SwitchboardSources/NStatProbe.swift). The framework is opened with `dlopen` and its ten functions resolved with `dlsym`, never linked, so a missing symbol is a reported condition rather than a launch failure.

**Result: it works unprivileged.**

```
framework loaded, all 10 symbols resolved
initial inventory: 170 sources added, 341 described (uid 501)
by provider: TCP 147, UDP 23
owning processes: 92 — own user 91, root 1
```

`netstat` showed 278 sockets at the same moment, so unprivileged NetworkStatistics covers about 60% of sockets: essentially those of the login user. System daemons running as root or as service accounts are not reported.

**What each source carries** (52 keys). The useful ones:

| Need | Keys |
|---|---|
| Identity | `processID`, `processName`, `uniqueProcessID`, `epid`, `uuid` |
| Endpoints | `localAddress`, `remoteAddress` (as `sockaddr` blobs), `interface`, `ifWiFi` / `ifWired` / `ifLoopback` |
| Volume | `rxBytes`, `txBytes`, `rxPackets`, `txPackets`, split by Wi-Fi, wired, cellular |
| Health | `rttAverage`, `rttMinimum`, `rttVariation`, `txRetransmittedBytes`, `rxDuplicateBytes`, `rxOutOfOrderBytes` |
| State | `TCPState`, `connectAttempts`, `connectSuccesses` |
| Time | `startAbsoluteTime`, `durationAbsoluteTime` |

`startAbsoluteTime` is a bonus: if it is the socket's creation time, connection age is exact even for flows that predate Switchboard, and the "≥ 37m" approximation in SPEC §6.4 is only needed as a fallback. Confirming its meaning is an M1 task.

**Short-lived flows: partial.** Three loopback connections lasting 0.4–1.2 ms produced six sockets. Two were described before they vanished, and both were later reported removed. Open and close events do arrive, but a description requested after the "added" event can lose the race with a sub-millisecond flow. Real connections involve a network round trip and live far longer; M1 should repeat this with 10–100 ms flows and try the framework's `…WithOptions` variants, which may deliver the description with the event.

**As root it sees nearly everything.** 250 sources across 116 processes, 99 of them owned by other accounts, against 267 sockets in the kernel list at about the same time. The gap of 17 is unexplained so far; M1 should diff the two lists to see which sockets NetworkStatistics omits. The sub-millisecond test gave the same partial result as root (2 of 6).

**Decision.** NetworkStatistics is the primary source in both modes. In the collector the kernel socket list runs beside it to catch whatever it omits.

---

## S3 — PKTAP

**What was built.** [`PktapProbe`](../../Sources/SwitchboardSources/PktapProbe.swift), plus DNS and TLS server-name parsers with tests in [`PacketParsers.swift`](../../Sources/SwitchboardSources/PacketParsers.swift). `pcap_set_want_pktap` is exported by libpcap but absent from its headers, so we declare it ourselves, along with the header struct.

**Result: it works on macOS 27.2.** Eight seconds on `pktap,all` as root, 821 packets, no kernel drops:

| Check | Result |
|---|---|
| Header length | 156 bytes on all 821 packets, matching our declaration |
| Packets carrying a PID | 781 of 821 (95%); the rest are attributed to no process |
| Direction flags | 426 in, 395 out |
| Link-header length from the kernel vs from the link type | agreed on all but 1 packet |
| IP and transport parsed | 798 |
| Delegated attribution | The probe's own lookup appeared as `mDNSResponder(664) for sbctl(75805)`: the effective PID named the real requester |
| TLS server names | 4 of 4 ClientHellos yielded a name, each attributed to its process |

Delegated attribution is the important one. DNS on macOS is sent by `mDNSResponder` on everyone's behalf, and PKTAP still says on whose behalf, so a DNS answer can be tied to the process that asked.

**Result: no kernel-side filtering.** libpcap refuses to compile a BPF filter for this link type ("Apple DLT_PKTAP link-layer type filtering not implemented"). The narrow filter in SPEC §6.7 has to be applied in our own code after the packet is delivered, so the collector sees every packet's first bytes. At the 100 packets per second observed here that is trivial; under sustained heavy traffic it is the collector's main CPU cost and needs measuring in M4.

**Not settled: ClientHello size.** All four ClientHellos fit in one segment, with the name at offset 114–118, but three were from one app and none from a browser. Browsers send larger hellos with shuffled extensions, and four samples cannot rule out names landing in a second segment. M4 measures this against real browser traffic before fixing the snap length.

**Coexistence.** The machine was running an endpoint security agent throughout; capture worked beside it.

---

## S4 — App bundle without Xcode

**Question.** Does an executable built by `swift build` and wrapped by a script behave as a first-class app?

**What was built.** [`scripts/bundle.sh`](../../scripts/bundle.sh): builds, assembles `Switchboard.app`, writes `Info.plist`, signs ad hoc, verifies the signature.

**Result: yes.** The running app reported on itself:

| Check | Result |
|---|---|
| Launches as a regular app, becomes active | yes |
| Main window (`WindowGroup`) | present |
| Menu bar extra | `NSStatusBarWindow` present |
| Settings scene | opened as "Switchboard Settings" |
| `codesign --verify --strict` | passes |
| Resources loaded from | `Contents/Resources` inside the app |

**One workaround was needed.** SwiftPM's generated `Bundle.module` looks for the resource bundle at the top level of the `.app`, then at an absolute path inside the build directory:

```swift
let mainPath = Bundle.main.bundleURL.appendingPathComponent("Switchboard_SwitchboardRender.bundle").path
let buildPath = "/Users/…/.build/arm64-apple-macosx/release/Switchboard_SwitchboardRender.bundle"
```

The first is not where resources belong in an app, and the second works only on the machine that built it, which would hide the problem until someone else ran the app. [`RenderResources`](../../Sources/SwitchboardRender/RenderResources.swift) checks `Contents/Resources` first and reports which location it used.

**Decision.** The build stays SwiftPM-only. No Xcode project.

**Toolchain note.** A plain `cc` invocation failed to link, because the default SDK lookup resolves to the Command Line Tools' 27.2 SDK and the Xcode 26 linker cannot read it. `swift build` is unaffected. Any script that calls the C compiler directly must pass `-isysroot "$(xcrun --sdk macosx --show-sdk-path)"`.

---

## S5 — Runtime shaders and the render prototype

**Question.** Is compiling Metal shaders from source at launch fast enough, and do 1,000 animated, additively blended edges hold 60 fps?

**What was built.** [`PrototypeRenderer`](../../Sources/SwitchboardRender/PrototypeRenderer.swift) and [`EdgePrototype.metal`](../../Sources/SwitchboardRender/Shaders/EdgePrototype.metal): instanced quadratic Bézier ribbons tessellated in the vertex shader, with travelling pulses computed in the fragment shader. One draw call, no per-frame CPU work per edge.

![Prototype frame, 1,000 edges](m0-render-prototype.jpg)

**Result: comfortably yes.** Release build, 120 Hz display, window of 5120 × 2756 pixels, five-second measurement after a two-second settle:

| Edges | Frames/s | Median frame | p99 frame | Worst frame | GPU mean | GPU p99 |
|---|---|---|---|---|---|---|
| 1,000 | 118.2 | 8.33 ms | 16.9 ms | 20.9 ms | 1.7 ms | 4.4 ms |
| 5,000 | 119.4 | 8.33 ms | 16.0 ms | 18.6 ms | 3.9 ms | 6.8 ms |
| 20,000 | 84.5 | 12.5 ms | 27.4 ms | 29.4 ms | 13.8 ms | 21.9 ms |

The SPEC §11 budget is 2,000 active edges. At 5,000 the GPU uses under half of a 120 Hz frame, at 14 megapixels. That is headroom for nodes, labels, and bloom, not proof that the full pipeline fits; M2 re-measures with every pass in place.

**Shader compilation:** 51 ms on the first launch of a build, 1 ms afterwards (the system caches compiled shaders). The 200 ms worry in SPEC §3.2 does not materialise for one shader file.

**Caveats.**
- The very first launch of the first build showed a single 370 ms hitch. It did not recur in three later runs. Worth watching, not yet explained.
- p99 frame times near 16 ms mean an occasional dropped frame at 120 Hz. Frame pacing gets proper instrumentation in M2.
- The frame above was captured by reading the drawable back to a PNG ([`FrameCapture`](../../Sources/SwitchboardRender/FrameCapture.swift)). That mechanism is the start of the headless snapshot tests.

---

## S6 — Process identity without root

**Question.** What can an unprivileged process learn about processes it does not own?

**Result.**

| Owner | Processes | Path (`proc_pidpath`) | Parent and start time (`PROC_PIDTBSDINFO`) | Descriptor list |
|---|---|---|---|---|
| Login user | 858 | 856 | 858 | 858 |
| root | 182 | 182 | 0 | 0 |
| Other accounts | 91 | 91 | 0 | 0 |

The owner and short name come from the `kern.proc.pid` sysctl and are available for everything.

**Decision.** Executable path, and therefore icon, bundle name, and code-signature trust, are available for every process in Standalone mode. Parent process and exact start time for other users' processes need the collector. Since unprivileged NetworkStatistics only reports the login user's sockets anyway, this gap rarely shows.

---

## What changes in the plan

1. **Standalone mode shows the login user's network activity, not the whole machine.** That covers browsers, chat, sync clients, developer tools: what most people mean by "what is my Mac talking to". System daemons need the collector.
2. **NetworkStatistics replaces the kernel socket list as the primary source**, in both modes. It is event-driven and carries RTT and retransmits, which the socket list never did.
3. **The kernel socket list becomes the collector's cross-check**, polled at 1 Hz, since root can read it and it is complete.
4. **`nettop` moves up, not down.** It is Apple-signed and entitled, so a `nettop` subprocess is the one unprivileged way to see other users' flows. M1 measured it at about 1.4 CPU cores while sampling, so it is an on-demand scan, not a continuous supplement.
5. **Capture filtering moves into our code**, because the kernel will not filter PKTAP for us.
6. **Full mode's claim holds.** As root: every socket, every process's detail, per-packet attribution, hostnames from DNS and TLS.

## Rerunning

```bash
swift build && sudo .build/debug/sbctl probe all
```

The root results above come from this command, run on 2026-11-20.
