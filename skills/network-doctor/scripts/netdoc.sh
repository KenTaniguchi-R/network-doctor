#!/bin/bash
# netdoc.sh — read-only home network diagnosis for macOS.
#
# Collects evidence only. It never changes a setting, never needs sudo, and
# never touches your router's admin interface. Everything it prints is
# something you could have run by hand.
#
# Usage: netdoc.sh [--quick] [--full] [--json] [--mirror URL]

set -uo pipefail

MODE=standard
JSON=0
MIRROR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --quick) MODE=quick ;;
    --full)  MODE=full ;;
    --json)  JSON=1 ;;
    --mirror) MIRROR="${2:-}"; shift ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

if [ "$(uname -s)" != "Darwin" ]; then
  echo "netdoc: macOS only for now (uses system_profiler / networksetup)." >&2
  echo "Linux support is tracked in the README." >&2
  exit 1
fi

# ---------------------------------------------------------------- utilities

FINDINGS_FILE="$(mktemp -t netdoc-findings)"
trap 'rm -f "$FINDINGS_FILE"' EXIT

# finding <severity> <title> <detail>
finding() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$FINDINGS_FILE"; }

say()  { [ "$JSON" = 1 ] || printf '%s\n' "$*"; }
hdr()  { [ "$JSON" = 1 ] || printf '\n\033[1m%s\033[0m\n' "$*"; }

now_ms() { python3 -c 'import time;print(int(time.time()*1000))'; }

# Time one command in milliseconds. Prints the elapsed ms.
time_ms() {
  local s e
  s=$(now_ms); "$@" >/dev/null 2>&1; e=$(now_ms)
  echo $(( e - s ))
}

WIFI_IF="$(networksetup -listallhardwareports 2>/dev/null \
  | awk '/Hardware Port: Wi-Fi/{getline; print $2; exit}')"
WIFI_IF="${WIFI_IF:-en0}"

WIFI_SERVICE="Wi-Fi"

# One system_profiler call is ~1s; cache it.
SPCACHE="$(mktemp -t netdoc-sp)"
trap 'rm -f "$FINDINGS_FILE" "$SPCACHE"' EXIT
refresh_wifi() { system_profiler SPAirPortDataType 2>/dev/null > "$SPCACHE"; }
refresh_wifi

# Field from the *current* network block only.
wifi_field() {
  # NB: field names can contain "/" (e.g. "Signal / Noise"), so no sed s/// here.
  sed -n '/Current Network Information/,/Other Local Wi-Fi Networks/p' "$SPCACHE" \
    | grep -m1 -- "$1" \
    | awk -v k="$1: " '{i=index($0,k); if(i){print substr($0,i+length(k))}}' \
    | sed 's/^ *//; s/ *$//'
}

# ---------------------------------------------------------------- 1. basics

hdr "1. Link and routing"

GW="$(netstat -rn -f inet 2>/dev/null | awk '$1=="default" && $NF !~ /^bridge/ {print $2; exit}')"
IP="$(ipconfig getifaddr "$WIFI_IF" 2>/dev/null)"
V6="$(ifconfig "$WIFI_IF" 2>/dev/null | awk '/inet6 .* autoconf secured/{print $2; exit}')"

say "  interface     : $WIFI_IF"
say "  IPv4          : ${IP:-none}"
say "  IPv6          : ${V6:-none}"
say "  gateway       : ${GW:-none}"

if [ -z "$GW" ]; then
  finding HIGH "No default gateway" "No IPv4 default route. Nothing else here will be meaningful."
fi
if [ -z "$V6" ]; then
  finding INFO "No IPv6" "No global IPv6 address. Not a fault, but you lose native v6 paths."
fi

# ---------------------------------------------------------------- 2. DNS
# The highest-value check in this whole script. A resolver that is configured
# but unreachable costs ~2s on EVERY cold lookup while throughput tests stay
# green, so it is invisible to normal "is my internet slow" testing.

hdr "2. DNS resolvers"

RESOLVERS="$(networksetup -getdnsservers "$WIFI_SERVICE" 2>/dev/null | grep -E '^[0-9a-fA-F:.]+$')"
if [ -z "$RESOLVERS" ]; then
  say "  (using DHCP-provided resolvers)"
  RESOLVERS="$(scutil --dns 2>/dev/null | awk '/nameserver\[0\]/{print $3; exit}')"
  MANUAL=0
