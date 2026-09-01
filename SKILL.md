---
name: network-doctor
description: >-
  Diagnose a slow, flaky, or laggy home network and produce a prioritised, evidence-backed
  findings report. Use whenever someone says their wifi or internet is slow, laggy, dropping,
  "fine on speed test but feels slow", pages take forever to start loading, video calls
  stutter, or they want their network checked, audited, or tuned — phrases like "why is my
  wifi slow", "check my network", "my internet feels slow", "improve my wifi", "network
  audit", "my connection keeps dropping", "ネットが遅い", "wifi 遅い". Also use before
  blaming an ISP, and when someone wants to know whether their bottleneck is wifi, DNS, or
  the line itself. Read-only: it measures and recommends, it never changes settings.
---

# Network Doctor

Find out *why* a network is slow, with evidence, and say what to change. This skill
diagnoses. It does not reconfigure anything.

## Why this exists

A standard speed test answers one question — how many megabits — and that question is
often the wrong one. The three problems below are common, cost real time every day, and
are all invisible to a speed test:

1. **A dead DNS resolver.** A resolver that is configured but unreachable costs roughly
   two seconds on *every* cold lookup, while throughput and ping stay perfect. Everything
   "feels slow to start" and every benchmark says the network is fine. Stale entries from
   an old apartment, a departed VPN, or a former office are the usual cause.
2. **A link that collapses rather than one that is slow.** A single snapshot of the wifi
   rate can look healthy. Only sampling it repeatedly reveals a link dropping from MCS 9
   to MCS 3 and back — the signature of a neighbour sharing your channel, which looks
   nothing like being far from the router but is fixed completely differently.
3. **Not knowing where the ceiling is.** If four parallel streams are no faster than one,
   you are at a real capacity limit and no amount of router tuning will help. If they are
   much faster, your line is fine and something per-connection is wrong. Most people spend
   hours tuning wifi that was never the bottleneck.

## Running it

```bash
bash scripts/netdoc.sh            # standard: ~3 minutes, includes throughput
bash scripts/netdoc.sh --quick    # ~45s, skips throughput, MTU and bufferbloat
bash scripts/netdoc.sh --full     # longer rate sampling, best for intermittent problems
bash scripts/netdoc.sh --mirror https://example.com/bigfile   # pick your own test file
```

macOS only for now — it leans on `system_profiler`, `networksetup` and `ipconfig`.
It needs no sudo, writes nothing, and never touches a router admin page.

## Reading the output

Findings are ranked HIGH / MED / INFO. Work top down; the ordering is deliberate, and
the first HIGH is almost always the thing actually hurting.

Interpretation notes that matter:

- **"Cold DNS lookups take ~2000ms"** — look at the per-resolver timings directly above
  it. A resolver showing `NO ANSWER` is the cause. Removing it is usually a one-line fix
  and the single biggest perceived-speed win available.
- **"Link rate is collapsing"** plus **"N other APs share your channel"** — these two
  together mean interference, not distance. Move channel. If you see the collapse
  *without* co-channel neighbours, suspect a non-wifi emitter (microwave, USB 3 enclosure,
  cordless phone) or simply weak signal.
- **"Capacity ceiling ~N Mbps"** where N is far below your wifi PHY rate — the line is
  the limit. Stop tuning wifi and go look at your plan.
- **"IPv4 path MTU is 1452"** and similar — your IPv4 is tunnelled. Normal on Japanese
  IPoE (DS-Lite / MAP-E) and on PPPoE. Harmless by itself; the first thing to suspect if
  containers or VMs stall on large transfers while the host is fine.

## Applying fixes

Deliberately manual. Router web UIs differ by vendor, model and firmware, and a wrong
change locks people out of their own network. The report names the specific change; a
human makes it.

Before changing a wifi channel or security mode, know that:

- **Switching to a DFS channel (52-144) costs a ~60 second radar check** during which the
  radio is silent. Clients will roam elsewhere or drop.
- **Many routers expose 2.4GHz and 5GHz as separate SSIDs.** After any radio restart,
  devices land on whichever SSID is higher in their saved-network priority — often the
  slow one — and will not roam back on their own. Check the priority order afterwards.
- **Dropping TKIP is safe for anything modern.** 802.11n and 802.11ac forbid TKIP, so any
  device linking above 54 Mbps is already on AES. Only genuinely pre-2006 hardware breaks.
- **Auto-channel neighbours move.** A block that scans empty today can have company next
  week. Re-run the diagnosis periodically rather than treating a channel choice as final.

See `references/` for the deeper notes on channel planning, DNS chains, and tunnelled WAN
links.

## Scope

Does: measure, correlate, rank, explain, recommend.
Does not: change settings, log into routers, guess admin passwords, or touch networks
you do not own.
