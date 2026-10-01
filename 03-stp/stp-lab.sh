#!/usr/bin/env bash
# stp-lab.sh - Spanning Tree on three Linux bridges in a triangle
#
#        sw1 (02:..:30)
#   s12 /     \ s13
#  s21 /       \ s31
#   sw2 ------- sw3 (02:..:20)
#  (02:..:10) s23  s32
#
# Usage (as root):
#   ./stp-lab.sh up       build the triangle with STP, show port states
#   ./stp-lab.sh status   show root bridge and port states
#   ./stp-lab.sh fail     cut sw1-sw2, watch s13 go blocking -> forwarding
#   ./stp-lab.sh restore  bring sw1-sw2 back, s13 returns to blocking
#   ./stp-lab.sh down     remove everything
#
# Timers are shortened (forward delay 4 s instead of 15 s) so changes take
# ~8 s instead of ~30 s. Values are in centiseconds.
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Run as root (sudo -i)"; exit 1; }

port_state() { bridge link show dev "$1" | grep -o 'state [a-z]*' | cut -d' ' -f2; }

status() {
  echo "Port states (expected: only s13 blocking):"
  bridge link show | awk '
    / master sw[123] / {
      name=$2; sub(/@.*/, "", name)
      for (i = 1; i <= NF; i++) { if ($i=="master") br=$(i+1); if ($i=="state") st=$(i+1) }
      printf "  %-4s on %-3s  %s\n", name, br, st
    }' | sort -k3
  echo "Root bridge: sw2 (lowest bridge ID 8000.02:00:00:00:00:10); all its ports forward."
}

up() {
  # STP is enabled BEFORE any cable is connected, so no loop ever exists.
  for i in 1 2 3; do
    ip link add "sw$i" type bridge stp_state 1 forward_delay 400 hello_time 100 max_age 600
  done
  ip link set sw1 address 02:00:00:00:00:30
  ip link set sw2 address 02:00:00:00:00:10
  ip link set sw3 address 02:00:00:00:00:20
  for i in 1 2 3; do ip link set "sw$i" up; done

  ip link add s12 type veth peer name s21
  ip link add s13 type veth peer name s31
  ip link add s23 type veth peer name s32
  ip link set s12 master sw1; ip link set s13 master sw1
  ip link set s21 master sw2; ip link set s23 master sw2
  ip link set s31 master sw3; ip link set s32 master sw3
  for p in s12 s21 s13 s31 s23 s32; do ip link set "$p" up; done

  echo "Waiting 10 s for STP to converge..."
  sleep 10
  status
}

fail() {
  echo "Cutting sw1-sw2 (s12 down). Watching alternate port s13:"
  ip link set s12 down
  for t in 0 2 4 6 8 10; do
    printf '  t=%2ss  s13: %s\n' "$t" "$(port_state s13)"
    if [[ $t -lt 10 ]]; then sleep 2; fi
  done
}

restore() {
  echo "Restoring sw1-sw2 (s12 up)..."
  ip link set s12 up
  sleep 10
  status
}

down() {
  for p in s12 s13 s23; do ip link del "$p" 2>/dev/null || true; done
  for i in 1 2 3; do ip link del "sw$i" 2>/dev/null || true; done
  echo "Lab removed."
}

case "${1:-}" in
  up) up ;; status) status ;; fail) fail ;; restore) restore ;; down) down ;;
  *) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