else
  MANUAL=1
fi

DEAD_COUNT=0
for r in $RESOLVERS; do
  ms=$(time_ms dig +tries=1 +time=2 "@$r" apple.com A)
  ans=$(dig +tries=1 +time=2 "@$r" apple.com A +short 2>/dev/null | head -1)
  if [ -z "$ans" ]; then
    say "  $r  ${ms}ms  NO ANSWER"
    DEAD_COUNT=$((DEAD_COUNT+1))
    finding HIGH "Dead DNS resolver: $r" \
      "Configured as a resolver but does not answer (${ms}ms timeout). Every cold lookup pays this. Remove it."
  else
    say "  $r  ${ms}ms  -> $ans"
    [ "$ms" -gt 300 ] && finding MED "Slow DNS resolver: $r" "${ms}ms to answer. Healthy is under ~50ms on a LAN."
  fi
done

# End-to-end resolution is what applications actually experience. If this is
# far worse than the fastest working resolver above, something in the resolver
# chain is stalling.
hdr "   End-to-end resolution (what apps actually feel)"
dscacheutil -flushcache 2>/dev/null
TOTAL=0; N=0
for h in github.com wikipedia.org cloudflare.com; do
  ms=$(python3 -c "
import time,socket,sys
t=time.time()
try: socket.getaddrinfo('$h',443)
except Exception: print(-1); sys.exit()
print(int((time.time()-t)*1000))")
  say "  $h  ${ms}ms"
  [ "$ms" -ge 0 ] && { TOTAL=$((TOTAL+ms)); N=$((N+1)); }
done
if [ "$N" -gt 0 ]; then
  AVG=$((TOTAL/N))
  if [ "$AVG" -gt 900 ]; then
    finding HIGH "Cold DNS lookups take ${AVG}ms" \
      "Applications stall ~${AVG}ms before any connection starts. Usually a dead or unreachable resolver in the list."
  elif [ "$AVG" -gt 250 ]; then
    finding MED "Cold DNS lookups take ${AVG}ms" "Slower than it should be; check the resolver timings above."
  fi
fi

# A resolver list containing ONLY VPN-internal addresses can starve the VPN's
# own forwarder of an upstream. Tailscale's 100.64.0.0/10 is the common case.
NONVPN=0
for r in $RESOLVERS; do
  case "$r" in
    100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) ;;
    *) NONVPN=1 ;;
  esac
done
if [ "$MANUAL" = 1 ] && [ "$NONVPN" = 0 ] && [ -n "$RESOLVERS" ]; then
  finding MED "All resolvers are inside the VPN range" \
    "Every configured resolver is in 100.64.0.0/10. A VPN's own DNS forwarder will not forward to itself, so it can end up with no upstream at all. Keep at least one non-VPN resolver."
fi

# ---------------------------------------------------------------- 3. Wi-Fi

hdr "3. Wi-Fi link quality"

SSID_LINE="$(wifi_field 'PHY Mode')"
CHAN="$(wifi_field 'Channel')"
SEC="$(wifi_field 'Security')"
SIG="$(wifi_field 'Signal / Noise')"

say "  PHY mode      : ${SSID_LINE:-unknown}"
say "  channel       : ${CHAN:-unknown}"
say "  security      : ${SEC:-unknown}"
say "  signal/noise  : ${SIG:-unknown}"

RSSI="$(echo "$SIG" | grep -oE '^-?[0-9]+' | head -1)"
if [ -n "$RSSI" ]; then
  if   [ "$RSSI" -lt -75 ]; then finding HIGH "Weak signal (${RSSI} dBm)" "Below -75 dBm the link rate collapses. Move closer or add an AP."
  elif [ "$RSSI" -lt -67 ]; then finding MED  "Marginal signal (${RSSI} dBm)" "Workable but you are leaving rate on the table. Under -65 dBm is comfortable."
  fi
fi

case "$SEC" in
  *WEP*)          finding HIGH "WEP encryption" "WEP is trivially broken. Move to WPA2-AES or WPA3." ;;
  *WPA/WPA2*)     finding MED  "WPA/WPA2 mixed mode" "Mixed mode keeps TKIP available, which is broken and caps 802.11n/ac rates. Set WPA2-AES (or WPA3) only." ;;
  *"WPA2 Personal"*|*WPA3*) : ;;
  *Open*|"None")  finding HIGH "Open network" "Unencrypted. Anyone nearby can read your traffic." ;;
