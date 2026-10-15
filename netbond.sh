#!/usr/bin/env bash
# netbond - combine two internet uplinks on a Linux desktop/workstation into one
# faster path for multi-connection downloads (Steam, torrents, apt, browsers),
# WITHOUT a VPS, tunnel or third-party service.
#
# It uses weighted ECMP (multipath default route) + L4 flow hashing, plus
# NetworkManager dispatcher hooks so the route survives reboots, DHCP renews
# and link up/down events.
#
#   sudo netbond.sh bond         use BOTH links (fast multi-connection downloads)
#   sudo netbond.sh fiber-only   pin to one link only (low latency, metered link off)
#   sudo netbond.sh status       show mode and what each link is carrying
#   sudo netbond.sh config       show config file + detected interfaces
#   sudo netbond.sh revert       full teardown, back to stock networking
#
# Note on names: "fiber"/"mobile" below mean "primary"/"secondary" uplink. They
# are configurable; nothing about the script is specific to those technologies.
#
# WHAT THIS DOES NOT DO: a single TCP stream still rides ONE link. This raises
# *aggregate* throughput for many parallel flows, not the speed of one download.
# For true single-stream bonding (packet-level, one fast socket) you need MPTCP
# with a server you control (e.g. OpenMPTCProuter). See README "Limitations".
set -uo pipefail

CONF=/etc/netbond.conf
MODE_FILE=/etc/netbond.mode
DISPATCH=/etc/NetworkManager/dispatcher.d/90-netbond
SYSCTL_FILE=/etc/sysctl.d/90-netbond.conf
RT_METRIC=0          # beats NM's routes while leaving them as a fallback
HASH_POLICY=1        # 1 = L3+L4 hash. REQUIRED: policy 0 often pins all flows to one link
LOG="logger -t netbond"

FIBER_DEV=""; FIBER_GW=""; FIBER_CON=""
MOB_DEV="";   MOB_GW="";   MOB_CON=""
W_FIBER=3;    W_MOB=2      # rough ratio of the two links' measured capacity
# shellcheck source=/dev/null
if [[ -r $CONF ]]; then . "$CONF"; fi

die(){ echo "ERROR: $*" >&2; exit 1; }
need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "run as root:  sudo $0 ${1:-}"; }

# --- discovery --------------------------------------------------------------
# Active default routes, lowest metric first: "dev gw metric"
default_routes(){
  ip -4 route show default 2>/dev/null | awk '
    { gw=""; dev=""; met=0
      for (i=1;i<=NF;i++){
        if ($i=="via") gw=$(i+1);
        else if ($i=="dev") dev=$(i+1);
        else if ($i=="metric") met=$(i+1)
      }
      if (gw!="" && dev!="") print dev, gw, met }' | sort -k3 -n
}

# Which NetworkManager connection profile owns this device (busybox-safe)
nm_con_for(){ nmcli -t -f NAME,DEVICE con show --active 2>/dev/null | awk -F: -v d="$1" '$2==d{print $1; exit}'; }

