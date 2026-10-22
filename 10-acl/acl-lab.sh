#!/usr/bin/env bash
# acl-lab.sh - Cisco-style ACLs (standard vs extended, order, implicit deny) with nftables
#
#   pc1 10.0.10.10 (admin) --+
#   pc2 10.0.10.20 (user)  --+-- users   [    ]  servers --- srv 10.0.20.10  (web :80, ssh :22)
#                                  .1    [ r1 ]  .1
#   guest 10.0.30.10 ----------- guests  [    ]
#                                  .1
# Policy:
#   - users may open the web server (tcp 80) and ping srv
#   - only pc1 (admin) may use SSH (tcp 22) on srv
#   - guests must not reach the servers network at all, but may reach users
#
# Usage (as root):
#   ./acl-lab.sh up          build topology, start web + ssh listeners on srv
#   ./acl-lab.sh test        access matrix: who can reach what
#   ./acl-lab.sh acl-wrong   apply ACLs with a rule in the WRONG order
#   ./acl-lab.sh acl         apply ACLs in the right order (extended near source, standard near destination)
#   ./acl-lab.sh acl-final   same + permit traffic from users to guests (ACLs are stateless!)
#   ./acl-lab.sh counters    hit counters per rule (like "show access-lists")
#   ./acl-lab.sh clear       remove all ACLs
#   ./acl-lab.sh down        remove everything
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Run as root (sudo ./acl-lab.sh ...)"; exit 1; }
for b in nft python3; do
  command -v "$b" >/dev/null || { echo "Missing $b: apt install -y nftables python3"; exit 1; }
done

NODES=(pc1 pc2 guest r1 srv)
RUN=/run/netlab-acl

listen() {  # listen <port>: tiny TCP service on srv that accepts and closes
  ip netns exec srv python3 -c "
import socket
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('0.0.0.0', $1)); s.listen(16)
while True:
    c, _ = s.accept(); c.close()
" >/dev/null 2>&1 &
  echo $! > "$RUN/srv-$1.pid"
}


up() {
  mkdir -p "$RUN"
  local n i
  for n in "${NODES[@]}"; do ip netns add "$n"; done
  ip -n r1 link add users type bridge
  ip -n pc1 link add eth0 type veth peer name p-pc1 netns r1
  ip -n pc2 link add eth0 type veth peer name p-pc2 netns r1
  ip -n r1 link set p-pc1 master users
  ip -n r1 link set p-pc2 master users
  ip -n guest link add eth0 type veth peer name guests netns r1
  ip -n srv   link add eth0 type veth peer name servers netns r1

  ip -n pc1   addr add 10.0.10.10/24 dev eth0
  ip -n pc2   addr add 10.0.10.20/24 dev eth0
  ip -n guest addr add 10.0.30.10/24 dev eth0
  ip -n srv   addr add 10.0.20.10/24 dev eth0
  ip -n r1 addr add 10.0.10.1/24 dev users
  ip -n r1 addr add 10.0.30.1/24 dev guests
  ip -n r1 addr add 10.0.20.1/24 dev servers
  for n in "${NODES[@]}"; do
    for i in $(ip -n "$n" -o link show | awk -F': ' '{print $2}' | cut -d@ -f1); do
      ip -n "$n" link set "$i" up
    done
  done
  ip netns exec r1 sysctl -qw net.ipv4.ip_forward=1
  ip -n pc1   route add default via 10.0.10.1
  ip -n pc2   route add default via 10.0.10.1
  ip -n guest route add default via 10.0.30.1
  ip -n srv   route add default via 10.0.20.1
  listen 80
  listen 22
  sleep 1
  echo "Up. r1 routes everything - no ACLs yet."
}

can_ping() { ip netns exec "$1" ping -c1 -W1 "$2" >/dev/null 2>&1 && echo ok || echo "--"; }
can_tcp()  { ip netns exec "$1" timeout 2 bash -c "exec 3<>/dev/tcp/$2/$3" 2>/dev/null && echo ok || echo "--"; }

test_lab() {
  printf '  %-6s %-9s %-9s %-9s %-9s\n' from "ping srv" "web :80" "ssh :22" "ping pc1"
  local h p1
  for h in pc1 pc2 guest; do
    p1=$([[ $h == guest ]] && can_ping guest 10.0.10.10 || echo "")
    printf '  %-6s %-9s %-9s %-9s %-9s\n' "$h" \
      "$(can_ping "$h" 10.0.20.10)" "$(can_tcp "$h" 10.0.20.10 80)" "$(can_tcp "$h" 10.0.20.10 22)" "$p1"
  done
}

apply() {  # apply <wrong|right|final>
  ip netns exec r1 nft delete table ip acl 2>/dev/null || true
  local first last=""
  [[ $1 == final ]] && last='ip daddr 10.0.30.0/24 counter accept comment "50 permit users to guests (incl. replies)"'
  if [[ $1 == wrong ]]; then
    first='ip saddr 10.0.10.0/24 ip daddr 10.0.20.10 counter accept comment "10 permit users to srv (too broad, too early)"'
  else
    first='ip saddr 10.0.10.10 ip daddr 10.0.20.10 tcp dport 22 counter accept comment "10 permit pc1 ssh"'
  fi
  ip netns exec r1 nft -f - <<NFT
table ip acl {
  chain forward {
    type filter hook forward priority filter; policy accept;
    iifname "users"   jump USERS_IN      # extended ACL, inbound on the users interface (near the source)
    oifname "servers" jump NO_GUESTS     # standard ACL, outbound towards servers (near the destination)
  }
  chain USERS_IN {
    $first
    ip daddr 10.0.20.10 tcp dport 22 counter drop comment "20 deny ssh for everyone else"
    ip daddr 10.0.20.10 tcp dport 80 counter accept comment "30 permit web"
    ip daddr 10.0.20.10 icmp type echo-request counter accept comment "40 permit ping"
    $last
    counter drop comment "implicit deny (invisible on Cisco)"
  }
  chain NO_GUESTS {
    ip saddr 10.0.30.0/24 counter drop comment "10 deny guests"
    counter accept comment "20 permit any"
  }
}
NFT
  echo "ACLs applied ($1 order)."
}

counters() {
  ip netns exec r1 nft list table ip acl 2>/dev/null \
    | grep -E 'chain (USERS_IN|NO_GUESTS)|counter' \
    | sed -E 's/^\s+//; s/counter packets ([0-9]+) bytes [0-9]+/[\1 matches]/' \
    | awk '/^chain/ {print; next} {c=$0; sub(/.*comment /,"",c); m=$0; sub(/.*\[/,"[",m); sub(/\].*/,"]",m); printf "  %-14s %s\n", m, c}' \
    || echo "No ACLs on r1."
}

clear_acl() { ip netns exec r1 nft delete table ip acl 2>/dev/null || true; echo "ACLs removed."; }

down() {
  local f n
  for f in "$RUN"/*.pid; do [[ -f $f ]] && kill "$(cat "$f")" 2>/dev/null || true; done
  for n in "${NODES[@]}"; do ip netns del "$n" 2>/dev/null || true; done
  rm -rf "$RUN"
  echo "Lab removed."
}

case "${1:-}" in
  up) up ;; test) test_lab ;; acl-wrong) apply wrong ;; acl) apply right ;; acl-final) apply final ;;
  counters) counters ;; clear) clear_acl ;; down) down ;;
  *) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
