# netbond

Combine two internet uplinks on a Linux desktop into one faster path for
**multi-connection downloads** — Steam, torrents, package mirrors, browsers —
using nothing but the kernel's own multipath routing. No VPS, no tunnel, no
subscription, no proprietary bonding service.

Measured on a fiber + phone-hotspot setup:

| Configuration | Throughput |
|---|---|
| Primary link alone (saturated) | 162 Mbit/s |
| **Both links, weighted ECMP** | **307 Mbit/s** |

That is a real `1.9x` on a 20-connection download. See
[Limitations](#limitations) for why a *single* download does not speed up.

## Why this is not just `ip route add`

Five things go wrong if you only add a multipath default route. Each one is
handled here, and each one cost real debugging time to find:

1. **`fib_multipath_hash_policy` defaults to `0`.** With the default the kernel
   often hashes everything to one nexthop, so you get zero benefit and no error
   message. This sets policy `1` (L3+L4) so each TCP flow lands on a link.
2. **NetworkManager owns the default route and overwrites yours** on every DHCP
   renew, reconnect, or suspend/resume. This installs a dispatcher hook that
   reinstalls the route on `up`/`down`/`dhcp4-change`/`connectivity-change`.
3. **`rp_filter` drops the replies.** Traffic leaves via one link and returns via
   the other's gateway; strict reverse-path filtering deletes those packets.
   Sets `rp_filter=2` (loose) — strict mode gives confusing partial failures.
4. **A dead nexthop blackholes its share of traffic.** If the secondary link goes
   away, a naive multipath route keeps sending ~40% of new connections into
   nowhere. This rebuilds the route from only the links that are actually up, on
   every interface event.
5. **`src` is not valid inside a nexthop.** `ip route ... nexthop via GW dev X src
   IP weight N` fails to parse on iproute2 7.x (`Error: "nexthop" or end of line
   is expected instead of "src"`). Omitting `src` is correct: the kernel selects
   the right source per nexthop anyway.

## Requirements

- Linux with a modern kernel (`CONFIG_IP_ROUTE_MULTIPATH=y`). Check:
  `ls /proc/sys/net/ipv4/fib_multipath_hash_policy`
- `iproute2` (`ip`), `curl`, `sysctl`
- **Two uplinks with two different gateways.** Two interfaces on the same gateway
  are the same ISP and will gain you nothing — the script detects and warns about
  this rather than silently doing nothing.
- NetworkManager is used for persistence hooks, but the routing itself is plain
  `ip route`, so other network stacks work with the `bond`/`fiber-only` commands
  (only auto-reinstall-on-event is NM-specific).

## Install

```bash
sudo install -m 755 netbond.sh /usr/local/bin/netbond

sudo netbond config      # see detected interfaces before changing anything
sudo netbond bond        # combine both links
sudo netbond status      # confirm both links are carrying traffic
```

Switch it off for latency-sensitive use (competitive games, video calls) or when
you want the metered link free:

```bash
sudo netbond fiber-only  # pin everything to the primary link
sudo netbond bond        # back to both
sudo netbond revert      # full teardown, stock networking restored
```

The mode is remembered in `/etc/netbond.mode`, so a reboot or DHCP renew keeps
whichever mode you chose. Edit `/etc/netbond.conf` to set the link weights.

## Configuration

`sudo netbond bond` writes `/etc/netbond.conf`:

```sh
FIBER_DEV="enp6s0"      # primary uplink
FIBER_GW="192.168.0.1"
FIBER_CON="Wired connection 1"
MOB_DEV="wlan0"         # secondary uplink
MOB_GW="172.20.10.1"
MOB_CON="iPhone"
W_FIBER=3               # weights ~ proportional to measured capacity
W_MOB=2                 # 3:2 => roughly 60/40 split
```

Set the weights from real measurements, not advertised speeds. A 150 Mbit/s
wired link and a nominally 300 Mbit/s mobile link that actually sustains ~90
Mbit/s is much closer to 3:1 than 2:1.

## Limitations

**This does not make a single connection faster.** ECMP hashes *connections* to
links, so one TCP stream always rides one link. You get the sum of both links
only when there are many parallel flows. Whether that helps depends entirely on
your client:

- Steam, torrents, browsers, package managers: **yes** — they open many
  connections.
- A single `curl`/`wget`/`scp` of one file, or one video stream: **no**.

For genuine single-stream bonding you need packet-level multiplexing across
links, which requires a server you control to reassemble the stream — MPTCP via
[OpenMPTCProuter](https://openmptcprouter.com/) is the free/self-hosted route.
Budget a VPS, KVM (not OpenVZ), low latency to it, and a port speed above your
combined throughput.

Other caveats:

- **IPv6 is not balanced.** This configures IPv4 only. IPv6 has its own routing
  table, so IPv6 flows keep using whichever single link their default route
  points at. If a download mysteriously runs at single-link speed, check whether
  it is using IPv6 and consider disabling IPv6 on the secondary link so
  everything rides IPv4 where balancing applies.
- **Per-flow hashing is statistical, not fair.** Weights bias the split; they do
  not guarantee it. Expect the ratio to wobble between runs.
- **Mobile links are bursty.** Identical tests on the same phone hotspot ranged
  from 57 to 243 Mbit/s. Do not expect a stable number.
- **Switching modes resets in-flight connections** that were using the secondary
  link. Pause/resume downloads, or reconnect the game, after switching.
- **The secondary link now carries its weight share of *all* traffic**, not just
  downloads — including background chatter. On a metered/tethered link that is
  real data and battery.

## Prior art

Worth knowing before reaching for this script — several approaches already exist:

| Project | Approach | Difference |
|---|---|---|
| [OpenMPTCProuter](https://openmptcprouter.com/) | MPTCP + VPN to a server you own | Real *single-stream* bonding; needs a VPS and OpenWrt |
| [go-dispatch-proxy](https://github.com/extremecoders-re/go-dispatch-proxy) | SOCKS5/transparent proxy, `SO_BINDTODEVICE` | Application-level, per-connection dispatch; not kernel routing |
| [mgi24/MPTCP-Internet-Combine](https://github.com/mgi24/MPTCP-Internet-Combine) | sing-box + socat + mptcpize | Requires a server; experimental |
| [isticktoit load-balance.sh](https://gir.st/blog/isticktoit/loadbalance.htm) | `ip route` + per-interface routing tables, GPLv2 | Closest prior art; equal weights only, no event persistence, no up/down handling |
| `nexthop` objects (`ip nexthop add id N ... group`) | Kernel nexthop group API | Cleaner API, same ECMP semantics; no mode switching or link-event handling |

The core `ip route add default nexthop ...` technique is long-established and
well documented. What is not commonly covered is the surrounding operational
work — surviving NetworkManager, `rp_filter`, dead-nexthop avoidance, and a
mode switch between bonded and single-link — which is what this script is for.

## Uninstall

```bash
sudo netbond revert
sudo rm /usr/local/bin/netbond
```

## License

MIT — see [LICENSE](LICENSE).
