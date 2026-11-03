#!/usr/bin/env bash
# drop-reject-lab.sh - Lab 15: DROP vs REJECT (what the client really sees)
#
# Topology:
#
#   +-----------+  10.0.15.0/30   +-----------------------------+
#   |   pc1     |srv           pc1|            srv              |
#   | 10.0.15.1 |-----------------| 10.0.15.2                   |
#   +-----------+                 | python3 http.server on      |
#                                 |   8080 8081 8082 8083       |
#                                 | nftables table ip lab15:    |
#                                 |   8080 -> accept (baseline) |
#                                 |   8081 -> drop              |
#                                 |   8082 -> reject tcp reset  |
#                                 |   8083 -> reject icmp       |
#                                 |           admin-prohibited  |
#                                 |   8084 -> no rule, NO app   |
#                                 +-----------------------------+
#
# Usage:
#   drop-reject-lab.sh up          create namespaces, servers and firewall
#   drop-reject-lab.sh probe PORT  connect from pc1 to srv:PORT, show result,
#                                  time and the packets seen on pc1
#   drop-reject-lab.sh test        probe all ports, one-line summary each
#   drop-reject-lab.sh counters    show nftables rule counters on srv
#   drop-reject-lab.sh down        remove everything
set -euo pipefail
export LC_ALL=C   # dot as decimal separator in awk/printf

PC=pc1
SRV=srv
PC_IP=10.0.15.1
SRV_IP=10.0.15.2
PORTS="8080 8081 8082 8083"      # ports with a running server
ALL_PORTS="8080 8081 8082 8083 8084"
WWW=/tmp/lab15-www
TIMEOUT=5

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 1; }

need_root() {
    [[ $EUID -eq 0 ]] || { echo "Run as root (sudo -i first)."; exit 1; }
}

need_deps() {
    local missing=()
    for c in ip nft python3 tcpdump; do
        command -v "$c" >/dev/null || missing+=("$c")
    done
    if (( ${#missing[@]} )); then
        echo "Missing: ${missing[*]}"
        echo "Install: apt install iproute2 nftables python3 tcpdump"
        exit 1
    fi
}

up() {
    for ns in "$PC" "$SRV"; do
        if ip netns list | grep -qw "$ns"; then
            echo "Namespace $ns already exists (old lab?). Run its 'down' first."
            exit 1
        fi
    done
    ip netns add "$PC"
    ip netns add "$SRV"

    # veth named by neighbour: in pc1 it is called "srv", in srv "pc1"
    ip link add lab15a type veth peer name lab15b
    ip link set lab15a netns "$PC"
    ip link set lab15b netns "$SRV"
    ip -n "$PC"  link set lab15a name "$SRV"
    ip -n "$SRV" link set lab15b name "$PC"

    ip -n "$PC"  addr add "$PC_IP/30"  dev "$SRV"
    ip -n "$SRV" addr add "$SRV_IP/30" dev "$PC"
    ip -n "$PC"  link set lo up
    ip -n "$SRV" link set lo up
    ip -n "$PC"  link set "$SRV" up
    ip -n "$SRV" link set "$PC" up

    # Real servers on every port, so any failure comes from the firewall
    mkdir -p "$WWW"
    echo "hello from srv" > "$WWW/index.html"
    for p in $PORTS; do
        ip netns exec "$SRV" python3 -m http.server "$p" --bind "$SRV_IP" \
            -d "$WWW" >/dev/null 2>&1 &
        echo $! > "/run/lab15-http-$p.pid"
    done

    ip netns exec "$SRV" nft -f - <<'EOF'
table ip lab15 {
    chain input {
        type filter hook input priority 0; policy accept;
        tcp dport 8080 counter accept
        tcp dport 8081 counter drop
        tcp dport 8082 counter reject with tcp reset
        tcp dport 8083 counter reject with icmp type admin-prohibited
    }
}
EOF
    sleep 1
    echo "Lab up. Servers listening in srv:"
    ip netns exec "$SRV" ss -ltn | grep "$SRV_IP" || true
}

# Connect once, print errno text and elapsed time
connect_once() {
    local port=$1
    ip netns exec "$PC" python3 - "$SRV_IP" "$port" "$TIMEOUT" <<'EOF'
import socket, sys, time
host, port, tmo = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
t0 = time.time()
try:
    s = socket.create_connection((host, port), timeout=tmo)
    s.close()
    r = "CONNECTED (handshake done)"
except socket.timeout:
    r = "TIMEOUT (no answer at all)"
except OSError as e:
    r = f"ERROR: {e.strerror}"
print(f"port {port}: {r}  after {time.time() - t0:.2f} s")
EOF
}

probe() {
    local port=${1:?usage: probe PORT}
    local cap=/tmp/lab15-cap.txt
    ip netns exec "$PC" tcpdump -lni "$SRV" -tt "host $SRV_IP and not arp" \
        >"$cap" 2>/dev/null &
    local tp=$!
    sleep 1
    connect_once "$port"
    sleep 0.5
    kill "$tp" 2>/dev/null; wait "$tp" 2>/dev/null || true
    echo "--- packets on pc1 ---"
    if [[ -s $cap ]]; then
        # relative time from the first packet
        awk 'NF==0{next} !t0{t0=$1} {printf "+%5.2fs ", $1-t0; $1=""; print}' "$cap"
    else
        echo "(nothing captured)"
    fi
}

test_all() {
    for p in $ALL_PORTS; do connect_once "$p"; done
}

counters() {
    ip netns exec "$SRV" nft list table ip lab15
}

down() {
    for p in $PORTS; do
        if [[ -f /run/lab15-http-$p.pid ]]; then
            kill "$(cat "/run/lab15-http-$p.pid")" 2>/dev/null || true
            rm -f "/run/lab15-http-$p.pid"
        fi
    done
    ip netns del "$PC"  2>/dev/null || true
    ip netns del "$SRV" 2>/dev/null || true
    rm -rf "$WWW" /tmp/lab15-cap.txt
    echo "Lab down."
}

[[ $# -ge 1 ]] || usage
need_root
case $1 in
    up)       need_deps; up ;;
    probe)    need_deps; probe "${2:-}" ;;
    test)     test_all ;;
    counters) counters ;;
    down)     down ;;
    *)        usage ;;
esac
