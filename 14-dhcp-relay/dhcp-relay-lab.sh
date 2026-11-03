#!/usr/bin/env bash
# dhcp-relay-lab.sh - DHCP relay (Cisco: ip helper-address) between two subnets
#
# Topology:
#
#   pc1 (DHCP client) ------------ r1 (relay) ------------ srv (dnsmasq server)
#              10.0.10.0/24                  10.0.20.0/24
#   pc1: no address   r1: 10.0.10.1 | 10.0.20.1        srv: 10.0.20.2
#
# Usage: sudo ./dhcp-relay-lab.sh COMMAND
#   up       build namespaces, start the DHCP server on srv (no relay, no return route)
#   relay    start the DHCP relay on r1 (giaddr 10.0.10.1 -> server 10.0.20.2)
#   route    add the return route on srv: 10.0.10.0/24 via 10.0.20.1
#   test     ask for a lease once from pc1 and report the result
#   capture  same as test, with tcpdump (DHCP + ARP) on all r1 interfaces
#   status   addresses, routes, ARP on r1, server leases
#   down     stop all processes and delete the namespaces
#
# Suggested order: up, test, relay, test, capture, route, capture, down

set -euo pipefail

SRV_PID=/tmp/lab14-srv.pid
SRV_LOG=/tmp/lab14-srv.log
SRV_LEASES=/tmp/lab14-srv.leases
RELAY_PID=/tmp/lab14-relay.pid
RELAY_LOG=/tmp/lab14-relay.log
# AppArmor lets dhclient write only /var/lib/dhcp/dhclient* lease files
CLI_LEASES=/var/lib/dhcp/dhclient-lab14.leases
CLI_PID=/run/dhclient-lab14.pid

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

[[ $EUID -eq 0 ]] || { echo "Run as root (sudo)." >&2; exit 1; }

missing=()
for bin in ip dnsmasq dhclient tcpdump; do
  command -v "$bin" >/dev/null || missing+=("$bin")
done
if (( ${#missing[@]} )); then
  echo "Missing: ${missing[*]}" >&2
  echo "Install: apt install iproute2 dnsmasq-base isc-dhcp-client tcpdump" >&2
  exit 1
fi

kill_pidfile() {
  if [[ -f $1 ]]; then
    kill "$(cat "$1")" 2>/dev/null || true
    rm -f "$1"
  fi
}

up() {
  if ip netns list | grep -qw pc1; then
    echo "Lab already up. Run: $0 down" >&2; exit 1
  fi
  ip netns add pc1; ip netns add r1; ip netns add srv
  # veth ends are named after the neighbour
  ip link add r1 netns pc1 type veth peer name pc1 netns r1
  ip link add srv netns r1 type veth peer name r1 netns srv

  ip -n r1 addr add 10.0.10.1/24 dev pc1
  ip -n r1 addr add 10.0.20.1/24 dev srv
  ip -n srv addr add 10.0.20.2/24 dev r1

  ip -n pc1 link set lo up; ip -n pc1 link set r1 up
  ip -n r1 link set lo up;  ip -n r1 link set pc1 up; ip -n r1 link set srv up
  ip -n srv link set lo up; ip -n srv link set r1 up

  ip netns exec r1 sysctl -qw net.ipv4.ip_forward=1
  ip netns exec r1 sysctl -qw net.ipv4.icmp_ratelimit=0

  # keep dhclient-script from overwriting the host's /etc/resolv.conf
  mkdir -p /etc/netns/pc1 && touch /etc/netns/pc1/resolv.conf

  # DHCP server for a subnet it is NOT connected to; it serves relayed requests by giaddr
  ip netns exec srv dnsmasq --port=0 \
    --dhcp-range=10.0.10.100,10.0.10.150,255.255.255.0,1h \
    --dhcp-option=3,10.0.10.1 \
    --dhcp-leasefile="$SRV_LEASES" --pid-file="$SRV_PID" \
    --log-dhcp --log-facility="$SRV_LOG"

  echo "Up. srv has no route to 10.0.10.0/24 and r1 runs no relay yet."
  echo "Next: $0 test"
}

relay() {
  [[ -f $RELAY_PID ]] && { echo "Relay already running."; return; }
  ip netns exec r1 dnsmasq --port=0 \
    --dhcp-relay=10.0.10.1,10.0.20.2 \
    --pid-file="$RELAY_PID" --log-dhcp --log-facility="$RELAY_LOG"
  echo "Relay on r1: 10.0.10.1 -> 10.0.20.2"
}

route() {
  ip -n srv route replace 10.0.10.0/24 via 10.0.20.1
  echo "srv: 10.0.10.0/24 via 10.0.20.1"
}

test_lease() {
  kill_pidfile "$CLI_PID"
  rm -f "$CLI_LEASES"
  ip -n pc1 addr flush dev r1 scope global
  ip netns exec pc1 timeout 15 dhclient -v -1 -pf "$CLI_PID" -lf "$CLI_LEASES" r1 || true

  echo
  local discovers=0
  [[ -f $SRV_LOG ]] && discovers=$(grep -c DHCPDISCOVER "$SRV_LOG" || true)
  if ip -n pc1 -4 addr show dev r1 | grep -q 'inet 10\.0\.10\.'; then
    echo "PASS: pc1 got $(ip -n pc1 -4 -o addr show dev r1 | awk '{print $4}')"
    ip -n pc1 route
  else
    echo "NO LEASE for pc1"
  fi
  echo "DHCPDISCOVER lines in server log so far: $discovers"
  echo "r1 ARP for the server: $(ip -n r1 neigh show 10.0.20.2 | head -1)"
}

capture() {
  ip netns exec r1 timeout 20 tcpdump -ni any -c 12 'udp port 67 or udp port 68 or arp' &
  local tpid=$!
  sleep 1
  test_lease
  wait "$tpid" || true
}

status() {
  for ns in pc1 r1 srv; do
    echo "== $ns"; ip -br -n "$ns" addr; ip -n "$ns" route
  done
  echo "== r1 ARP"; ip -n r1 neigh
  echo "== server leases"; cat "$SRV_LEASES" 2>/dev/null || echo "(none)"
}

down() {
  kill_pidfile "$CLI_PID"
  kill_pidfile "$RELAY_PID"
  kill_pidfile "$SRV_PID"
  for ns in pc1 r1 srv; do ip netns del "$ns" 2>/dev/null || true; done
  rm -rf /etc/netns/pc1
  rm -f "$SRV_LOG" "$SRV_LEASES" "$RELAY_LOG" "$CLI_LEASES"
  echo "Down."
}

case "${1:-}" in
  up) up ;;
  relay) relay ;;
  route) route ;;
  test) test_lease ;;
  capture) capture ;;
  status) status ;;
  down) down ;;
  *) usage ;;
esac