detect(){
  local rows; rows=$(default_routes)
  [[ -n $rows ]] || die "no IPv4 default route found - is something connected?"
  FIBER_DEV=$(awk 'NR==1{print $1}' <<<"$rows")
  FIBER_GW=$(awk  'NR==1{print $2}' <<<"$rows")
  # secondary = the first route to a DIFFERENT gateway (same gateway == same ISP == no gain)
  MOB_DEV=$(awk -v fg="$FIBER_GW" 'NR>1 && $2!=fg {print $1; exit}' <<<"$rows")
  MOB_GW=$( awk -v fg="$FIBER_GW" 'NR>1 && $2!=fg {print $2; exit}' <<<"$rows")
  if [[ -z $MOB_DEV ]]; then
    cat >&2 <<EOW
WARNING: only one distinct gateway found.
  routes:
${rows//$'\n'/$'\n'    }
  Multiple interfaces pointing at the SAME gateway are the same ISP/network.
  Balancing them adds no bandwidth (the bottleneck is upstream, not the NIC).
  netbond is only useful with two genuinely separate uplinks.
EOW
  fi
  FIBER_CON=$(nm_con_for "$FIBER_DEV"); MOB_CON=$(nm_con_for "$MOB_DEV")
}

write_conf(){
  cat > "$CONF" <<EOC
# netbond configuration - edit then re-run: sudo netbond.sh bond
# "fiber" = primary uplink, "mobile" = secondary uplink.
FIBER_DEV="$FIBER_DEV"
FIBER_GW="$FIBER_GW"
FIBER_CON="$FIBER_CON"
MOB_DEV="$MOB_DEV"
MOB_GW="$MOB_GW"
MOB_CON="$MOB_CON"
# Weights ~ proportional to each link's real capacity. W_FIBER=3 W_MOB=2 => ~60/40.
W_FIBER=$W_FIBER
W_MOB=$W_MOB
EOC
  chmod 644 "$CONF"
}

# --- route plumbing ---------------------------------------------------------
link_up(){ ip link show "$1" 2>/dev/null | grep -q "state UP"; }
has_ip(){  ip -4 addr show "$1" 2>/dev/null | grep -q "inet "; }

install_route(){
  local f=0 m=0
  link_up "$FIBER_DEV" && has_ip "$FIBER_DEV" && f=1
  [[ -n $MOB_DEV ]] && link_up "$MOB_DEV" && has_ip "$MOB_DEV" && m=1
  if   (( f && m )); then
    ip route replace default metric $RT_METRIC \
      nexthop via "$FIBER_GW" dev "$FIBER_DEV" weight "$W_FIBER" \
      nexthop via "$MOB_GW"   dev "$MOB_DEV"   weight "$W_MOB"
  elif (( f )); then                       # secondary gone: never leave a dead nexthop
    ip route replace default via "$FIBER_GW" dev "$FIBER_DEV" metric $RT_METRIC
    $LOG "secondary down - primary only"
  elif (( m )); then
    ip route replace default via "$MOB_GW" dev "$MOB_DEV" metric $RT_METRIC
    $LOG "primary down - secondary only"
  else
    ip route del default metric $RT_METRIC 2>/dev/null
    $LOG "no usable uplink"
  fi
}
del_route(){ ip route del default metric $RT_METRIC 2>/dev/null; }

assert_sysctls(){
  sysctl -qw net.ipv4.conf.all.rp_filter=2
  sysctl -qw net.ipv4.conf."$FIBER_DEV".rp_filter=2
  sysctl -qw net.ipv4.conf.all.fib_multipath_hash_policy=$HASH_POLICY 2>/dev/null
  sysctl -qw net.ipv4.fib_multipath_hash_policy=$HASH_POLICY
  [[ -n $MOB_DEV ]] && sysctl -qw net.ipv4.conf."$MOB_DEV".rp_filter=2
}

write_dispatcher(){
  mkdir -p "$(dirname "$DISPATCH")"
  cat > "$DISPATCH" <<EOF
#!/bin/sh
# netbond: keep the metric-$RT_METRIC default route correct across link events.
# Mode-aware: "fiber" mode deliberately installs NO metric-$RT_METRIC route,
# so this script must stay a no-op then.
PATH=/usr/bin:/usr/sbin:/bin:/sbin
IFACE="\$1"; ACTION="\$2"
[ -n "\$IFACE" ] || exit 0
[ -r $CONF ] || exit 0
. $CONF
case "\$IFACE" in "\$FIBER_DEV"|"\$MOB_DEV") ;; *) exit 0 ;; esac
case "\$ACTION" in
  up|down|dhcp4-change|dhcp6-change|connectivity-change|pre-up) ;;
  *) exit 0 ;;
esac
[ -r $MODE_FILE ] || exit 0
[ "\$(cat $MODE_FILE 2>/dev/null)" = "bond" ] || exit 0

sleep 1
for i in \$(seq 1 20); do
  ip link show "\$FIBER_DEV" 2>/dev/null | grep -q "state UP" && break
  sleep 1
done

/usr/sbin/sysctl -qw net.ipv4.conf.all.rp_filter=2 2>/dev/null
/usr/sbin/sysctl -qw net.ipv4.conf.\$FIBER_DEV.rp_filter=2 2>/dev/null
/usr/sbin/sysctl -qw net.ipv4.conf.\$MOB_DEV.rp_filter=2 2>/dev/null
/usr/sbin/sysctl -qw net.ipv4.fib_multipath_hash_policy=$HASH_POLICY 2>/dev/null

