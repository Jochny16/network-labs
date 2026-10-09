# Lab 05 – OSPF with FRRouting

Three Linux routers (network namespaces) in a triangle, each running FRRouting (zebra + ospfd). Instead of writing static routes, the routers discover each other, exchange link-state information and calculate the best paths themselves. When the direct link fails, traffic moves to the backup path without losing a ping.

## Topology

                    r2
        10.0.12.0/30   10.0.23.0/30
              /            \
     pc1 --- r1 ------------ r3 --- pc3
     10.0.1.0/24  10.0.13.0/30  10.0.3.0/24

| Router | Router ID | Interfaces |
|---|---|---|
| r1 | 1.1.1.1 | lan 10.0.1.1/24, to-r2 10.0.12.1/30, to-r3 10.0.13.1/30 |
| r2 | 2.2.2.2 | to-r1 10.0.12.2/30, to-r3 10.0.23.1/30 |
| r3 | 3.3.3.3 | to-r2 10.0.23.2/30, to-r1 10.0.13.2/30, lan 10.0.3.1/24 |

## Run

    sudo apt install -y frr
    sudo ./ospf-lab.sh up        # topology + FRR, no OSPF yet
    sudo ./ospf-lab.sh test      # pc1 -> pc3 fails (connected routes only)
    sudo vtysh -N r1             # configure r1 by hand (see below), or:
    sudo ./ospf-lab.sh ospf      # configure all three routers
    sudo ./ospf-lab.sh status    # neighbours + routes learned via OSPF
    sudo ./ospf-lab.sh test
    sudo ./ospf-lab.sh fail      # cut r1-r3, ping during reconvergence
    sudo ./ospf-lab.sh restore
    sudo ./ospf-lab.sh down

## Router configuration (r1)

    router ospf
     ospf router-id 1.1.1.1
     network 10.0.1.0/24 area 0
     network 10.0.12.0/30 area 0
     network 10.0.13.0/30 area 0
     passive-interface lan
    !
    interface to-r2
     ip ospf network point-to-point
     ip ospf hello-interval 1
     ip ospf dead-interval 4
    !
    interface to-r3
     ip ospf network point-to-point
     ip ospf hello-interval 1
     ip ospf dead-interval 4

## Results

| Step | Observation |
|---|---|
| Before OSPF | pc1 -> pc3 fails – routers know only connected networks |
| OSPF configured | Every router has 2 neighbours in state **Full**; remote networks appear as `proto ospf` routes |
| Normal path | pc1 -> pc3 OK, **ttl 62** (2 routers), r1 sends via 10.0.13.2 (direct link to r3) |
| r1–r3 link down | **0 pings lost**, ttl 61 (3 routers), r1 now sends via 10.0.12.2 (through r2) |
| Link restored | Back to ttl 62 via 10.0.13.2 – OSPF always picks the lowest-cost path |

## What I learned

1. **Dynamic vs static routing.** Static routes are written by hand and do not react to failures. OSPF learns the topology and recalculates routes on every change.
2. **Link-state.** Each router floods LSAs (Link-State Advertisements) describing its links. All routers in the area build the same database (LSDB) and run SPF (Dijkstra) to compute the shortest-path tree with themselves as the root.
3. **Neighbours.** Routers discover each other with hello packets. Hello/dead timers, area and network type must match, otherwise no adjacency forms. *Full* = databases are synchronised.
4. **Router ID** identifies a router in the LSDB. Set it explicitly instead of letting the router pick one from its interfaces.
5. **`network ... area 0`** enables OSPF on interfaces whose address falls into that range – it does not "advertise a route" by itself.
6. **Passive interface.** The LAN is advertised, but no hellos are sent to it – no neighbours expected there, and nobody on the LAN can form an adjacency (security).
7. **Point-to-point network type** skips the DR/BDR election (40 s wait on broadcast links), so adjacencies come up in seconds. Fast timers (hello 1 s, dead 4 s) make failure detection quick; Cisco defaults are 10/40 s.
8. **Cost decides the path.** The direct r1–r3 link has a lower total cost than the path through r2. The backup path is not blocked (unlike STP) – it is in the LSDB, just not the best, so it is not installed in the routing table until it becomes the best.
9. **TTL shows the path length.** 62 = 2 routers (direct), 61 = 3 routers (via r2).

## Cisco equivalents

| This lab (FRR) | Cisco IOS |
|---|---|
| `vtysh -N r1` | console / SSH to the router |
| `network 10.0.12.0/30 area 0` | `network 10.0.12.0 0.0.0.3 area 0` (wildcard mask) |
| `ospf router-id 1.1.1.1` | `router-id 1.1.1.1` |
| `passive-interface lan` | `passive-interface g0/0` |
| `show ip ospf neighbor` | `show ip ospf neighbor` |
| `show ip route ospf` | `show ip route ospf` (O = OSPF) |
| `ip route` with `proto ospf` | `show ip route` |

## Next steps

- Change the OSPF cost on r1's to-r3 interface (`ip ospf cost 100`) and predict the new path.
- Make both paths equal cost and observe ECMP (two next hops for one network).
- Multi-area OSPF: put pc3's LAN into area 1 with r3 as the ABR.
- Rebuild the same topology on Cisco IOS in EVE-NG / Packet Tracer.