esac

# --- Rate sampling. A single snapshot is not enough: an interfered link often
# --- shows a healthy peak rate and only reveals itself by collapsing between
# --- samples. This is how you tell "far away" from "someone is stepping on us".
SAMPLES=8; [ "$MODE" = quick ] && SAMPLES=4; [ "$MODE" = full ] && SAMPLES=15
hdr "   Rate stability (${SAMPLES} samples)"
RATES=""; MCSES=""
for _ in $(seq 1 $SAMPLES); do
  refresh_wifi
  r="$(wifi_field 'Transmit Rate')"; m="$(wifi_field 'MCS Index')"
  RATES="$RATES ${r:-0}"; MCSES="$MCSES ${m:--1}"
  sleep 1
done
say "  tx rates : $RATES"
say "  MCS      : $MCSES"

RMIN=$(echo $RATES | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -n | head -1)
RMAX=$(echo $RATES | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -n | tail -1)
if [ -n "$RMIN" ] && [ -n "$RMAX" ] && [ "$RMIN" -gt 0 ]; then
  say "  range    : ${RMIN} - ${RMAX} Mbps"
  # A >2x swing while sitting still is contention, not distance.
  if [ $(( RMAX * 10 / RMIN )) -ge 20 ]; then
    finding HIGH "Link rate is collapsing (${RMIN}-${RMAX} Mbps)" \
      "More than a 2x swing while stationary means airtime contention or interference, not range. See the channel analysis below."
  fi
fi

# ---------------------------------------------------------------- 4. channels

hdr "4. Channel congestion"

# Neighbour list. Signal strength is only reported for some entries depending
# on macOS version, so treat presence as the primary signal.
# Bound the range to the Wi-Fi interface's own block. system_profiler also
# prints an awdl0 (AirDrop) section whose "Current Network Information" echoes
# your own connection — running to EOF would count you as your own neighbour.
NEIGH="$(awk '
  /Other Local Wi-Fi Networks/ {inblock=1; next}
  /^        [a-z0-9]+:$/       {inblock=0}
  inblock && /Channel: /       {sub(/.*Channel: /,""); print}
' "$SPCACHE")"
if [ -z "$NEIGH" ]; then
  say "  (scan list empty — macOS sometimes returns a stale scan; rerun if this persists)"
else
  say "  neighbouring APs by channel:"
  echo "$NEIGH" | sed 's/^/    /' | sort | uniq -c | sort -rn | head -14
fi

MYCH="$(echo "$CHAN" | grep -oE '^[0-9]+')"
MYBAND="$(echo "$CHAN" | grep -oE '[0-9]+GHz')"
if [ -n "$MYCH" ]; then
  SAME=$(echo "$NEIGH" | grep -cE "^${MYCH} ")
  if [ "$SAME" -gt 0 ]; then
    finding HIGH "$SAME other AP(s) share your channel ($MYCH)" \
      "Co-channel APs split airtime with you via CSMA. Moving to an empty channel is usually the single biggest Wi-Fi win."
  fi
fi

# 2.4GHz: only 1/6/11 are non-overlapping.
if [ "$MYBAND" = "2GHz" ] && [ -n "$MYCH" ]; then
  case "$MYCH" in
    1|6|11) ;;
    *) finding MED "2.4GHz is on channel $MYCH" \
         "Only 1, 6 and 11 are non-overlapping. Channel $MYCH bleeds into two of them and receives interference from both." ;;
  esac
fi

# Recommend a clean 80MHz block. The 5GHz 80MHz blocks are fixed groupings;
# a block is only usable if every channel in it is quiet.
say ""
say "  5GHz 80MHz block occupancy (lower is better):"
BEST=""; BESTN=999
for block in "36 40 44 48" "52 56 60 64" "100 104 108 112" "116 120 124 128" "132 136 140 144"; do
  n=0
  for c in $block; do
    k=$(echo "$NEIGH" | grep -cE "^${c} .*5GHz" 2>/dev/null)
    n=$((n+k))
  done
  # A 160MHz AP occupies two adjacent blocks; count it against both.
  wide=$(echo "$NEIGH" | grep -cE "160MHz" 2>/dev/null)
  label="$(echo $block | tr ' ' ',')"
  dfs=""
  case "$block" in "36 40 44 48") dfs="(no DFS)" ;; *) dfs="(DFS)" ;; esac
  say "    ch ${label}  ${n} AP(s) ${dfs}"
  if [ "$n" -lt "$BESTN" ]; then BESTN=$n; BEST="$label"; fi
