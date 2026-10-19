#!/usr/bin/env bash
# dhcp-lab.sh - DHCP server, clients, pool exhaustion and a rogue server
#
#              r1 (br0 192.168.10.1/24, dnsmasq DHCP server)
#            /   |    \      \
#         pc1   pc2   pc3    evil (rogue DHCP server, started by 'rogue')
#
#  Pool: 192.168.10.100 - 192.168.10.101 (only 2 addresses on purpose)
#
# Usage (as root):
#   ./dhcp-lab.sh up            build topology, start the DHCP server on r1
#   ./dhcp-lab.sh lease <pc>    get an address with dhclient, show DORA in tcpdump
#   ./dhcp-lab.sh release <pc>  give the address back (DHCPRELEASE)
#   ./dhcp-lab.sh status        addresses of the PCs and leases on the server
#   ./dhcp-lab.sh rogue         start a rogue DHCP server (fake gateway .66)
#   ./dhcp-lab.sh down          remove everything
#
# Needs: apt install -y dnsmasq-base isc-dhcp-client tcpdump
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Run as root (sudo ./dhcp-lab.sh ...)"; exit 1; }
for b in dnsmasq dhclient tcpdump; do
  command -v "$b" >/dev/null || { echo "Missing $b: apt install -y dnsmasq-base isc-dhcp-client tcpdump"; exit 1; }
done

PCS=(pc1 pc2 pc3)
RUN=/run/netlab-dhcp
# dhclient files live where Debian's AppArmor profile for dhclient allows them
DHC_CONF=/etc/dhcp/netlab-dhclient.conf
dhc() {  # dhc <pc> <dhclient args...>: dhclient with per-PC lease and pid files
  local pc=$1; shift
  ip netns exec "$pc" dhclient -cf "$DHC_CONF" -lf "/var/lib/dhcp/netlab-$pc.leases" \
    -pf "/run/dhclient-netlab-$pc.pid" "$@" eth0
}

up() {
  mkdir -p "$RUN"
  ip netns add r1
  ip -n r1 link add br0 type bridge
  ip -n r1 addr add 192.168.10.1/24 dev br0
  ip -n r1 link set br0 up
  ip -n r1 link set lo up

  local pc
  for pc in "${PCS[@]}" evil; do
    ip netns add "$pc"
    # ip netns exec bind-mounts /etc/netns/<ns>/resolv.conf over /etc/resolv.conf,
    # so dhclient cannot overwrite the laptop's real DNS settings
    mkdir -p "/etc/netns/$pc" && : > "/etc/netns/$pc/resolv.conf"
    ip -n "$pc" link add eth0 type veth peer name "$pc" netns r1
    ip -n r1 link set "$pc" master br0
    ip -n r1 link set "$pc" up
    ip -n "$pc" link set eth0 up
    ip -n "$pc" link set lo up
  done

  start_server 0
  mkdir -p /var/lib/dhcp
  printf 'timeout 8;\nretry 60;\n' > "$DHC_CONF"
  echo "Topology up. DHCP server on r1, pool 192.168.10.100-101. PCs have no IP yet."
}

start_server() {  # start_server <reply delay in seconds>
  [[ -f $RUN/r1.pid ]] && { kill "$(cat "$RUN/r1.pid")" 2>/dev/null || true; sleep 0.5; }
  ip netns exec r1 dnsmasq --conf-file=/dev/null --user=root --port=0 \
    --interface=br0 --bind-interfaces --dhcp-authoritative \
    --dhcp-range=192.168.10.100,192.168.10.101,255.255.255.0,10m \
    --dhcp-option=option:router,192.168.10.1 \
    --dhcp-option=option:dns-server,192.168.10.1 \
    --dhcp-reply-delay="$1" \
    --dhcp-leasefile="$RUN/r1.leases" --pid-file="$RUN/r1.pid" \
    --log-dhcp --log-facility="$RUN/r1.log"
}

lease() {  # lease <pc>
  local pc=${1:?usage: lease pc1|pc2|pc3}
  ip -n "$pc" addr flush dev eth0
  ip netns exec r1 tcpdump -Uni br0 -w "$RUN/dhcp.pcap" 'udp port 67 or udp port 68' 2>/dev/null &
  local tpid=$!
  sleep 1
  echo "dhclient on $pc:"
  dhc "$pc" -1 -v 2>&1 | grep -E 'DHCP|bound|No DHCPOFFERS' | sed 's/^/  /' || true
  sleep 1; kill "$tpid" 2>/dev/null || true; wait "$tpid" 2>/dev/null || true
  echo "tcpdump on r1 (what crossed the wire):"
  tcpdump -nv -r "$RUN/dhcp.pcap" 2>/dev/null \
    | awk '/ > .*BOOTP/ {split($0,a,":"); hdr=a[1]; gsub(/^ +/,"",hdr)}
           /Your-IP/ {yip=$2}
           /DHCP-Message/ {printf "  %-9s %-36s %s\n", $NF, hdr, (yip ? "your-ip " yip : ""); yip=""}'
  echo "Result: $(ip -n "$pc" -4 -o addr show dev eth0 | awk '{print $4}') gateway: $(ip -n "$pc" route show default | awk '{print $3}')"
}

release() {
  local pc=${1:?usage: release pc1|pc2|pc3}
  dhc "$pc" -r 2>/dev/null || true
  echo "$pc released its address."
}

status() {
  local pc
  for pc in "${PCS[@]}"; do
    printf '  %-4s %-18s gw %s\n' "$pc" \
      "$(ip -n "$pc" -4 -o addr show dev eth0 | awk '{print $4}')" \
      "$(ip -n "$pc" route show default | awk '{print $3}')"
  done
  echo "Leases on r1 (expiry MAC IP):"
  awk '{print "  " strftime("%H:%M:%S", $1), $2, $3}' "$RUN/r1.leases" 2>/dev/null || true
}

rogue() {
  # Legit server now answers after 2 s (busy server / remote via DHCP relay).
  # The rogue answers at once - first offer wins.
  start_server 2
  ip -n evil addr add 192.168.10.66/24 dev eth0
  ip netns exec evil dnsmasq --conf-file=/dev/null --user=root --port=0 \
    --interface=eth0 --bind-interfaces --dhcp-authoritative \
    --dhcp-range=192.168.10.200,192.168.10.210,255.255.255.0,10m \
    --dhcp-option=option:router,192.168.10.66 \
    --dhcp-option=option:dns-server,192.168.10.66 \
    --dhcp-leasefile="$RUN/evil.leases" --pid-file="$RUN/evil.pid"
  echo "Rogue DHCP server running on 'evil' (gateway 192.168.10.66)."
}

down() {
  local f ns
  for f in "$RUN"/*.pid /run/dhclient-netlab-*.pid; do [[ -f $f ]] && kill "$(cat "$f")" 2>/dev/null || true; done
  for ns in r1 "${PCS[@]}" evil; do
    ip netns del "$ns" 2>/dev/null || true
    rm -rf "/etc/netns/$ns"
  done
  rm -rf "$RUN" "$DHC_CONF" /var/lib/dhcp/netlab-*.leases /run/dhclient-netlab-*.pid
  echo "Lab removed."
}

case "${1:-}" in
  up) up ;; lease) lease "${2:-}" ;; release) release "${2:-}" ;;
  status) status ;; rogue) rogue ;; down) down ;;
  *) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
