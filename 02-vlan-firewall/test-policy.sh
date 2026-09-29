#!/usr/bin/env bash
# test-policy.sh - verify the inter-VLAN firewall policy on r1
# Prerequisites (as root): lab 01 phases 1-3, then: ip netns exec r1 nft -f firewall.nft
set -uo pipefail
[[ $EUID -eq 0 ]] || { echo "Run as root (sudo -i)"; exit 1; }
pass=0; fail=0
check() {  # check <description> <expected: ok|blocked> <command...>
  local desc=$1 want=$2; shift 2
  local got
  if "$@" >/dev/null 2>&1; then got=ok; else got=blocked; fi
  if [[ $got == "$want" ]]; then
    printf '  [PASS] %-45s expected %-7s got %s\n' "$desc" "$want" "$got"; pass=$((pass + 1))
  else
    printf '  [FAIL] %-45s expected %-7s got %s\n' "$desc" "$want" "$got"; fail=$((fail + 1))
  fi
}
http() { [[ $(ip netns exec "$1" curl -s -m2 -o /dev/null -w '%{http_code}' "$2") == 200 ]]; }
ip netns exec pc1 python3 -m http.server 8080 >/dev/null 2>&1 & srv1=$!
ip netns exec pc2 python3 -m http.server 8080 >/dev/null 2>&1 & srv2=$!
trap 'kill $srv1 $srv2 2>/dev/null' EXIT
sleep 1
echo "Firewall policy tests:"
check "Office pc1 -> Warehouse pc3 (ping)"           ok      ip netns exec pc1 ping -c1 -W1 192.168.20.3
check "Office pc2 -> Warehouse pc4 (ping)"           ok      ip netns exec pc2 ping -c1 -W1 192.168.20.4
check "Warehouse pc3 -> Office pc1 (ping)"           blocked ip netns exec pc3 ping -c1 -W1 192.168.10.1
check "Warehouse pc3 -> server pc1:8080 (HTTP)"      ok      http pc3 http://192.168.10.1:8080
check "Warehouse pc3 -> pc2:8080 (not the server)"   blocked http pc3 http://192.168.10.2:8080
check "Warehouse pc4 -> server pc1:8080 (HTTP)"      ok      http pc4 http://192.168.10.1:8080
check "Same VLAN pc3 -> pc4 (not routed)"            ok      ip netns exec pc3 ping -c1 -W1 192.168.20.4
echo; echo "Drop counter on r1:"
ip netns exec r1 nft list ruleset | grep 'dropped by policy' | sed 's/^[[:space:]]*/  /'
echo; echo "Result: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
