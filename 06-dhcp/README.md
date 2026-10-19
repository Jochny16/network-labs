# Lab 06 – DHCP: DORA, pool exhaustion and a rogue DHCP server

A DHCP server (dnsmasq) on r1 hands out addresses to three PCs on one LAN. The pool is deliberately tiny (2 addresses) to show what happens when it runs out – and how an attacker uses exactly that moment to start a rogue DHCP server and become everyone's gateway (man-in-the-middle).

## Topology

                 r1 (br0 192.168.10.1/24, DHCP server)
               /   |    \      \
            pc1   pc2   pc3    evil (rogue DHCP server, 192.168.10.66)

    Legit pool: 192.168.10.100 - 192.168.10.101, gateway 192.168.10.1
    Rogue pool: 192.168.10.200 - 192.168.10.210, gateway 192.168.10.66

## Run

    sudo apt install -y dnsmasq-base isc-dhcp-client tcpdump
    sudo ./dhcp-lab.sh up
    sudo ./dhcp-lab.sh lease pc1     # DORA, captured with tcpdump on r1
    sudo ./dhcp-lab.sh lease pc2     # pool is now full
    sudo ./dhcp-lab.sh lease pc3     # no offer
    sudo ./dhcp-lab.sh rogue         # attacker starts a DHCP server
    sudo ./dhcp-lab.sh lease pc3     # pc3 gets the attacker as gateway
    sudo ./dhcp-lab.sh status
    sudo ./dhcp-lab.sh down

## Results

DORA for pc1, as seen on the wire:

    Discover  0.0.0.0.68 > 255.255.255.255.67
    Offer     192.168.10.1.67 > 192.168.10.100.68  your-ip 192.168.10.100
    Request   0.0.0.0.68 > 255.255.255.255.67
    ACK       192.168.10.1.67 > 192.168.10.100.68  your-ip 192.168.10.100

| Step | Observation |
|---|---|
| pc1, pc2 lease | .100 and .101 with gateway .1 – the pool is full |
| pc3 lease | Only repeated Discovers, **no Offer** – the server never invents addresses or steals active leases |
| Rogue server + pc3 lease | Offer and ACK from **192.168.10.66**, pc3 gets 192.168.10.209 with **gateway .66** |
| Same capture | The legit server sends a **NACK** (it saw the broadcast Request for an address it does not own) – too late, the client already accepted the rogue ACK |

Final state:

    pc1  192.168.10.100/24  gw 192.168.10.1
    pc2  192.168.10.101/24  gw 192.168.10.1
    pc3  192.168.10.209/24  gw 192.168.10.66   <- all traffic goes through the attacker

## What I learned

1. **DORA** – Discover, Offer, Request, Ack. DHCP gives the whole network config: address, mask, gateway, DNS, lease time.
2. **Discover goes from 0.0.0.0 to 255.255.255.255** – the client has no address yet and does not know any server, so it broadcasts. UDP ports: client 68, server 67.
3. **Request is a broadcast too** – several servers may have made offers; the broadcast tells all of them which offer was accepted, so the others release theirs. In this lab it also let the legit server see the request and send a NACK.
4. **Empty pool = silence.** The client gets no address. On Windows it then picks a 169.254.x.x (APIPA) address – a quick sign that DHCP did not answer.
5. **DHCP has no authentication.** Any device on the LAN can answer Discovers. A rogue server hands out its own gateway and DNS: **man-in-the-middle** (sniffing, fake DNS, phishing). Typical attack chain: **DHCP starvation** (exhaust the pool with fake MACs) → **rogue server**.
6. **Defence: DHCP snooping** on the switch. Ports towards the real server are *trusted*; user ports are *untrusted* – Offers/ACKs arriving on them are dropped. Rate-limiting DHCP on user ports and port security stop starvation. The snooping binding table is also used by Dynamic ARP Inspection and IP Source Guard.

## Cisco equivalents

| This lab | Cisco IOS |
|---|---|
| dnsmasq `--dhcp-range=...100,...101` | `ip dhcp pool LAN` / `network 192.168.10.0 255.255.255.0` + `ip dhcp excluded-address` |
| `--dhcp-option=option:router,...` | `default-router 192.168.10.1` (in the pool) |
| `--dhcp-option=option:dns-server,...` | `dns-server 192.168.10.1` |
| r1 lease file | `show ip dhcp binding` |
| client `dhclient` | `ip address dhcp` (on an interface) |
| server in another subnet | `ip helper-address <server>` (DHCP relay) |
| defence against the rogue server | `ip dhcp snooping`, `ip dhcp snooping vlan 10`, `ip dhcp snooping trust` (uplink), `ip dhcp snooping limit rate 10` (user ports) |

## Next steps

- DHCP relay: put the server in another subnet behind a router (`ip helper-address`).
- Build DHCP snooping in Packet Tracer and show the rogue Offer being dropped.
- Simulate starvation with many fake MACs (e.g. scapy) instead of a tiny pool.
