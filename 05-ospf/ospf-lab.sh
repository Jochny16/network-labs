#!/usr/bin/env bash
# ospf-lab.sh - OSPF with FRRouting on three Linux routers (network namespaces)
#
#                 r2
#     10.0.12.0/30   10.0.23.0/30
#           /            \
#  pc1 --- r1 ------------ r3 --- pc3
#  10.0.1.0/24  10.0.13.0/30  10.0.3.0/24
#
# Usage (as root):
#   ./ospf-lab.sh up       build topology + start FRR (zebra, ospfd) on r1-r3
#   ./ospf-lab.sh test     pings pc1 -> pc3 with TTL (shows the path length)
#   ./ospf-lab.sh ospf     configure OSPF area 0 on all routers (auto)
#   ./ospf-lab.sh status   OSPF neighbours and routing table of each router
#   ./ospf-lab.sh fail     cut the direct r1-r3 link and watch reconvergence
#   ./ospf-lab.sh restore  bring r1-r3 back
#   ./ospf-lab.sh down     stop FRR and remove everything
#
# Configure a router by hand (Cisco-like CLI):  vtysh -N r1
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Run as root (sudo -i)"; exit 1; }
FRR=/usr/lib/frr
[[ -x $FRR/ospfd ]] || { echo "Install FRRouting first: apt install -y frr"; exit 1; }

NODES=(pc1 r1 r2 r3 pc3)
ROUTERS=(r1 r2 r3)

link() {  # link <ns1> <if1> <ns2> <if2>
  ip -n "$1" link add "$2" type veth peer name "$4" netns "$3"
}

up() {
  local n i r
  for n in "${NODES[@]}"; do ip netns add "$n"; ip -n "$n" link set lo up; done

  link pc1 eth0   r1 lan
  link r1  to-r2  r2 to-r1
  link r2  to-r3  r3 to-r2
  link r1  to-r3  r3 to-r1
  link r3  lan    pc3 eth0

  ip -n pc1 addr add 10.0.1.10/24 dev eth0
  ip -n r1  addr add 10.0.1.1/24  dev lan
  ip -n r1  addr add 10.0.12.1/30 dev to-r2
  ip -n r1  addr add 10.0.13.1/30 dev to-r3
  ip -n r2  addr add 10.0.12.2/30 dev to-r1
  ip -n r2  addr add 10.0.23.1/30 dev to-r3
  ip -n r3  addr add 10.0.23.2/30 dev to-r2
  ip -n r3  addr add 10.0.13.2/30 dev to-r1
  ip -n r3  addr add 10.0.3.1/24  dev lan
  ip -n pc3 addr add 10.0.3.10/24 dev eth0

  for n in "${NODES[@]}"; do
    for i in $(ip -n "$n" -o link show | awk -F': ' '{print $2}' | cut -d@ -f1); do
      ip -n "$n" link set "$i" up
    done
  done
  ip -n pc1 route add default via 10.0.1.1
  ip -n pc3 route add default via 10.0.3.1

  # One FRR instance per router namespace (-N = separate config/run dirs)
  for r in "${ROUTERS[@]}"; do
    ip netns exec "$r" sysctl -qw net.ipv4.ip_forward=1
    ip netns exec "$r" sysctl -qw net.ipv4.icmp_ratelimit=0
    install -d -o frr -g frr "/etc/frr/$r" "/var/run/frr/$r"
    touch "/etc/frr/$r/vtysh.conf"
    ip netns exec "$r" "$FRR/zebra" -d -N "$r" -u frr -g frr >/dev/null 2>&1
    ip netns exec "$r" "$FRR/ospfd" -d -N "$r" -u frr -g frr >/dev/null 2>&1
    vtysh -N "$r" -c 'conf t' -c "hostname $r" >/dev/null
  done
  echo "Topology up, FRR running on r1 r2 r3. No routing protocol configured yet."
}

p2p() {  # p2p <router> <iface...>: point-to-point links, fast timers for the demo
  local r=$1 i; shift
  for i in "$@"; do
    vtysh -N "$r" -c 'conf t' -c "interface $i" -c 'ip ospf network point-to-point' \
      -c 'ip ospf hello-interval 1' -c 'ip ospf dead-interval 4' >/dev/null
  done
}

