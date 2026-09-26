#!/usr/bin/env bash
# =============================================================================
# vlan-lab.sh - VLANs and router-on-a-stick on plain Linux (no Packet Tracer)
#
# Topology:
#
#          r1 (router)  eth0.10 = 192.168.10.254/24
#           |           eth0.20 = 192.168.20.254/24
#           | trunk (802.1Q, VLAN 10 + 20 tagged)
#   +-------+-----------------------------+
#   |              br0 (switch)           |
#   +---+--------+--------+--------+------+
#       |access  |access  |access  |access
#      pc1      pc2      pc3      pc4
#     VLAN 10  VLAN 10  VLAN 20  VLAN 20
#
# Cisco equivalents:
#   br0 + vlan_filtering        -> managed L2 switch
#   "pvid untagged" port        -> switchport mode access / access vlan X
#   tagged port (r1)            -> switchport mode trunk
#   eth0.10 on r1               -> interface g0/0.10 / encapsulation dot1Q 10
#
# Usage (as root):
#   ./vlan-lab.sh phase1    # flat network, all hosts in VLAN 1, same subnet
#   ./vlan-lab.sh phase2    # split into VLAN 10 / VLAN 20 (same subnet!)
#   ./vlan-lab.sh phase3    # router-on-a-stick, one subnet per VLAN
#   ./vlan-lab.sh test      # run the connectivity checks for the current phase
#   ./vlan-lab.sh capture   # tcpdump on the trunk to see 802.1Q tags
#   ./vlan-lab.sh down      # remove everything
#
# Phases build on each other: phase2 needs phase1, phase3 needs phase2.
# Nothing touches your real NICs; everything disappears on reboot or "down".
# =============================================================================
set -euo pipefail

HOSTS=(pc1 pc2 pc3 pc4)
VLAN10=(pc1 pc2)
VLAN20=(pc3 pc4)

need_root() {
  [[ $EUID -eq 0 ]] || { echo "Run as root (sudo -i)"; exit 1; }
}

# Docker loads br_netfilter, which pushes bridged frames through iptables
# (FORWARD policy DROP) and silently breaks pings between lab hosts.
check_br_netfilter() {
  local f=/proc/sys/net/bridge/bridge-nf-call-iptables
  if [[ -f $f && $(cat "$f") == 1 ]]; then
    echo "!! br_netfilter is active (Docker?). If pings fail, run:"
    echo "   sysctl -w net.bridge.bridge-nf-call-iptables=0"
  fi
}

ping_check() {  # ping_check <from-ns> <ip> <expected: ok|fail>
  local ns=$1 ip=$2 want=$3 got
  if ip netns exec "$ns" ping -c2 -W1 "$ip" >/dev/null 2>&1; then got=ok; else got=fail; fi
  local mark="PASS"; [[ $got == "$want" ]] || mark="UNEXPECTED"
  printf '  %-4s -> %-15s expected %-4s got %-4s [%s]\n' "$ns" "$ip" "$want" "$got" "$mark"
}

# --- Phase 1: one flat switch, everyone in VLAN 1 ----------------------------
phase1() {
  # The switch. vlan_filtering=1 makes it VLAN-aware ("managed").
  ip link add br0 type bridge vlan_filtering 1
  ip link set br0 up

  local i=1
  for pc in "${HOSTS[@]}"; do
    ip netns add "$pc"                                   # a separate "computer"
    ip link add "$pc" type veth peer name eth0 netns "$pc"  # a cable: one end in the PC
    ip link set "$pc" master br0 up                      # other end into a switch port
    ip -n "$pc" link set eth0 up
    ip -n "$pc" addr add "192.168.1.$i/24" dev eth0
    i=$((i + 1))
  done

  echo "Phase 1 ready: all ports in VLAN 1, subnet 192.168.1.0/24"
  bridge vlan show
  check_br_netfilter
}

# --- Phase 2: split the switch into VLAN 10 and VLAN 20 ----------------------
# IP addresses stay in ONE subnet on purpose: this shows VLANs isolate at L2.
# pc1 -> pc3 fails because the ARP broadcast never leaves VLAN 10.
phase2() {
  for p in "${VLAN10[@]}"; do
    bridge vlan del dev "$p" vid 1
    bridge vlan add dev "$p" vid 10 pvid untagged      # access port, VLAN 10
  done
  for p in "${VLAN20[@]}"; do
    bridge vlan del dev "$p" vid 1
    bridge vlan add dev "$p" vid 20 pvid untagged      # access port, VLAN 20
  done
  echo "Phase 2 ready: pc1,pc2 = VLAN 10; pc3,pc4 = VLAN 20 (same IP subnet)"
  bridge vlan show
}

