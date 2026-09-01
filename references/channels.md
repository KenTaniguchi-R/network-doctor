# Channel planning

## 2.4 GHz
Only **1, 6 and 11** are non-overlapping in a 20 MHz world. Anything else bleeds into two
of them *and* receives interference from both — strictly worse than picking one of the
three, even a busy one. Pick whichever of 1/6/11 has the fewest and weakest neighbours.

40 MHz on 2.4 GHz is almost always a mistake in a dense area: it doubles your interference
footprint for a gain you will not keep.

## 5 GHz
80 MHz channels come in fixed blocks. You cannot straddle them:

| Block | Band | DFS |
|---|---|---|
| 36, 40, 44, 48 | W52 | No |
| 52, 56, 60, 64 | W53 | Yes |
| 100, 104, 108, 112 | W56 | Yes |
| 116, 120, 124, 128 | W56 | Yes |
| 132, 136, 140, 144 | W56 | Yes |

A block is only useful if *every* channel in it is quiet. One AP on 104 running 160 MHz
occupies 100-128, i.e. two whole blocks.

**W52 (36-48) is the only non-DFS block, which is exactly why everyone is on it.** If you
have a loud neighbour there, DFS is your only real escape.

### DFS trade-offs
- Switching to a DFS channel triggers a **Channel Availability Check**, typically ~60
  seconds of radio silence. Clients roam away or drop.
- If radar is detected the AP moves automatically. It does not go dead, but you get an
  unannounced interruption.
- Some older client devices do not support all DFS channels and simply will not see the
  network. Check anything unusual on your LAN before committing.

### Choosing
Prefer the emptiest block. Break ties toward non-DFS if you have DFS-shy clients or
cannot tolerate occasional radar moves, and toward DFS if your non-DFS options are
contended. Note that a router's channel list may not offer 144, which makes the
132-144 block unreliable at 80 MHz on that hardware.

### Re-check periodically
Most consumer routers auto-select. Your neighbours' choices move, so a block that scans
empty today can be occupied next week. This is not a one-time decision.
