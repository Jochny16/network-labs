# Lab 17: DHCP relay in Packet Tracer (ip helper-address)

The Cisco IOS version of lab 14. A client and a DHCP server sit in two different subnets, separated by a router. Without a relay the client never gets an address. With `ip helper-address` on the client-facing interface, the router turns the broadcast into a unicast packet for the server and the client gets a lease from the correct pool.

Every step was watched packet by packet in Packet Tracer Simulation mode, filtered to DHCP only.

## Topology

    PC1 --- Switch0 (2960) --- Router1 (2911) --- Server0
        192.168.10.0/24      G0/0  |  G0/1     192.168.20.0/24
                           .10.1      .20.1    .20.10

| Device | Interface | Address |
|---|---|---|
| PC1 | Fa0 | DHCP client |
| Router1 | G0/0 | 192.168.10.1/24 (client side) |
| Router1 | G0/1 | 192.168.20.1/24 (server side) |
| Server0 | Fa0 | 192.168.20.10/24, gateway 192.168.20.1 |

## Run

Router1:

    enable
    conf t
    no ip domain-lookup
    hostname R1
    interface g0/0
     ip address 192.168.10.1 255.255.255.0
     no shutdown
    interface g0/1
     ip address 192.168.20.1 255.255.255.0
     no shutdown
    end

Server0:

    Desktop > IP Configuration > Static
      IP 192.168.20.10, mask 255.255.255.0, gateway 192.168.20.1
    Services > DHCP > On, then Add a new pool:
      Pool Name LAN10, Default Gateway 192.168.10.1,
      Start IP 192.168.10.100, mask 255.255.255.0, max users 50

The default serverPool stays in place. The server picks a pool by the subnet the request comes from.

Test 1 (no relay): PC1 > Desktop > IP Configuration > DHCP, watch in Simulation mode.

Enable the relay on the client-facing interface:

    conf t
    interface g0/0
     ip helper-address 192.168.20.10
    end

Test 2 (relay): PC1 Static, then DHCP again, watch the Discover until it reaches Server0.

The saved topology is in `dhcp-relay-pt.pkt`.

## Results

| Test | What Simulation mode showed | Result on PC1 |
|---|---|---|
| No relay | Discover at Router1: src 0.0.0.0, dst 255.255.255.255, UDP 68 to 67. Out Layers empty, the router drops it | No lease (APIPA 169.254.x.x after timeout) |
| Relay on G0/0 | Discover at Server0: src 192.168.10.1, dst 192.168.20.10 (unicast), UDP 68 to 67 | 192.168.10.100/24, gateway 192.168.10.1 (pool LAN10) |

Side note: Switch0 also sent DTP frames on its access ports during the capture (dynamic ports from lab 16). They are unrelated to DHCP and were filtered out.

## What I learned

1. **Discover is a limited broadcast.** The client has no IP yet (src 0.0.0.0) and does not know where the server is (dst 255.255.255.255). Seen directly in Layer 3 of the PDU.
2. **Routers do not forward 255.255.255.255.** Router1 received the Discover on G0/0 and sent nothing out (empty Out Layers). Without a relay, DHCP only works inside one broadcast domain.
3. **ip helper-address goes on the interface facing the client.** That is where the broadcast arrives. The address in the command is the DHCP server.
4. **The relay turns the broadcast into a unicast.** At the server the packet had dst 192.168.20.10, not 255.255.255.255.
5. **giaddr selects the pool.** The relay writes the address of the client-facing interface (192.168.10.1) into giaddr. Packet Tracer does not show the field, but the proof is the lease: PC1 got 192.168.10.100 from LAN10, not an address from serverPool (192.168.20.0/24). My prediction said giaddr = 192.168.20.1, which was wrong.
6. **The server needs a route back to the client subnet.** Here it is the server's default gateway 192.168.20.1. In lab 14 the missing return route broke the whole exchange.
7. **In Simulation mode time stands still.** PC1 stays empty while waiting; switch to Realtime to see the timeout or the lease.

## Linux (lab 14) vs Cisco

| | Lab 14 (Linux namespaces) | Lab 17 (Cisco IOS) |
|---|---|---|
| Relay | dnsmasq --dhcp-relay=LOCAL,SERVER | ip helper-address SERVER on the client-facing interface |
| Server | dnsmasq with a dhcp-range for the client subnet | Server-PT pool LAN10 |
| Visibility | tcpdump -ni any on r1 | Simulation mode, PDU details per layer |
| Return path | Explicit route on the server namespace | Default gateway on Server0 |

In production `ip helper-address` also forwards several other UDP broadcasts by default (for example TFTP, DNS, NetBIOS), which can be limited with `ip forward-protocol`.

## Next steps

- DHCP snooping on Switch0 with the uplink to the router as the trusted port.
- Option 82 (relay agent information).
- Lab 18: Windows Server, Active Directory and GPO on Proxmox.
