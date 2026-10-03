#!/usr/bin/env bash
# routing-lab.sh - static routing across three routers (network namespaces)
#
#  pc1 ------ r1 ------------ r2 ------------ r3 ------ pc3
#     10.0.1.0/24  10.0.12.0/30   10.0.23.0/30  10.0.3.0/24
#  .10      .1  .1          .2  .1          .2  .1      .10
#
# Usage (as root):
#   ./routing-lab.sh up       build topology (connected routes only)
#   ./routing-lab.sh test     ping tests: ok / timeout / unreachable (+ TTL)
#   ./routing-lab.sh return   add only r2's return route to 10.0.1.0/24
#   ./routing-lab.sh routes   add all static routes needed for pc1 <-> pc3
#   ./routing-lab.sh tables   show routing tables of r1, r2, r3
#   ./routing-lab.sh down     remove everything
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Run as root (sudo -i)"; exit 1; }

NODES=(pc1 r1 r2 r3 pc3)

up() {
  for n in "${NODES[@]}"; do ip netns add "$n"; done

  # cables
  ip -n pc1 link add eth0  type veth peer name lan   netns r1
  ip -n r1  link add to-r2 type veth peer name to-r1 netns r2
  ip -n r2  link add to-r3 type veth peer name to-r2 netns r3
  ip -n r3  link add lan   type veth peer name eth0  netns pc3

  # addressing (/30 on router-to-router links: exactly 2 usable hosts)
  ip -n pc1 addr add 10.0.1.10/24 dev eth0
  ip -n r1  addr add 10.0.1.1/24  dev lan
  ip -n r1  addr add 10.0.12.1/30 dev to-r2
  ip -n r2  addr add 10.0.12.2/30 dev to-r1
  ip -n r2  addr add 10.0.23.1/30 dev to-r3
  ip -n r3  addr add 10.0.23.2/30 dev to-r2
  ip -n r3  addr add 10.0.3.1/24  dev lan
  ip -n pc3 addr add 10.0.3.10/24 dev eth0

  local n i
  for n in "${NODES[@]}"; do
    for i in $(ip -n "$n" -o link show | awk -F': ' '{print $2}' | cut -d@ -f1); do
      ip -n "$n" link set "$i" up
    done
  done
  for n in r1 r2 r3; do
    ip netns exec "$n" sysctl -qw net.ipv4.ip_forward=1
    # no ICMP error rate limiting, so "unreachable" replies show up on every test
    ip netns exec "$n" sysctl -qw net.ipv4.icmp_ratelimit=0
  done
  ip -n pc1 route add default via 10.0.1.1
  ip -n pc3 route add default via 10.0.3.1
  echo "Topology up. Routers know only their connected networks."
}

probe() {  # probe <ns> <ip> <label>
  local out ttl from
  if out=$(ip netns exec "$1" ping -c1 -W1 "$2" 2>&1); then
    ttl=$(grep -o 'ttl=[0-9]*' <<<"$out" | head -1)
    printf '  %-28s OK (%s)\n' "$3" "$ttl"
  elif from=$(grep -o 'From [0-9.]* .*Unreachable' <<<"$out" | head -1); [[ -n $from ]]; then
    printf '  %-28s UNREACHABLE: %s\n' "$3" "$from"
  else
    printf '  %-28s TIMEOUT (no reply - missing return route?)\n' "$3"
  fi
}

test_lab() {
  echo "Ping tests from pc1:"
  probe pc1 10.0.1.1  "pc1 -> r1 (10.0.1.1)"
  probe pc1 10.0.12.2 "pc1 -> r2 (10.0.12.2)"
  probe pc1 10.0.23.2 "pc1 -> r3 (10.0.23.2)"
  probe pc1 10.0.3.10 "pc1 -> pc3 (10.0.3.10)"
}

return_route() {
  # "To reach pc1's network, hand the packet to r1"
  ip -n r2 route replace 10.0.1.0/24 via 10.0.12.1
  echo "Added on r2: 10.0.1.0/24 via 10.0.12.1"
}

routes() {
  # Every router needs a path to the destination AND back to the source.
  ip -n r1 route replace 10.0.3.0/24  via 10.0.12.2
  ip -n r1 route replace 10.0.23.0/30 via 10.0.12.2
  ip -n r2 route replace 10.0.1.0/24  via 10.0.12.1
  ip -n r2 route replace 10.0.3.0/24  via 10.0.23.2
  ip -n r3 route replace 10.0.1.0/24  via 10.0.23.1
  ip -n r3 route replace 10.0.12.0/30 via 10.0.23.1
  echo "Static routes added on r1, r2, r3."
}

tables() {
  local r
  for r in r1 r2 r3; do echo "--- $r"; ip -n "$r" route; done
}

down() {
  local n
  for n in "${NODES[@]}"; do ip netns del "$n" 2>/dev/null || true; done
  echo "Lab removed."
}

case "${1:-}" in
  up) up ;; test) test_lab ;; return) return_route ;; routes) routes ;;
  tables) tables ;; down) down ;;
  *) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
