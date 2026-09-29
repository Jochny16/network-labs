# network-labs

Hands-on networking labs from my CCNA preparation and master's studies in cybersecurity.
Each lab is reproducible on a plain Linux machine or in my Proxmox homelab, with a script and a write-up of what it shows.

| # | Lab | Topics | Tools |
|---|---|---|---|
| 01 | [VLAN + router-on-a-stick](01-vlan-lab/) | VLANs, access/trunk ports, 802.1Q, inter-VLAN routing, ARP, TTL | Linux bridge, network namespaces, tcpdump |
| 02 | [Stateful firewall between VLANs](02-vlan-firewall/) | Default deny, stateful inspection, least privilege, nftables | nftables, conntrack, curl |

## Planned

- 03: OSPF: single and multi-area (FRRouting / Cisco IOS in EVE-NG)
- 04: NAT and DHCP
- 05: Network automation with Ansible

## Environment

Debian 13, Proxmox VE 9 homelab, EVE-NG / GNS3 for Cisco images.
