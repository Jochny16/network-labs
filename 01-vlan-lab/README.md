# VLAN lab on plain Linux

VLANs, trunking and router-on-a-stick built only with `iproute2`: a VLAN-aware Linux bridge acts as the switch, network namespaces act as PCs and the router. No Packet Tracer, GNS3 or VMs needed.

Part of my CCNA preparation (topics: VLANs, 802.1Q trunking, inter-VLAN routing).

## Topology

```
         r1 (router)  eth0.10 = 192.168.10.254/24
          |           eth0.20 = 192.168.20.254/24
          | trunk (802.1Q, VLAN 10 + 20 tagged)
  +-------+-----------------------------+
  |              br0 (switch)           |
  +---+--------+--------+--------+------+
      |access  |access  |access  |access
     pc1      pc2      pc3      pc4
    VLAN 10  VLAN 10  VLAN 20  VLAN 20
```

## Run

```bash
sudo -i
./vlan-lab.sh phase1 && ./vlan-lab.sh test   # flat network: everyone pings everyone
./vlan-lab.sh phase2 && ./vlan-lab.sh test   # VLANs: pc1 -> pc3 fails, same subnet
./vlan-lab.sh phase3 && ./vlan-lab.sh test   # router-on-a-stick: pc1 -> pc3 works, TTL 63
./vlan-lab.sh capture                        # 802.1Q tags on the trunk
./vlan-lab.sh down
```

Requirements: Linux with `iproute2`; `tcpdump` for the capture step. If Docker is installed and pings fail in phase 1, run `sysctl -w net.bridge.bridge-nf-call-iptables=0` (Docker's `br_netfilter` sends bridged frames through iptables).

## What each phase shows

| Phase | Setup | Result | Lesson |
|---|---|---|---|
| 1 | All ports in VLAN 1, one subnet | All pings succeed | A default switch is one broadcast domain |
| 2 | pc1/pc2 in VLAN 10, pc3/pc4 in VLAN 20, **same subnet** | pc1 → pc2 works, pc1 → pc3 fails, ARP for pc3 is `FAILED` | A VLAN is a separate broadcast domain; ARP never crosses it, so isolation happens at L2 |
| 3 | One subnet per VLAN, router with 802.1Q subinterfaces on a trunk | pc1 → pc3 works, `ttl=63` | Traffic between VLANs must be routed; each router hop decrements TTL |
| Capture | `tcpdump -e` on the trunk | Each packet appears as `vlan 10` then `vlan 20`, 4 bytes longer (802.1Q tag) | MAC addresses change on every hop; IP addresses stay the same end to end |

## Cisco equivalents

| Linux | Cisco IOS |
|---|---|
| `bridge vlan add dev pc1 vid 10 pvid untagged` | `switchport mode access` / `switchport access vlan 10` |
| `bridge vlan add dev r1 vid 10` (tagged) | `switchport mode trunk` / `switchport trunk allowed vlan 10,20` |
| `ip link add link eth0 name eth0.10 type vlan id 10` | `interface g0/0.10` / `encapsulation dot1Q 10` |
| `ip route add default via 192.168.10.254` | `ip default-gateway` on the host |

## Next steps

- Add a firewall (nftables) on `r1`: allow only selected traffic from VLAN 20 to VLAN 10.
- Replicate the same topology in Cisco IOS (Packet Tracer / EVE-NG) and compare.