# --- Phase 3: router-on-a-stick ----------------------------------------------
phase3() {
  # Router with a single trunk link to the switch
  ip netns add r1
  ip link add r1 type veth peer name eth0 netns r1
  ip link set r1 master br0 up
  bridge vlan del dev r1 vid 1
  bridge vlan add dev r1 vid 10                        # tagged -> trunk
  bridge vlan add dev r1 vid 20

  # Subinterfaces = default gateways for each VLAN
  ip -n r1 link set eth0 up
  ip -n r1 link add link eth0 name eth0.10 type vlan id 10
  ip -n r1 link add link eth0 name eth0.20 type vlan id 20
  ip -n r1 addr add 192.168.10.254/24 dev eth0.10
  ip -n r1 addr add 192.168.20.254/24 dev eth0.20
  ip -n r1 link set eth0.10 up
  ip -n r1 link set eth0.20 up
  ip netns exec r1 sysctl -qw net.ipv4.ip_forward=1

  # One subnet per VLAN + default gateway on every host
  local i
  for i in 1 2; do
    ip -n "pc$i" addr flush dev eth0
    ip -n "pc$i" addr add "192.168.10.$i/24" dev eth0
    ip -n "pc$i" route add default via 192.168.10.254
  done
  for i in 3 4; do
    ip -n "pc$i" addr flush dev eth0
    ip -n "pc$i" addr add "192.168.20.$i/24" dev eth0
    ip -n "pc$i" route add default via 192.168.20.254
  done

  echo "Phase 3 ready: VLAN 10 = 192.168.10.0/24, VLAN 20 = 192.168.20.0/24, gw .254"
  bridge vlan show
}

# --- Tests: detect the current phase and check expected behaviour -----------
test_lab() {
  if ip netns list | grep -qw r1; then
    echo "Phase 3 checks (routed between VLANs, expect TTL 63 across the router):"
    ping_check pc1 192.168.10.2 ok
    ping_check pc1 192.168.20.3 ok
    ip netns exec pc1 ping -c1 -W1 192.168.20.3 | grep -o 'ttl=[0-9]*' | sed 's/^/  pc1 -> pc3 /' || true
  elif bridge vlan show dev pc1 | grep -qw 10; then
    echo "Phase 2 checks (same subnet, different VLANs):"
    ping_check pc1 192.168.1.2 ok
    ping_check pc1 192.168.1.3 fail
    echo "  ARP table of pc1 (192.168.1.3 should be FAILED/INCOMPLETE):"
    ip -n pc1 neigh | sed 's/^/    /'
  else
    echo "Phase 1 checks (flat network):"
    ping_check pc1 192.168.1.2 ok
    ping_check pc1 192.168.1.3 ok
  fi
}

# --- Capture: see 802.1Q tags on the trunk ------------------------------------
# Each ping crosses the trunk twice: as VLAN 10 (pc1->r1) and VLAN 20 (r1->pc3).
# MAC addresses change on every hop; IP addresses stay the same end to end.
capture() {
  command -v tcpdump >/dev/null || { echo "Install tcpdump first: apt install -y tcpdump"; exit 1; }
  ip netns list | grep -qw r1 || { echo "Run phase3 first"; exit 1; }
  ( sleep 1; ip netns exec pc1 ping -c1 -W1 192.168.20.3 >/dev/null ) &
  timeout 4 tcpdump -e -n -l -i r1 icmp || true
}

# --- Cleanup -------------------------------------------------------------------
down() {
  for n in "${HOSTS[@]}" r1; do ip netns del "$n" 2>/dev/null || true; done
  ip link del br0 2>/dev/null || true
  echo "Lab removed."
}

need_root
case "${1:-}" in
  phase1)  phase1 ;;
  phase2)  phase2 ;;
  phase3)  phase3 ;;
  test)    test_lab ;;
  capture) capture ;;
  down)    down ;;
  *) sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
