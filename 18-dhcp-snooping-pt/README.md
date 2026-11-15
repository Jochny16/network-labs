# Lab 18: DHCP snooping in Packet Tracer (rogue DHCP server)

Follow-up to lab 17 (DHCP relay). A rogue DHCP server is plugged into the access switch in the same VLAN as the client. Without protection the client takes the rogue's lease and its fake gateway. With DHCP snooping the switch drops server messages (Offer/Ack) that arrive on untrusted ports, so only the legitimate server behind the router can answer. The switch also learns a binding table (MAC - IP - VLAN - port) from the Acks it lets through.

File: dhcp-snooping.pkt (copy of lab 17 + Rogue server).

## Topology

    PC1 (DHCP client)
     | Fa0/1 (untrusted)
    Switch0 (2960) --- Gi0/1 (TRUSTED) --- G0/0 Router1 (2911) G0/1 --- Server0
     | Fa0/3 (untrusted)                  192.168.10.1                    192.168.20.10
    Rogue (Server-PT)                     ip helper-address 192.168.20.10  pool LAN10
    192.168.10.200
    pool start .100, gateway/DNS .200

    VLAN 1, client LAN 192.168.10.0/24, server LAN 192.168.20.0/24

## Run

Step 1 - attack without protection. Add Server-PT "Rogue" on Switch0 Fa0/3, static IP 192.168.10.200, DHCP service on, pool start 192.168.10.100, default gateway and DNS 192.168.10.200. On PC1: Desktop -> IP Configuration -> Static, then DHCP again.

Step 2 - enable DHCP snooping on Switch0:

    enable
    configure terminal
    ip dhcp snooping
    ip dhcp snooping vlan 1
    no ip dhcp snooping information option
    interface GigabitEthernet0/1
     ip dhcp snooping trust
    end

Renew the lease on PC1 again (Static -> DHCP).

Step 3 - check:

    Switch0# show ip dhcp snooping
    Switch0# show ip dhcp snooping binding
    PC1 C:\> ipconfig /all

## Results

| Test | Result |
|---|---|
| No snooping, two DHCP servers | PC1 got 192.168.10.100 with gateway 192.168.10.200 - the rogue won (its Offer arrives first, it is local, DHCP has no authentication) |
| Snooping on, Gi0/1 trusted | PC1 got gateway 192.168.10.1, DNS 0.0.0.0, DHCP Server 192.168.20.10 - the legitimate server via the relay |
| show ip dhcp snooping binding | 1 entry: 00:0D:BD:6A:17:15, 192.168.10.100, lease 86400, type dhcp-snooping, VLAN 1, Fa0/1 |
| Binding after reopening the .pkt | Rebuilt automatically - PC1 renewed its lease on load and the Ack was snooped |

Predictions: 1/2 (predicted that two DHCP servers would conflict and the client would fall back to APIPA; servers do not coordinate, the client simply takes the first Offer).

## What I learned

1. **DHCP has no authentication.** Any host can answer a Discover. The client takes the first Offer, and a rogue in the same LAN is almost always faster than a server behind a relay.
2. **The attack is about the gateway, not the address.** The rogue hands out its own IP as default gateway and DNS, which puts it in the middle of all traffic (man-in-the-middle) - the IP address itself can look perfectly normal.
3. **Snooping filters server messages, not clients.** On untrusted ports the switch drops Offer and Ack (and other server-to-client messages). Discover and Request from clients pass normally.
4. **Trust only the uplink towards the real server.** Every port is untrusted by default; here only Gi0/1 (towards the router with ip helper-address) is trusted.
5. **The binding table is learned, not configured.** The switch fills it from Acks it forwards. It holds MAC, IP, lease, VLAN and port of each client. Servers do not appear in it - they give addresses, they do not receive them.
6. **The binding table is the base for further features.** Dynamic ARP Inspection (DAI) and IP Source Guard check traffic against it.
7. **Option 82 and "no ip dhcp snooping information option".** By default the switch inserts option 82 with giaddr 0.0.0.0, and the relay router drops such packets. Disabling the insertion keeps the relay working in this lab.

## Cisco equivalents / production vs lab

- Production: enable snooping per VLAN on every access switch, trust only uplinks and ports towards real DHCP servers.
- Add ip dhcp snooping limit rate on access ports to stop DHCP starvation (pool exhaustion, see lab 06).
- Store the binding table (ip dhcp snooping database) so it survives a switch reload.
- Linux equivalent from lab 06: rogue server detection in namespaces; on Linux bridges there is no built-in snooping, it needs nftables/ebtables rules.

## Next steps

- Dynamic ARP Inspection using the binding table.
- Port security part 2: errdisable recovery, maximum 2.
- Option 82 with a relay that accepts it (ip dhcp relay information trust-all).
