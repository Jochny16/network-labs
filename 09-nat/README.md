# Lab 09 – NAT, PAT and port forwarding (nftables)

A Linux router (r1) connects a private LAN to a "public" network where a web server (srv) lives. Without NAT the private hosts cannot talk to srv at all; with PAT they all share r1's single public address, told apart by ports; with port forwarding srv can reach a web server inside the LAN.

## Topology

    pc1 192.168.1.10 --+
                       +-- lan [ r1 ] wan ---------- srv 203.0.113.10
    pc2 192.168.1.20 --+  .1         203.0.113.1      "internet" web server
         private LAN (192.168.1.0/24)          public side (203.0.113.0/24, TEST-NET-3)

srv has **no route** to 192.168.1.0/24 – like any server on the internet, it cannot reach private addresses.

## Run

    sudo ./nat-lab.sh up        # topology + web servers on srv and pc1
    sudo ./nat-lab.sh test      # pc1 -> srv without NAT
    sudo ./nat-lab.sh nat       # masquerade (PAT) on r1's wan
    sudo ./nat-lab.sh test
    sudo ./nat-lab.sh pat       # pc1 and pc2 at once, both from source port 40000
    sudo ./nat-lab.sh rules     # nftables rules + NAT table (conntrack)
    sudo ./nat-lab.sh forward   # 203.0.113.1:8080 -> pc1:80
    sudo ./nat-lab.sh down

## Results

| Step | Observation |
|---|---|
| No NAT | ping **TIMEOUT**, curl no answer – the request reaches srv, but srv has no route back to 192.168.1.10 |
| PAT on | ping OK, curl OK – srv's log shows the client as **203.0.113.1** (r1), never 192.168.1.10 |
| pc1 + pc2 from port 40000 at once | srv sees `203.0.113.1.40000` and `203.0.113.1.25809` – r1 **rewrote the port** of one connection to keep them apart |
| NAT table | `src=192.168.1.10 sport=40000 … dst=203.0.113.1 dport=25809` – r1 maps every inside IP:port to an outside port |
| Port forwarding | srv -> 203.0.113.1:8080 reaches **pc1:80**; pc1's log shows the client as **203.0.113.10** (DNAT changes only the destination) |

r1's rules:

    table ip nat {
      chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        oifname "wan" ip saddr 192.168.1.0/24 masquerade
      }
      chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        iifname "wan" tcp dport 8080 dnat to 192.168.1.10:80
      }
    }

## What I learned

1. **Private addresses (RFC 1918) are not routed on the internet.** Without NAT the packet arrives, but the reply has nowhere to go – the same "missing return path" timeout as in lab 04.
2. **Source NAT / masquerade** replaces the private source address with the router's public one on the way out, and reverses it for the replies.
3. **PAT (NAT overload)** lets many hosts share one public IP. Connections are told apart by **port**; if two hosts use the same source port, the router changes one of them.
4. **The NAT table (conntrack)** stores each mapping: inside IP:port <-> outside IP:port. Replies are matched against it.
5. **Port forwarding (destination NAT)** maps public IP:port to an inside host:port. Only the destination is rewritten – the inside server sees the real client address.
6. **NAT is not a firewall**, but it hides the LAN: nothing outside can start a connection inward unless a port is forwarded. Every forwarded port exposes an internal host – forward only what is needed.

## Cisco equivalents

| This lab (nftables) | Cisco IOS |
|---|---|
| `lan` / `wan` interfaces | `ip nat inside` / `ip nat outside` on the interfaces |
| `ip saddr 192.168.1.0/24 masquerade` | `access-list 1 permit 192.168.1.0 0.0.0.255` + `ip nat inside source list 1 interface g0/1 overload` |
| `dnat to 192.168.1.10:80` (port 8080) | `ip nat inside source static tcp 192.168.1.10 80 203.0.113.1 8080` |
| NAT table (conntrack) | `show ip nat translations` |
| — | `show ip nat statistics`, `clear ip nat translation *` |

Terms: inside local = 192.168.1.10, inside global = 203.0.113.1, outside global = 203.0.113.10.

## Next steps

- Static 1:1 NAT and a NAT pool; the same lab in Packet Tracer with `show ip nat translations`.
- Combine with lab 02: a stateful firewall in front of the forwarded port.
- IPv6: why it needs no NAT.
