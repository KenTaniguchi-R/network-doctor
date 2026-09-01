# Network Doctor

Find out **why** your home network is slow — with evidence — and get a ranked list of what
to change. Read-only: it measures and recommends, it never touches a setting.

An [agent skill](https://skills.sh) that works with **Claude Code, Cursor, Codex, Copilot,
OpenCode, Windsurf, Gemini, Cline, Zed** and 60+ other agents — or as a plain shell script
with no agent at all.

[![skills.sh](https://skills.sh/b/KenTaniguchi-R/network-doctor)](https://skills.sh/KenTaniguchi-R/network-doctor)

```
$ bash scripts/netdoc.sh

FINDINGS

  [HIGH] Dead DNS resolver: 10.0.0.9
      Configured as a resolver but does not answer (3032ms timeout).
      Every cold lookup pays this. Remove it.

  [HIGH] Link rate is collapsing (234-433 Mbps)
      More than a 2x swing while stationary means airtime contention
      or interference, not range. See the channel analysis below.

  [MED] A quieter 5GHz block exists: ch 132,136,140,144
      Your channel 36 has 1 co-channel AP(s); block 132,136,140,144 has 0.
```

## Why not just run a speed test?

Because a speed test answers one question, and it is frequently the wrong one. Three
common problems are completely invisible to it:

**A dead DNS resolver.** A resolver that is configured but unreachable costs ~2 seconds on
*every* cold lookup while throughput and ping stay perfect. Everything feels sluggish to
start, and every benchmark says the network is fine. Stale entries left over from an old
apartment, a removed VPN, or a former office are the usual culprit. This is the single
most common invisible problem and usually a one-line fix.

**A link that collapses rather than one that is slow.** One snapshot of your wifi rate can
look fine. Sampling it repeatedly is what reveals a link dropping from MCS 9 to MCS 3 and
back — the signature of a neighbour sharing your channel. That looks nothing like being
far from the router, and it is fixed completely differently.

**Not knowing where the ceiling is.** If four parallel streams are no faster than one, you
are at a genuine capacity limit and no router tuning will move it. If they are much
faster, your line is fine and something per-connection is wrong. People routinely spend
hours tuning wifi that was never the bottleneck.

## What it checks

| Area | What it looks for |
|---|---|
| DNS | Dead/slow resolvers, end-to-end lookup latency, VPN-only resolver lists that starve a forwarder of an upstream |
| Wi-Fi | Signal, security mode, and **rate stability sampled over time** to catch collapse |
| Channels | Co-channel neighbours, 2.4GHz overlap, and the quietest 5GHz 80MHz block |
| Latency | Gateway vs internet RTT, packet loss, jitter |
| Bufferbloat | Latency under load — why a "fast" line still stutters on calls |
| Path MTU | Detects tunnelled WAN (PPPoE, DS-Lite, MAP-E, VPN) |
| Throughput | Single vs parallel streams to **locate the bottleneck**, not just measure speed |

## Install

One command, any supported agent:

```bash
npx skills add KenTaniguchi-R/network-doctor
```

That detects which agents you have installed and offers to add it to each. To target
specific ones, or install globally rather than per-project:

```bash
npx skills add KenTaniguchi-R/network-doctor -a claude-code -a cursor -a codex
npx skills add KenTaniguchi-R/network-doctor -g -y
```

Then just ask your agent: *"why is my wifi slow?"*

### Without an agent

It is an ordinary shell script and works fine on its own:

```bash
git clone https://github.com/KenTaniguchi-R/network-doctor
cd network-doctor/skills/network-doctor
bash scripts/netdoc.sh
```

## Requirements

macOS. It uses `system_profiler`, `networksetup` and `ipconfig`, plus `curl`, `dig` and
`python3` (all preinstalled). **No sudo. No writes. No router login.**

Linux and Windows support would need a different collection layer (`iw`, `nmcli`,
`netsh`); the analysis logic is portable. PRs welcome.

## Design decisions

**Read-only, on purpose.** Router UIs differ by vendor, model and firmware, and a wrong
automated change locks people out of their own network. Real-world testing of these fixes
turned up a DFS radar-check outage, a band-priority trap that stranded a laptop on 2.4GHz,
and a DNS server that changed both IP and MAC mid-session. Each was recoverable because a
human was watching. A script running blind is a different proposition. So the report names
the exact change and a human applies it.

**Findings are ranked and explained, not just listed.** Every finding says what to do and
why it matters. A tool that prints forty numbers has moved the problem, not solved it.

**It reports what it cannot prove.** Absence from an ARP sweep is not proof a device is
gone — sleeping devices do not answer. The output distinguishes measurement from
inference.

## Notes for Japan

Common here and worth recognising:

- **DS-Lite / MAP-E (IPoE)** shows up as an IPv4 path MTU around 1452-1460 while IPv6 is a
  full 1500. This is normal and generally *better* than PPPoE, which congests in the
  evenings. Check the gate address (`dgw.xpass.jp`, `transix`, `v6plus`) in your router.
- **W53 and W56 (ch 52-140) are DFS.** More spectrum, but a ~60s radar check when you
  switch and an automatic channel move if radar appears. W52 (36-48) is the only
  non-DFS 80MHz block, which is exactly why it is always crowded.
- Buffalo, NEC and ELECOM routers commonly ship with **WPA/WPA2 mixed mode**, which keeps
  broken TKIP alive. Many also ship with **WPS enabled and its PIN printed on the case**.

## Contributing

The analysis logic is portable; only the collection layer is macOS-specific. A Linux port
would swap `system_profiler` for `iw`/`nmcli` and `networksetup` for `resolvectl`. The
findings engine, thresholds and reference docs carry over unchanged.

Issues and PRs welcome — especially real-world findings the tool missed, or false
positives it produced.

## License

MIT
