# Lab 14: DHCP relay between two subnets

A DHCP client in one subnet gets its address from a server in another subnet. Built step by step to see each failure on the way: no relay, relay without a return route, then a working relay.

Linux network namespaces stand in for the hosts, dnsmasq is both the DHCP server and the relay, and tcpdump shows what crosses the router.

## Topology

    pc1 (DHCP client) ------------ r1 (relay) ------------ srv (dnsmasq server)
               10.0.10.0/24                  10.0.20.0/24
    pc1: no address   r1: 10.0.10.1 | 10.0.20.1        srv: 10.0.20.2

The server has a pool for 10.0.10.0/24 (10.0.10.100-150, gateway 10.0.10.1) but no interface in that subnet. It can only be reached through the relay.

## Run

    sudo ./dhcp-relay-lab.sh up        # namespaces + DHCP server, no relay, no return route
    sudo ./dhcp-relay-lab.sh test      # step 1: no relay
    sudo ./dhcp-relay-lab.sh relay
    sudo ./dhcp-relay-lab.sh capture   # step 2: relay, but srv has no route back
    sudo ./dhcp-relay-lab.sh route
    sudo ./dhcp-relay-lab.sh capture   # step 3: working relay
    sudo ./dhcp-relay-lab.sh status
    sudo ./dhcp-relay-lab.sh down

Requirements: iproute2, dnsmasq-base, isc-dhcp-client, tcpdump.

## Results

| Step | Setup | What happened | Why |
|---|---|---|---|
| 1 | No relay | pc1 sends DHCPDISCOVER to 255.255.255.255, no lease, 0 Discovers in the server log | A router never forwards a limited broadcast, even with ip_forward on |
| 2 | Relay on r1, srv has no route to 10.0.10.0/24 | Relay logs "DHCP relay at 10.0.10.1 -> 10.0.20.2", but r1 only sends ARP "who-has 10.0.20.2 tell 10.0.10.1", ARP entry stays INCOMPLETE, server sees nothing | Linux does not answer an ARP request from a sender it has no route back to |
| 3 | Relay + return route on srv | pc1 bound to 10.0.10.116, default via 10.0.10.1, full DORA in 8 packets | Server replies to giaddr 10.0.10.1, which r1 delivers to the client |

Capture on r1 in step 3 (one Discover/Offer pair):

    pc1 B   0.0.0.0.68     > 255.255.255.255.67  Request   (broadcast from the client)
    srv Out 10.0.10.1.67   > 10.0.20.2.67        Request   (relayed as unicast)
    srv In  10.0.20.2.67   > 10.0.10.1.67        Reply     (server answers giaddr)
    pc1 Out 10.0.10.1.67   > 10.0.10.116.68      Reply     (relay delivers the offer)

## What I learned

1. **Broadcast stops at the router.** DHCPDISCOVER goes from 0.0.0.0 to 255.255.255.255 because the client has no address and knows no server or gateway. Routing only works for unicast, so without a relay the server in another subnet never sees it.
2. **The relay turns the broadcast into unicast and adds giaddr.** giaddr (10.0.10.1, the relay's address in the client subnet) tells the server which pool to use and where to send the reply.
3. **The server needs a route back to the client subnet.** Here the missing route broke the exchange earlier than expected: not at the Offer, but already at ARP, because the relay sources its packets from giaddr and srv ignored an ARP request from an unknown network. In a real network the server's default gateway usually hides this.
4. **The client sees the relay as the server.** dhclient printed "DHCPOFFER of 10.0.10.116 from 10.0.10.1". The real server address is invisible to it.
5. **Check the right capture point.** tcpdump on srv showed 0 packets; tcpdump on r1 with -i any showed where it stopped (ARP on the srv side). Capturing on the device in the middle answers "where is the packet lost".
6. **AppArmor limits dhclient.** It may write lease files only as /var/lib/dhcp/dhclient* (other paths: Permission denied).

## Cisco equivalents

| Linux lab | Cisco IOS |
|---|---|
| dnsmasq --dhcp-relay=10.0.10.1,10.0.20.2 on r1 | interface g0/0 (client side), ip helper-address 10.0.20.2 |
| Pool on the server: 10.0.10.100-150, option 3 = 10.0.10.1 | ip dhcp pool LAN10, network 10.0.10.0 255.255.255.0, default-router 10.0.10.1 |
| ip -n srv route add 10.0.10.0/24 via 10.0.20.1 | ip route 10.0.10.0 255.255.255.0 10.0.20.1 (or a default route) on the server side |
| cat /tmp/lab14-srv.leases | show ip dhcp binding |

On Cisco, ip helper-address forwards several UDP broadcast services by default (DHCP/BOOTP, TFTP, DNS, TACACS, NetBIOS, time), not only DHCP; ip forward-protocol changes the list.

## Next steps

- Two client subnets (two VLANs) served by one central server, one pool per giaddr.
- DHCP snooping with a relay (option 82).
- The same topology in Packet Tracer with ip helper-address.
