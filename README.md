# network-labs

Hands-on networking labs from my CCNA preparation and master's studies in cybersecurity.
Each lab is reproducible on a plain Linux machine or in my Proxmox homelab, with a script and a write-up of what it shows.

| # | Lab | Topics | Tools |
|---|---|---|---|
| 01 | [VLAN + router-on-a-stick](01-vlan-lab/) | VLANs, access/trunk ports, 802.1Q, inter-VLAN routing, ARP, TTL | Linux bridge, network namespaces, tcpdump |
| 02 | [Stateful firewall between VLANs](02-vlan-firewall/) | Default deny, stateful inspection, least privilege, nftables | nftables, conntrack, curl |
| 03 | [Spanning Tree (STP)](03-stp/) | Root bridge election, port roles, blocking, failover, convergence | Linux bridge STP |
| 04 | [Static routing](04-static-routing/) | Connected vs static routes, next hop, return path, timeout vs unreachable, TTL | Linux namespaces, iproute2 |
| 05 | [OSPF with FRRouting](05-ospf/) | OSPF area 0, neighbours, LSA/SPF, passive interface, cost, failover | FRRouting, network namespaces |
| 06 | [DHCP + rogue server](06-dhcp/) | DORA, leases, pool exhaustion, rogue DHCP (MITM), DHCP snooping | dnsmasq, dhclient, tcpdump |
| 07 | [Ansible: one playbook, three servers](07-ansible/) | Inventory, playbooks, idempotency, configuration drift, templates, handlers | Ansible, Docker |
| 08 | [Kubernetes basics](08-kubernetes/) | Pods, Deployment, Service, self-healing, load balancing, readinessProbe, rolling update | k3s, kubectl |
| 09 | [NAT, PAT, port forwarding](09-nat/) | Source NAT/masquerade, PAT ports, NAT table, DNAT, RFC 1918 | nftables, conntrack, tcpdump |
| 10 | [ACLs: standard vs extended](10-acl/) | First match, implicit deny, ACL placement, stateless ACLs, hit counters | nftables |
| 11 | [Wazuh SIEM: SSH brute-force, FIM, alert triage](11-wazuh-siem/) | SIEM, log correlation, agent enrollment, rule levels, FIM, rootcheck tuning, false positives | Wazuh 4.14, Proxmox LXC |
| 11b | [Wazuh FIM](11b-wazuh-fim/) | File integrity monitoring, realtime vs scheduled, baseline gap, rules 550/553/554 | Wazuh, Proxmox |

## Planned

- 12: Windows Server, Active Directory and GPO (Proxmox)

## Environment

Debian 13, Proxmox VE 9 homelab, EVE-NG / GNS3 for Cisco images.
