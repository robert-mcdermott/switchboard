# M4 findings — part one

The collector and Full mode. Part one is the privileged daemon, the protocol it speaks, and the app following it automatically. Part two is packet capture and hostnames.

Measured on macOS 27.2.1 (26B131), Apple M4. The automated checks below ran with the collector unprivileged on a temporary socket. **The root run was done by the owner on 2026-11-21:** installed with `sudo scripts/install.sh`, used the app in Full mode and saw processes from every account, then removed it with `sudo scripts/uninstall.sh`. That confirms the install path and Full mode work end to end; the specific measurements in "What still needs measuring as root" were not taken.

```bash
sudo scripts/install.sh
```

```bash
sudo scripts/uninstall.sh
```

## Roadmap items

| Item | State |
|---|---|
| `switchboardd`: socket publisher, peer checks, backpressure | Done |
| Wire codec with round-trip and fuzz tests | Done |
| `sbctl tap` | Done |
| App-side client, automatic Standalone ⇄ Full switching, reconnect | Done |
| Kernel socket list as the collector's cross-check | Done as a source; its root coverage not yet measured |
| `scripts/install.sh` and `uninstall.sh` | Done; run by the owner |
| The install command offered in the app | Done, in the Health panel, with a Copy button |
| Collector section in Health | Mode, what it means, and each collector source's status |
| Packet capture: DNS answers, TLS server names, short-flow attribution | Part two |
| Hostname modes, source badges, DNS Activity panel, observed service labels | Part two |

## Verification

| Check | Result |
|---|---|
| Codec round trip | Every message type, with all optional fields present and absent, decodes to what was encoded |
| Codec truncation | Every message cut at every length fails cleanly |
| Codec fuzzing | About 8,000 corrupted and random bodies: none crashes; a count larger than the message is refused before anything is allocated |
| Stream framing | Frames are recovered identically whether bytes arrive 1, 2, 3, 7, or 64 at a time |
| Collector and client over a real socket | A client that connects late is brought up to date, and its engine ends with the same connections and the same byte totals as one fed directly |
| Collector stops | The client notices and reports itself disconnected |
| Client leaves | The collector drops it |
| Second collector on the same socket | Refused |
| Wrong protocol version | Refused with the reason |
| Garbage instead of a hello | Refused; never registered as a client |
| The real daemon, unprivileged | `sbctl tap` and `sbctl top --source collector:…` both work against it; the socket is mode 0600; it is removed on exit |
| The app with the collector running | Mode reads "FULL · collector running as uid 501", 118 fps |
| The app with the collector killed at five seconds | Back in "STANDALONE · your processes" by the time it was measured, still drawing |
| The app with no collector | Standalone, as before |
| Unit tests | 104 passing |

## What still needs measuring as root

The owner's run showed the service installs, the app switches to Full mode, and other accounts' processes appear. These were not measured during it:

| Question | How to answer it |
|---|---|
| Does root NetworkStatistics plus the kernel socket list reach 100% of `netstat`? | `scripts/verify.sh` with the collector installed, once `sbctl verify` can take the collector as its source |
| Is a non-administrator refused? | Connect from a standard account |
| Does `uninstall.sh` leave nothing behind? | Check the four paths it removes |
| The burst test: 500 connections each under 100 ms, 99% attributed | Depends on capture, in part two |

## Design decisions

**The engine stays in the app; the collector forwards what its sources see.** SPEC §5.1 put the flow engine in the daemon and had it publish flow deltas. What was built has the daemon run the *sources* and publish their observations, and the app run the same engine it always has, fed from the socket instead of from local sources. The reasons:

- The privileged process does less. It gathers and forwards; it does not interpret.
- Everything above the sources is identical in both modes, literally the same code path, so Full mode cannot drift from Standalone.
- Source observations are already a stream of changes, which is what the spec wanted from deltas.

The cost is that two clients each run their own engine. For a single-user desktop tool that is the right trade.

**A client that falls behind is restarted from the present.** Each client has an outbound queue. Past 8 MB the queue is dropped and the client is sent a reset followed by the complete current state. On a reset the client reports everything it knew about as gone, and what is still there follows. Collection never waits for a reader.

**The collector serves administrators, or only its owner.** Running as root it accepts root and members of `admin`, and the socket is `0660 root:admin`. Run by an ordinary user for development it accepts only that user, with the socket `0600`. Everyone's network activity is sensitive, so the default is narrow.

**The only thing a client may send is a hello,** within three seconds and under 4 KB. After that the collector reads from the client solely to learn when it has gone.

**Switching modes restarts the engine, not the picture.** Flows are identified by the source that reported them, so they cannot be carried from local sources to the collector's. The engine starts afresh and refills within a second; the graph keeps every node where it was, because placement depends only on names and addresses.

**The kernel socket list reports received bytes as zero.** M1 found its receive counter runs at about twice the true figure. A connection known only from that list shows what it sent and no figure for what it received, rather than a wrong one. Where NetworkStatistics also reports the connection, its numbers are used.

## The protocol

A frame is a four-byte length, a type byte, and a payload. Integers are variable-length; strings carry their length. Seven message types: hello, welcome, refused, events, process, health, reset. The whole codec is one file with no dependencies, [`Wire.swift`](../../Sources/SwitchboardCore/Wire.swift).

```bash
sbctl tap --json
```

prints each event the collector publishes as a line of JSON.
