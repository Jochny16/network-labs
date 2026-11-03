# Lab 15: DROP vs REJECT - what the client really sees

A firewall can block a TCP connection silently (DROP) or answer with a refusal
(REJECT with a TCP reset or an ICMP error). The client sees something different
in each case, and an attacker or a SOC analyst can tell them apart. This lab
puts a real server behind four nftables rules plus one closed port and probes
each from a client while tcpdump watches the wire.

## Topology

    +-----------+  10.0.15.0/30   +-----------------------------+
    |   pc1     |srv           pc1|            srv              |
    | 10.0.15.1 |-----------------| 10.0.15.2                   |
    +-----------+                 | python3 http.server on      |
                                  |   8080 8081 8082 8083       |
                                  | nftables table ip lab15:    |
                                  |   8080 -> accept (baseline) |
                                  |   8081 -> drop              |
                                  |   8082 -> reject tcp reset  |
                                  |   8083 -> reject icmp       |
                                  |           admin-prohibited  |
                                  |   8084 -> no rule, NO app   |
                                  +-----------------------------+

A server listens on 8080-8083, so every failure on those ports comes from the
firewall, not from the application.

## Run

    sudo -i
    cd /home/janas/network-labs/15-drop-vs-reject
    ./drop-reject-lab.sh up
    ./drop-reject-lab.sh probe 8081     # result, time and packets on pc1
    ./drop-reject-lab.sh test           # one line per port
    ./drop-reject-lab.sh counters       # nftables counters on srv
    ./drop-reject-lab.sh down

Requires: iproute2, nftables, python3, tcpdump.

## Results

| Port | Rule on srv | Client error | Time | Packets on pc1 |
|---|---|---|---|---|
| 8080 | accept | connected | 0.00 s | SYN, SYN-ACK, ACK, then FIN close |
| 8081 | drop | timeout | 5.01 s | 5 x SYN with the same seq, no answer |
| 8082 | reject with tcp reset | Connection refused | 0.00 s | SYN, RST-ACK (ack = seq + 1) |
| 8083 | reject with icmp admin-prohibited | No route to host | 0.00 s | SYN, ICMP host unreachable - admin prohibited filter |
| 8084 | no rule, no application | Connection refused | 0.00 s | SYN, RST-ACK from the kernel |

## What I learned

1. **DROP means silence.** The client cannot tell a dropped packet from a lost
   one, so it retransmits the same SYN (same sequence number) until its timeout.
   A port scanner reports it as "filtered" and has to wait.
2. **SYN retransmits were 1 s apart, not 1-2-4 s.** Kernel 6.x uses
   net.ipv4.tcp_syn_linear_timeouts (default 4): the first retransmits are
   linear, exponential backoff starts after them.
3. **REJECT with tcp reset looks exactly like a closed port.** Ports 8082 and
   8084 produced identical traffic. The kernel itself answers a SYN to a port
   with no socket with RST - "nobody listening" does not mean "no answer".
4. **A valid RST acknowledges the SYN.** The RST-ACK carried ack = SYN seq + 1;
   that is how the client knows the reset belongs to its connection.
5. **The error text can mislead.** ICMP admin-prohibited (type 3 code 13) is
   reported as "No route to host" although a route exists. The ICMP message
   carries a copy of the original IP header and part of the TCP header, which
   lets the kernel match it to the right socket. Only tcpdump shows the real
   cause.
6. **Timeout vs refused tells you where to look.** Timeout: something drops
   silently (firewall, dead host, missing return route). Refused: the host is
   reachable and answered, the service or a REJECT rule said no.

## Cisco and production equivalents

| Here (nftables) | Cisco IOS / other |
|---|---|
| drop | ACL deny - packet dropped |
| reject with icmp admin-prohibited | ACL deny on a router sends ICMP unreachable "administratively prohibited" (code 13) unless no ip unreachables is set on the interface |
| reject with tcp reset | iptables -j REJECT --reject-with tcp-reset, ASA/firewall "reset" action |
| icmp rate limit | ip icmp rate-limit unreachable |

Production choice: DROP on the internet edge (slows scans, gives nothing
away), REJECT inside the network (users and applications fail fast instead of
waiting for a timeout, troubleshooting is easier).

## Next steps

- Same lab for UDP: no answer vs ICMP port unreachable.
- nmap -sS against all five ports: open / filtered / closed.
- Cisco ACL deny with and without no ip unreachables in Packet Tracer.
