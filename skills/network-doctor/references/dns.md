# DNS chains

## The dead resolver problem
A resolver that is *configured but unreachable* is far worse than no resolver at all. The
OS tries it, waits for a timeout (2-5s), then falls back. Throughput tests and ping stay
perfect, so every conventional diagnostic says the network is healthy while every new
connection stalls for seconds.

Diagnose by timing each configured resolver individually and comparing against end-to-end
`getaddrinfo()`. If end-to-end is dramatically worse than the fastest working resolver,
something in the chain is stalling.

Common sources of stale entries: a previous home or office, a VPN that was removed, a
Pi-hole or AdGuard box that moved or changed IP, a manually-set resolver never cleaned up.

## Parallel racing does not save you
It is often claimed that a resolver library races all configured servers and takes the
fastest. Do not rely on it. Measured behaviour with a dead entry present was a consistent
~2s penalty regardless. Treat any unreachable entry as a defect.

## VPN forwarders need a non-VPN upstream
If every configured resolver lives inside the VPN's own address range, the VPN's DNS
forwarder can end up with no upstream at all — it will not forward to itself, for loop
avoidance. Tailscale's `100.64.0.0/10` is the common case: a list containing only a
`100.x` address leaves MagicDNS with nothing to forward to, and lookups crawl.

Keep at least one resolver reachable outside the VPN.

## Filtering vs redundancy
If you run a filtering resolver (Pi-hole, AdGuard), a public fallback like `1.1.1.1`
silently bypasses your filtering whenever it wins. Prefer listing two paths to the *same*
filtering resolver — for example its LAN address and its VPN address — so you get
redundancy without a hole.

## Pin to a name, not an address
A self-hosted resolver on wifi with a rotating private MAC and no DHCP reservation will
change address eventually, and take your DNS with it. Resolve it by mDNS name
(`hostname.local`) or give it a reservation.