f=0; m=0
ip link show "\$FIBER_DEV" 2>/dev/null | grep -q "state UP" && f=1
[ -n "\$MOB_DEV" ] && ip link show "\$MOB_DEV" 2>/dev/null | grep -q "state UP" && m=1
if [ \$f -eq 1 ] && [ \$m -eq 1 ]; then
  ip route replace default metric $RT_METRIC \\
    nexthop via \$FIBER_GW dev \$FIBER_DEV weight \$W_FIBER \\
    nexthop via \$MOB_GW dev \$MOB_DEV weight \$W_MOB
  logger -t netbond "bond route reinstalled (both links up)"
elif [ \$f -eq 1 ]; then
  ip route replace default via \$FIBER_GW dev \$FIBER_DEV metric $RT_METRIC
  logger -t netbond "secondary down - primary only"
elif [ \$m -eq 1 ]; then
  ip route replace default via \$MOB_GW dev \$MOB_DEV metric $RT_METRIC
  logger -t netbond "primary down - secondary only"
else
  ip route del default metric $RT_METRIC 2>/dev/null
fi
EOF
  chmod 755 "$DISPATCH"; chown root:root "$DISPATCH" 2>/dev/null || true
}

# --- commands ---------------------------------------------------------------
bond(){
  need_root bond
  detect
  [[ -n $MOB_DEV ]] || die "need TWO distinct gateways to bond - nothing to do"
  for d in "$FIBER_DEV" "$MOB_DEV"; do
    [[ -e /sys/class/net/$d ]] || die "interface $d missing"
  done
  echo "[1/5] rp_filter=2 (loose) + L4 multipath hashing"
  assert_sysctls
  cat > "$SYSCTL_FILE" <<EOC
# netbond: multipath load balancing across two uplinks.
# Managed by netbond.sh - removed again by 'netbond.sh revert'.
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.$FIBER_DEV.rp_filter = 2
net.ipv4.conf.$MOB_DEV.rp_filter = 2
net.ipv4.fib_multipath_hash_policy = $HASH_POLICY
EOC
  echo "[2/5] writing config ($CONF) and mode=bond ($MODE_FILE)"
  write_conf; echo bond > "$MODE_FILE"
  echo "[3/5] NetworkManager keeps its own routes as fallback"
  for c in "${FIBER_CON:-}" "${MOB_CON:-}"; do
    if [[ -n $c ]]; then nmcli con mod "$c" ipv4.never-default no >/dev/null 2>&1 || true; fi
  done
  echo "[4/5] installing dispatcher hook + combined route"
  write_dispatcher
  install_route || die "route install failed - nothing changed"
  echo "[5/5] verifying"; echo; verify
  echo
  echo "NOTE: connections already open keep their old route. Pause/resume a Steam"
  echo "      download so it re-opens flows across both links."
}

fiber_only(){
  need_root fiber-only
  # shellcheck source=/dev/null
  [[ -r $CONF ]] || detect
  echo "[1/4] mode=fiber (no metric-$RT_METRIC route, so the NM route takes over)"
  echo fiber > "$MODE_FILE"
  del_route
  echo "[2/4] rewriting dispatcher hook so it respects fiber mode"
  write_dispatcher
  echo "[3/4] confirming a NetworkManager event cannot re-enable bonding"
  [[ -n $FIBER_CON ]] && { nmcli con up "$FIBER_CON" >/dev/null 2>&1 || true; }
  echo "[4/4] verifying"; sleep 2; echo; verify
  echo
  echo "Single-link mode. Flows that were on the other link were reset (by design)."
  echo "Back to both links:  sudo $0 bond"
}

