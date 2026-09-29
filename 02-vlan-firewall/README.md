# Lab 02 – Stateful firewall between VLANs (nftables)

Builds on [Lab 01](../01-vlan-lab/): the router-on-a-stick `r1` becomes a stateful firewall that enforces segmentation between an office VLAN and a less-trusted warehouse/IoT VLAN.

## Scenario

| VLAN | Zone | Hosts | Trust |
|---|---|---|---|
| 10 | Office | pc1 (app server on tcp/8080), pc2 | trusted |
| 20 | Warehouse / IoT | pc3, pc4 (scanners, cameras) | untrusted |

**Policy (default deny):**

| Traffic | Decision |
|---|---|
| Office → Warehouse | allow |
| Warehouse → Office, replies to connections started by Office | allow (stateful) |
| Warehouse → 192.168.10.1 tcp/8080 (app server) | allow |
| Anything else Warehouse → Office | drop + count |

## Run

    sudo -i
    cd network-labs/01-vlan-lab
    ./vlan-lab.sh phase1 && ./vlan-lab.sh phase2 && ./vlan-lab.sh phase3
    cd ../02-vlan-firewall
    ip netns exec r1 nft -f firewall.nft
    ./test-policy.sh

## What I learned

1. **VLANs alone are not security.** Without rules the router forwards everything between VLANs.
2. **Stateless rules break replies.** With only `Office → Warehouse accept`, even Office-initiated pings failed: the echo reply travels Warehouse → Office and hit `policy drop`.
3. **Stateful inspection fixes it precisely.** `ct state established,related accept` allows replies only for connections that were already allowed. Conntrack tracks flows (protocol, IPs, ports), not hosts.
4. **Least privilege.** The exception opens one host and one port. pc2 on tcp/8080 stays blocked (2 s timeout = silent drop).
5. **Visibility.** A counter before the default drop answers "is the firewall blocking it?".
6. **Change management.** I deleted the wrong rule by handle and cut Office → Warehouse traffic. Fix: always `nft -a list ruleset` before `delete`, keep the known-good ruleset in Git.

## Mapping to enterprise firewalls

| This lab | FortiGate / Palo Alto |
|---|---|
| `iifname` / `oifname` | interfaces / security zones |
| `policy drop` | implicit deny |
| `ct state established,related` | session table (stateful) |
| `ip daddr ... tcp dport 8080` | address + service objects |
| `counter` | policy hit counters / logs |