done
if [ -n "$BEST" ] && [ -n "$MYCH" ] && [ "$MYBAND" = "5GHz" ]; then
  MYN=$(echo "$NEIGH" | grep -cE "^${MYCH} .*5GHz" 2>/dev/null)
  if [ "$MYN" -gt "$BESTN" ]; then
    finding MED "A quieter 5GHz block exists: ch ${BEST}" \
      "Your channel ${MYCH} has ${MYN} co-channel AP(s); block ${BEST} has ${BESTN}. DFS blocks cost a ~60s radar check when you switch, and can auto-move if radar is detected."
  fi
fi
say ""
say "  Note: neighbours running auto-channel move over time. Re-run occasionally —"
say "  a block that is empty today can have company next week."

# ---------------------------------------------------------------- 5. latency

hdr "5. Latency and loss"

if [ -n "$GW" ]; then
  GWSTAT=$(ping -c 15 -i 0.2 -q "$GW" 2>/dev/null | tail -2)
  say "  gateway:"; echo "$GWSTAT" | sed 's/^/    /'
  GWAVG=$(echo "$GWSTAT" | awk -F'/' '/round-trip/{print int($5)}')
  if [ -n "$GWAVG" ] && [ "$GWAVG" -gt 8 ]; then
    finding MED "Gateway latency ${GWAVG}ms" "A healthy local Wi-Fi hop is 1-4ms. Elevated local RTT points at the radio, not the ISP."
  fi
fi

NETSTAT=$(ping -c 15 -i 0.2 -q 1.1.1.1 2>/dev/null | tail -2)
say "  internet:"; echo "$NETSTAT" | sed 's/^/    /'
LOSS=$(echo "$NETSTAT" | grep -oE '[0-9.]+% packet loss' | grep -oE '^[0-9.]+')
case "$LOSS" in
  ""|0.0|0) ;;
  *) finding HIGH "Packet loss to the internet: ${LOSS}%" "Any sustained loss on an idle link is a real fault." ;;
esac

# ---------------------------------------------------------------- 6. MTU
# A path MTU below 1500 while the LAN is 1500 means the WAN is tunnelled
# (PPPoE, DS-Lite, MAP-E, some VPNs). Worth knowing before debugging
# "some sites hang" or containers stalling on large transfers.

if [ "$MODE" != quick ]; then
  hdr "6. Path MTU"
  probe() { ping -c 1 -W 1200 -D -s "$1" "$2" >/dev/null 2>&1; }
  lo=1200; hi=1472
  while [ $((hi-lo)) -gt 1 ]; do
    mid=$(((lo+hi)/2))
    if probe $mid 1.1.1.1; then lo=$mid; else hi=$mid; fi
  done
  PMTU=$((lo+28))
  say "  IPv4 path MTU to the internet: $PMTU"
  if [ "$PMTU" -lt 1500 ] && [ "$PMTU" -gt 1200 ]; then
    finding INFO "IPv4 path MTU is $PMTU (LAN is 1500)" \
      "Your IPv4 is tunnelled — PPPoE (~1492), DS-Lite/MAP-E (~1452-1460), or a VPN. Normal in Japan on IPoE. If containers or a VM stall on large transfers, this is the first suspect."
  fi
fi

# ---------------------------------------------------------------- 7. speed
# Two questions: how fast is it, and WHERE is the ceiling. Comparing a single
# stream against several parallel streams separates a per-connection limit
# from a real capacity limit.

if [ "$MODE" != quick ]; then
  hdr "7. Throughput and bottleneck isolation"

  MIRRORS="${MIRROR:-}"
  if [ -z "$MIRRORS" ]; then
    MIRRORS="https://ftp.jaist.ac.jp/pub/Linux/ubuntu-releases/24.04/ubuntu-24.04.3-live-server-amd64.iso