ospf() {
  # Router links are point-to-point: no DR/BDR election, adjacency in seconds.
  # Hello 1 s / dead 4 s (defaults 10/40) so failover is visible quickly.
  p2p r1 to-r2 to-r3
  p2p r2 to-r1 to-r3
  p2p r3 to-r1 to-r2
  # network statements put interfaces into area 0; LANs are passive (no Hellos to PCs)
  vtysh -N r1 -c 'conf t' -c 'router ospf' -c 'ospf router-id 1.1.1.1' \
    -c 'network 10.0.1.0/24 area 0' -c 'network 10.0.12.0/30 area 0' -c 'network 10.0.13.0/30 area 0' \
    -c 'passive-interface lan' >/dev/null
  vtysh -N r2 -c 'conf t' -c 'router ospf' -c 'ospf router-id 2.2.2.2' \
    -c 'network 10.0.12.0/30 area 0' -c 'network 10.0.23.0/30 area 0' >/dev/null
  vtysh -N r3 -c 'conf t' -c 'router ospf' -c 'ospf router-id 3.3.3.3' \
    -c 'network 10.0.3.0/24 area 0' -c 'network 10.0.23.0/30 area 0' -c 'network 10.0.13.0/30 area 0' \
    -c 'passive-interface lan' >/dev/null
  echo "OSPF area 0 configured on r1 r2 r3. Wait ~15 s for neighbours and routes (./ospf-lab.sh status)."
}

status() {
  local r
  for r in "${ROUTERS[@]}"; do
    echo "===== $r: neighbours"
    vtysh -N "$r" -c 'show ip ospf neighbor' | sed -n '3,$p'
    echo "----- $r: OSPF routes in the kernel table"
    ip -n "$r" route | grep 'proto ospf' || echo "  (none)"
  done
}

test_lab() {
  local out
  if out=$(ip netns exec pc1 ping -c1 -W1 10.0.3.10 2>&1); then
    echo "pc1 -> pc3: OK ($(grep -o 'ttl=[0-9]*' <<<"$out"))  [ttl 62 = 2 routers, 61 = 3 routers]"
  else
    local why
    why=$(grep -o 'From .*Unreachable' <<<"$out" | head -1 || true)
    echo "pc1 -> pc3: FAILED (${why:-timeout - no reply, a return route may be missing})"
  fi
  echo "r1 path to 10.0.3.0/24: $(ip -n r1 route get 10.0.3.10 2>/dev/null | head -1 || echo 'no route')"
}

fail() {
  echo "Cutting r1-r3 (to-r3 down on r1). Watching pc1 -> pc3 every second:"
  ip -n r1 link set to-r3 down
  local t out
  for t in $(seq 1 15); do
    if out=$(ip netns exec pc1 ping -c1 -W1 10.0.3.10 2>&1); then
      printf '  t=%2ss  OK   %s  %s\n' "$t" "$(grep -o 'ttl=[0-9]*' <<<"$out")" \
        "$(ip -n r1 route get 10.0.3.10 | grep -o 'via [0-9.]*')"
    else
      printf '  t=%2ss  LOST\n' "$t"
    fi
    sleep 1
  done
}

restore() {
  ip -n r1 link set to-r3 up
  echo "r1-r3 back up. Give OSPF ~10 s, then run: ./ospf-lab.sh test"
}

down() {
  local r n pid
  for r in "${ROUTERS[@]}"; do
    for pid in /var/run/frr/"$r"/*.pid; do
      if [[ -f $pid ]]; then kill "$(cat "$pid")" 2>/dev/null || true; fi
    done
  done
  sleep 1
  for n in "${NODES[@]}"; do ip netns del "$n" 2>/dev/null || true; done
  for r in "${ROUTERS[@]}"; do rm -rf "/etc/frr/$r" "/var/run/frr/$r"; done
  echo "Lab removed."
}

case "${1:-}" in
  up) up ;; test) test_lab ;; ospf) ospf ;; status) status ;;
  fail) fail ;; restore) restore ;; down) down ;;
  *) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
