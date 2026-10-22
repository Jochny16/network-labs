#!/usr/bin/env bash
# nat-lab.sh - NAT/PAT and port forwarding with nftables on a Linux router
#
#   pc1 192.168.1.10 --+
#                      +-- lan [ r1 ] wan ---------- srv 203.0.113.10
#   pc2 192.168.1.20 --+  .1         203.0.113.1      "internet" web server
#        private LAN (192.168.1.0/24)          public side (203.0.113.0/24)
#
# srv only knows the public network - like a server on the internet,
# it has NO route to 192.168.1.0/24 (private addresses are not routed).
#
# Usage (as root):
#   ./nat-lab.sh up        build topology, start web servers on srv and pc1
#   ./nat-lab.sh test      pc1 -> srv (ping + curl) and what srv sees
#   ./nat-lab.sh nat       enable PAT (masquerade) on r1's wan interface
#   ./nat-lab.sh pat       pc1 and pc2 open connections at the same time: src IP and ports on srv
#   ./nat-lab.sh forward   port forwarding: srv -> 203.0.113.1:8080 -> pc1:80
#   ./nat-lab.sh rules     show r1's nftables NAT rules and the NAT table (conntrack)
#   ./nat-lab.sh down      remove everything
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Run as root (sudo ./nat-lab.sh ...)"; exit 1; }
for b in nft tcpdump python3 curl; do
  command -v "$b" >/dev/null || { echo "Missing $b: apt install -y nftables tcpdump python3 curl"; exit 1; }
done

NODES=(pc1 pc2 r1 srv)
RUN=/run/netlab-nat

web() {  # web <ns> <log>: tiny web server on port 80 that says who it is
  mkdir -p "$RUN/www-$1" && echo "<h1>$1</h1>" > "$RUN/www-$1/index-$1.html"
  ip netns exec "$1" sh -c "python3 -m http.server 80 --bind 0.0.0.0 --directory $RUN/www-$1 \
    >$2 2>&1 & echo \$! > $RUN/$1-web.pid"
}

up() {
  mkdir -p "$RUN"
  local n i
  for n in "${NODES[@]}"; do ip netns add "$n"; done
  ip -n r1 link add lan type bridge
  ip -n pc1 link add eth0 type veth peer name p-pc1 netns r1
  ip -n pc2 link add eth0 type veth peer name p-pc2 netns r1
  ip -n r1 link set p-pc1 master lan
  ip -n r1 link set p-pc2 master lan
  ip -n r1 link add wan type veth peer name eth0 netns srv

  ip -n pc1 addr add 192.168.1.10/24 dev eth0
  ip -n pc2 addr add 192.168.1.20/24 dev eth0
  ip -n r1  addr add 192.168.1.1/24  dev lan
  ip -n r1  addr add 203.0.113.1/24  dev wan
  ip -n srv addr add 203.0.113.10/24 dev eth0
  for n in "${NODES[@]}"; do
    for i in $(ip -n "$n" -o link show | awk -F': ' '{print $2}' | cut -d@ -f1); do
      ip -n "$n" link set "$i" up
    done
  done
  ip netns exec r1 sysctl -qw net.ipv4.ip_forward=1
  ip -n pc1 route add default via 192.168.1.1
  ip -n pc2 route add default via 192.168.1.1
  # srv: no route back to 192.168.1.0/24 on purpose

  web srv "$RUN/srv-web.log"
  web pc1 "$RUN/pc1-web.log"
  sleep 1
  echo "Up. r1 routes, but does NOT translate addresses yet."
}

last_client() {  # last_client <log>: client address of the last HTTP request
  grep '"GET' "$1" 2>/dev/null | tail -n 1 | awk '{print $1}' | grep . || echo "(no completed request)"
}

test_lab() {
  local out
  if ip netns exec pc1 ping -c1 -W1 203.0.113.10 >/dev/null 2>&1; then
    echo "  ping pc1 -> srv : OK"
  else
    echo "  ping pc1 -> srv : TIMEOUT"
  fi
  out=$(ip netns exec pc1 curl -s --max-time 2 http://203.0.113.10/index-srv.html || true)
  echo "  curl pc1 -> srv : ${out:-no answer}"
  echo "  srv's log - client address of the last request: $(last_client "$RUN/srv-web.log")"
}

nat() {
  ip netns exec r1 nft -f - <<'NFT'
table ip nat {
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    oifname "wan" ip saddr 192.168.1.0/24 masquerade
  }
}
NFT
  echo "PAT on: traffic from 192.168.1.0/24 leaving 'wan' gets r1's public address."
}

pat() {
  local cap=$RUN/pat.txt
  ip netns exec srv timeout 6 tcpdump -lnni eth0 'tcp dst port 80 and tcp[tcpflags] & tcp-syn != 0' \
    > "$cap" 2>/dev/null &
  sleep 1
  ip netns exec pc1 curl -s -o /dev/null --local-port 40000 http://203.0.113.10/index-srv.html &
  ip netns exec pc2 curl -s -o /dev/null --local-port 40000 http://203.0.113.10/index-srv.html &
  wait %2 %3 2>/dev/null || true
  sleep 1
  echo "pc1 and pc2 both used source port 40000. What srv received (src > dst):"
  awk '{print "  " $3, $4, $5}' "$cap" | sed 's/:$//'
  wait 2>/dev/null || true
}

forward() {
  ip netns exec r1 nft -f - <<'NFT'
table ip nat {
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    iifname "wan" tcp dport 8080 dnat to 192.168.1.10:80
  }
}
NFT
  echo "Port forwarding on: 203.0.113.1:8080 -> pc1 192.168.1.10:80"
  local out
  out=$(ip netns exec srv curl -s --max-time 2 http://203.0.113.1:8080/index-pc1.html || true)
  echo "  curl srv -> 203.0.113.1:8080 : ${out:-no answer}"
  echo "  pc1's log - client address: $(last_client "$RUN/pc1-web.log")"
}

rules() {
  ip netns exec r1 nft list table ip nat 2>/dev/null || echo "No NAT rules on r1."
  echo "NAT table (conntrack) on r1:"
  { if command -v conntrack >/dev/null; then ip netns exec r1 conntrack -L 2>/dev/null
    else ip netns exec r1 cat /proc/net/nf_conntrack 2>/dev/null; fi; } \
    | grep -E 'dport=(80|8080) ' \
    | awk '{for(i=1;i<=NF;i++) if($i ~ /^(src|dst|sport|dport)=/) printf "%s ", $i; print ""}' \
    | sed 's/^/  /' | head -6
}

down() {
  local f n
  for f in "$RUN"/*.pid; do [[ -f $f ]] && kill "$(cat "$f")" 2>/dev/null || true; done
  for n in "${NODES[@]}"; do ip netns del "$n" 2>/dev/null || true; done
  rm -rf "$RUN"
  echo "Lab removed."
}

case "${1:-}" in
  up) up ;; test) test_lab ;; nat) nat ;; pat) pat ;; forward) forward ;;
  rules) rules ;; down) down ;;
  *) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
