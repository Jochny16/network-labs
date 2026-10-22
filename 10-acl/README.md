# Lab 10 – ACLs: standard vs extended, rule order, implicit deny

A Linux router (r1) filters traffic between three networks with Cisco-style access lists built in nftables: an **extended ACL** inbound on the users interface and a **standard ACL** outbound towards the servers. The lab shows the rules every CCNA question is about – first match wins, the invisible deny at the end, where to place each ACL type, and that ACLs are stateless.

## Topology

    pc1 10.0.10.10 (admin) --+
    pc2 10.0.10.20 (user)  --+-- users   [    ]  servers --- srv 10.0.20.10  (web :80, ssh :22)
                                   .1    [ r1 ]  .1
    guest 10.0.30.10 ----------- guests  [    ]
                                   .1

Policy: users may use the web server and ping srv; only pc1 may use SSH; guests may not reach the servers network but may reach users.

## Run

    sudo ./acl-lab.sh up
    sudo ./acl-lab.sh test         # access matrix
    sudo ./acl-lab.sh acl-wrong    # broad permit placed first
    sudo ./acl-lab.sh counters     # hit counts per rule ("show access-lists")
    sudo ./acl-lab.sh acl          # correct order
    sudo ./acl-lab.sh acl-final    # + permit users -> guests (return traffic)
    sudo ./acl-lab.sh down

## The ACLs (final version)

    USERS_IN  - extended, inbound on "users" (near the source)
      10 permit tcp host 10.0.10.10 -> host 10.0.20.10 port 22
      20 deny   tcp any            -> host 10.0.20.10 port 22
      30 permit tcp any            -> host 10.0.20.10 port 80
      40 permit icmp echo          -> host 10.0.20.10
      50 permit ip  any            -> 10.0.30.0/24
         deny   any                (implicit)

    NO_GUESTS - standard, outbound on "servers" (near the destination)
      10 deny   10.0.30.0/24
      20 permit any

## Results

| Step | pc2 ssh :22 | guest -> srv | guest -> pc1 | Counters |
|---|---|---|---|---|
| No ACLs | ok | ok | ok | – |
| `acl-wrong` (broad permit first) | **ok – policy broken** | blocked | blocked | rule 10: 14 matches, rules 20–40: **0** (dead rules) |
| `acl` (specific rules first) | **blocked** | blocked | **blocked** | implicit deny: 1 match = pc1's reply to guest |
| `acl-final` (+ rule 50) | blocked | blocked | **ok** | rule 50: 1 match, implicit deny: 0 |

## What I learned

1. **First match wins.** A broad permit placed too high makes every rule below it dead – the counters show 0 matches. Specific rules go first, general rules last.
2. **Implicit deny.** Anything not permitted is dropped by an invisible last rule. Its counter is the place to look when "something just doesn't work".
3. **Standard ACL = source only → place it near the destination**, otherwise it blocks the source from everything. **Extended ACL = source, destination, protocol, port → place it near the source**, so unwanted traffic is dropped before it crosses the network.
4. **ACLs are stateless.** The reply from pc1 to guest entered the users interface and was dropped by USERS_IN – return traffic must be permitted explicitly (`established` on Cisco for TCP). A stateful firewall (lab 02, `ct state established,related`) handles this automatically.
5. **Counters (`show access-lists`) are the main troubleshooting tool** – they show which rule actually matched.
6. **Direction matters:** an ACL is applied to one interface in one direction (in or out) and only sees that traffic.

## Cisco equivalents

    ip access-list extended USERS_IN
     10 permit tcp host 10.0.10.10 host 10.0.20.10 eq 22
     20 deny   tcp any host 10.0.20.10 eq 22
     30 permit tcp any host 10.0.20.10 eq 80
     40 permit icmp any host 10.0.20.10 echo
     50 permit ip any 10.0.30.0 0.0.0.255
    interface g0/0
     ip access-group USERS_IN in

    ip access-list standard NO_GUESTS
     10 deny   10.0.30.0 0.0.0.255
     20 permit any
    interface g0/2
     ip access-group NO_GUESTS out

    show access-lists        ! hit counts per line
    show ip interface g0/0   ! which ACL is applied, in which direction

Numbered ACLs: standard 1–99 and 1300–1999, extended 100–199 and 2000–2699.

## Next steps

- The same ACLs in Packet Tracer, including `established` instead of rule 50.
- Restrict router management (VTY lines) with `access-class`.
- Compare with lab 02: stateless ACL vs stateful firewall for the same policy.