https://mirror.leaseweb.com/ubuntu-releases/24.04/ubuntu-24.04.3-live-server-amd64.iso
https://mirror.us.leaseweb.net/ubuntu-releases/24.04/ubuntu-24.04.3-live-server-amd64.iso"
  fi

  URL=""
  for m in $MIRRORS; do
    sz=$(curl -s -r 0-1048575 -o /dev/null -w '%{size_download}' --max-time 20 "$m" 2>/dev/null)
    if [ "${sz:-0}" -gt 500000 ]; then URL="$m"; break; fi
  done

  if [ -z "$URL" ]; then
    say "  (no usable mirror reachable; skipping — pass --mirror URL)"
  else
    say "  mirror: $URL"
    CHUNK=104857599
    S1=$(curl -s -r 0-$CHUNK -o /dev/null -w '%{speed_download}' --max-time 90 "$URL")
    M1=$(python3 -c "print(f'{$S1*8/1e6:.1f}')")
    say "  single stream : ${M1} Mbps"

    t0=$(now_ms)
    for i in 0 1 2 3; do
      o=$((i*200000000)); e=$((o+52428799))
      curl -s -r "${o}-${e}" -o /dev/null --max-time 90 "$URL" &
    done
    wait
    t1=$(now_ms)
    M4=$(python3 -c "d=($t1-$t0)/1000.0;print(f'{4*52428800*8/d/1e6:.1f}')")
    say "  4 parallel    : ${M4} Mbps"

    VERDICT=$(python3 -c "
s=float('$M1'); p=float('$M4')
print('parallel_much_faster' if p > s*1.5 else 'ceiling_reached')")
    if [ "$VERDICT" = "parallel_much_faster" ]; then
      say "  -> parallel is much faster: your ceiling is per-connection, not capacity."
      finding INFO "Single-stream limited" \
        "Parallel streams (${M4}) far exceed one stream (${M1}). The bottleneck is per-TCP-connection (distant server, loss, or window), not your line."
    else
      say "  -> parallel ~= single: you are at a real capacity ceiling (~${M4} Mbps)."
      finding INFO "Capacity ceiling ~${M4} Mbps" \
        "Parallel streams do not beat a single stream, so this is the true ceiling. If your Wi-Fi PHY rate is far above this, the limit is your line or ISP, and no router tuning will move it."
    fi
  fi

  # Bufferbloat: latency under load is what makes a "fast" line feel awful.
  hdr "   Bufferbloat (latency under load)"
  if [ -n "${URL:-}" ]; then
    IDLE=$(ping -c 10 -i 0.2 -q 1.1.1.1 2>/dev/null | awk -F'/' '/round-trip/{print int($5)}')
    for i in 0 1 2 3; do
      o=$((i*300000000)); e=$((o+150000000))
      curl -s -r "${o}-${e}" -o /dev/null --max-time 40 "$URL" &
    done
    sleep 4
    LOADED=$(ping -c 12 -i 0.2 -q 1.1.1.1 2>/dev/null | awk -F'/' '/round-trip/{print int($5)}')
    wait
    say "  idle ${IDLE}ms -> under load ${LOADED}ms"
    if [ -n "$IDLE" ] && [ -n "$LOADED" ]; then
      DELTA=$((LOADED - IDLE))
      if   [ "$DELTA" -gt 100 ]; then finding HIGH "Severe bufferbloat (+${DELTA}ms under load)" "Calls and games will stutter whenever anything downloads. Enable SQM/QoS on the router."
      elif [ "$DELTA" -gt 40 ];  then finding MED  "Bufferbloat (+${DELTA}ms under load)" "Noticeable during large transfers. SQM/QoS would help."
      else say "  -> healthy (+${DELTA}ms)"; fi
    fi
  fi
fi

# ---------------------------------------------------------------- report

hdr "FINDINGS"
if [ ! -s "$FINDINGS_FILE" ]; then
  say "  Nothing notable. Your network looks healthy."
else
  for sev in HIGH MED INFO; do
    grep "^$sev	" "$FINDINGS_FILE" 2>/dev/null | while IFS=$'\t' read -r s t d; do
      printf '\n  [%s] %s\n      %s\n' "$s" "$t" "$d"
    done
  done
fi
say ""
say "netdoc changed nothing. Every fix above is yours to apply."