revert(){
  need_root revert
  # Read the config BEFORE deleting it, otherwise the per-device sysctl reset
  # below silently does nothing.
  # shellcheck source=/dev/null
  [[ -r $CONF ]] && . "$CONF"
  local fdev="$FIBER_DEV" mdev="$MOB_DEV" fcon="${FIBER_CON:-}" mcon="${MOB_CON:-}"

  echo "[1/5] removing dispatcher hook";   rm -f "$DISPATCH"
  echo "[2/5] removing mode + config";     rm -f "$MODE_FILE" "$CONF"
  echo "[3/5] removing persisted sysctls"; rm -f "$SYSCTL_FILE"
  echo "[4/5] dropping metric-$RT_METRIC route, restoring stock routes"
  del_route
  sysctl -qw net.ipv4.conf.all.rp_filter=1
  sysctl -qw net.ipv4.fib_multipath_hash_policy=0
  for d in "$fdev" "$mdev"; do
    if [[ -n $d ]]; then sysctl -qw net.ipv4.conf."$d".rp_filter=1 2>/dev/null || true; fi
  done
  if [[ -n $fcon ]]; then nmcli con mod "$fcon" ipv4.never-default no >/dev/null 2>&1 || true; fi
  if [[ -n $mcon ]]; then nmcli con mod "$mcon" ipv4.never-default no >/dev/null 2>&1 || true; fi
  if [[ -n $fcon ]]; then nmcli con up "$fcon" >/dev/null 2>&1 || true; fi
  if [[ -n $mcon ]]; then nmcli con up "$mcon" >/dev/null 2>&1 || true; fi
  echo "[5/5] done. Final routes:"; ip route show default | sed 's/^/  /'
}

egress_ip(){ curl -4 -s --max-time 8 --interface "$1" https://api.ipify.org 2>/dev/null; }

verify(){
  [[ -n ${FIBER_DEV:-} ]] || { echo "  no uplink detected"; return 1; }
  local mode="(none)"; [[ -r $MODE_FILE ]] && mode=$(cat "$MODE_FILE")
  echo "  mode              : $mode"
  echo "  primary ($FIBER_DEV) egress : $(egress_ip "$FIBER_DEV" || echo '(none)')"
  [[ -n $MOB_DEV ]] && echo "  secondary ($MOB_DEV) egress : $(egress_ip "$MOB_DEV" || echo '(none)')"
  echo "  metric-$RT_METRIC route:"
  ip route show default metric $RT_METRIC 2>/dev/null | sed 's/^/     /' | grep . || echo "     (none)"
  echo "  hash_policy       : $(sysctl -n net.ipv4.fib_multipath_hash_policy 2>/dev/null)"
  echo "  rp_filter         : $(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null)"
  if [[ -n $MOB_DEV ]]; then
    local fip mip f=0 m=0 o=0 r
    fip=$(egress_ip "$FIBER_DEV"); mip=$(egress_ip "$MOB_DEV")
    for _ in 1 2 3 4 5 6 7 8; do
      r=$(curl -4 -s --max-time 6 https://api.ipify.org 2>/dev/null)
      if   [[ -n $fip && $r == "$fip" ]]; then f=$((f+1))
      elif [[ -n $mip && $r == "$mip" ]]; then m=$((m+1))
      else o=$((o+1)); fi
    done
    echo "  new-flow spread (8 probes): primary=$f secondary=$m other/failed=$o"
  fi
  echo "  live 6s throughput:"
  local a b
  a=$(cat /sys/class/net/"$FIBER_DEV"/statistics/rx_bytes 2>/dev/null || echo 0)
  b=$(cat /sys/class/net/"${MOB_DEV:-$FIBER_DEV}"/statistics/rx_bytes 2>/dev/null || echo 0)
  sleep 6
  echo "     $FIBER_DEV : $(( ($(cat /sys/class/net/"$FIBER_DEV"/statistics/rx_bytes)-a)*8/6/1000000 )) Mbit/s"
  [[ -n $MOB_DEV ]] && echo "     $MOB_DEV : $(( ($(cat /sys/class/net/"$MOB_DEV"/statistics/rx_bytes)-b)*8/6/1000000 )) Mbit/s"
}

case "${1:-status}" in
  bond|apply)          bond ;;
  fiber-only|single|off) fiber_only ;;
  revert|teardown)     revert ;;
  status)              echo "=== netbond status ==="; # shellcheck source=/dev/null
                 . "$CONF" 2>/dev/null || detect; verify ;;
  config)              echo "=== $CONF ==="; [[ -r $CONF ]] && cat "$CONF" || echo "(not written yet - run 'bond' once)"
                       echo "=== routes seen ==="; default_routes | sed 's/^/  dev gw metric: /' ;;
  *) cat <<USAGE
netbond - combine two uplinks on Linux for faster multi-connection downloads

  sudo $0 bond         use BOTH links
  sudo $0 fiber-only   pin to one link (low latency / metered link off)
  sudo $0 status       show mode and what each link is carrying
  sudo $0 config       show the config file and detected interfaces
  sudo $0 revert       full teardown, back to stock networking
USAGE
     exit 1 ;;
esac
