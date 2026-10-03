# Lab 04 – Static routing across three routers

Three Linux routers (network namespaces) in a chain. With only connected routes nothing beyond the first router works; static routes are added step by step until pc1 reaches pc3 – in both directions.

## Topology

     pc1 ------ r1 ------------ r2 ------------ r3 ------ pc3
        10.0.1.0/24  10.0.12.0/30   10.0.23.0/30  10.0.3.0/24
     .10      .1  .1          .2  .1          .2  .1      .10

Router-to-router links use /30: block of 4 addresses, 2 usable hosts – exactly one per router.

## Run

    sudo -i
    ./routing-lab.sh up       # connected routes only
    ./routing-lab.sh test     # see which pings fail and HOW they fail
    ./routing-lab.sh return   # add r2's return route only
    ./routing-lab.sh test
    ./routing-lab.sh routes   # all routes for pc1 <-> pc3
    ./routing-lab.sh test
    ./routing-lab.sh tables
    ./routing-lab.sh down

## Results

| Test | Connected routes only | + r2 return route | All static routes |
|---|---|---|---|
| pc1 → r1 | OK (ttl 64) | OK | OK |
| pc1 → r2 (10.0.12.2) | **TIMEOUT** – request arrives, r2 has no route back to 10.0.1.0/24 | OK (ttl 63) | OK |
| pc1 → pc3 | **UNREACHABLE from 10.0.1.1** – r1 has no route to 10.0.3.0/24 | UNREACHABLE | OK (**ttl 61** = 3 routers) |

## Static routes

    r1: 10.0.3.0/24 via 10.0.12.2
    r2: 10.0.1.0/24 via 10.0.12.1
        10.0.3.0/24 via 10.0.23.2
    r3: 10.0.1.0/24 via 10.0.23.1

The script also adds the remaining router-to-router networks so every router can reach every interface.

## What I learned

1. **A router only knows connected networks** until routes are added (statically or by a routing protocol). No route = packet dropped.
2. **Routing must work in both directions.** The request to r2 arrived, but the reply died because r2 had no route back to pc1's network. Missing return routes are the most common real-world static routing mistake.
3. **Two failure symptoms, two meanings.** *Timeout* (silence) often means a missing return path or a firewall. *Destination Net Unreachable from X* means router X has no route to the destination – and tells you exactly which router.
4. **Next hop = the neighbour's address on the shared link** – a single IP, no mask. Reading a route as a sentence helps: "to reach network X, hand the packet to neighbour Y".
5. **TTL counts routers.** 64 − 3 = 61 for three routers in the path.

## Cisco equivalents

| This lab | Cisco IOS |
|---|---|
| `ip route add 10.0.3.0/24 via 10.0.12.2` | `ip route 10.0.3.0 255.255.255.0 10.0.12.2` |
| `ip route add default via 10.0.1.1` | `ip route 0.0.0.0 0.0.0.0 10.0.1.1` |
| `ip route` (table) | `show ip route` (C = connected, S = static) |
| `sysctl net.ipv4.ip_forward=1` | routing enabled by default (`ip routing`) |

## Next steps

- Replace static routes with OSPF (FRRouting) and compare.
- Add a second path between r1 and r3 and test failover with floating static routes (administrative distance).
