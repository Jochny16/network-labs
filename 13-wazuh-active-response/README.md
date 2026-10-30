# Lab 13: Wazuh Active Response - automatic IP block after SSH brute force

Lab 11 detected an SSH brute-force attack. This lab makes Wazuh react to it:
when the brute-force rule fires, the manager tells the agent on the victim to
drop all traffic from the attacker's IP with a firewall rule, and the agent
removes the block by itself after a timeout. Detection becomes response
(IDS -> IPS).

Like labs 11 and 12, this is a service lab on Proxmox: no script, the steps
below were run by hand and every output was checked.

## Topology

    think14 (attacker laptop)  192.168.1.109 (enp0s31f6)
          |  12x wrong SSH password
          v
    CT 121  victim  192.168.1.61   sshd + wazuh-agent 001 + iptables (nf_tables)
          |  auth log -> agent -> manager (1514/tcp)
          v
    CT 112  wazuh   192.168.1.60   manager: rule 5712 fires
          |  active response: firewall-drop 192.168.1.109
          v
    CT 121  iptables -I INPUT -s 192.168.1.109 -j DROP   (removed after 180 s)

Why attack from the laptop and not from the manager (as in lab 11)?
If the victim blocked 192.168.1.60, the agent would lose its connection to
its own SIEM.

## Run

1. Prerequisite on the agent. The built-in firewall-drop script calls
   iptables, but the Debian 13 container only had nft:

        pct exec 121 -- bash -c 'command -v iptables; command -v nft'
        pct exec 121 -- apt install -y iptables
        pct exec 121 -- iptables -V          # iptables v1.8.11 (nf_tables)
        pct exec 121 -- iptables -L INPUT -n # works in an unprivileged CT

2. Manager config (/var/ossec/etc/ossec.conf). The firewall-drop command
   is already defined. Back up, extend the whitelist, add the
   active-response block, check with diff:

        pct exec 112 -- cp /var/ossec/etc/ossec.conf /var/ossec/etc/ossec.conf.bak-lab13

    Added to the global section:

        <white_list>192.168.1.1</white_list>     <!-- gateway -->
        <white_list>192.168.1.60</white_list>    <!-- Wazuh manager -->
        <white_list>192.168.1.100</white_list>   <!-- Proxmox host -->

    Added before the log analysis section:

        <active-response>
          <command>firewall-drop</command>
          <location>local</location>
          <rules_id>5712,5763</rules_id>
          <timeout>180</timeout>
        </active-response>

    | Option | Meaning |
    |---|---|
    | command | script to run (defined in a command block) |
    | location local | run it on the agent that produced the alert |
    | rules_id 5712,5763 | SSH brute force, non-existent and existing user |
    | timeout 180 | the agent removes the block after 180 s |

        pct exec 112 -- diff /var/ossec/etc/ossec.conf.bak-lab13 /var/ossec/etc/ossec.conf
        pct exec 112 -- systemctl restart wazuh-manager
        pct exec 112 -- systemctl is-active wazuh-manager
        pct exec 112 -- tail -60 /var/ossec/logs/ossec.log | grep -iE "error|critical|active.response"

3. Attack from the laptop:

        for i in $(seq 1 12); do sshpass -p "bad$i" ssh -o StrictHostKeyChecking=no \
          -o ConnectTimeout=5 -o PreferredAuthentications=password \
          -o PubkeyAuthentication=no haker@192.168.1.61 2>&1 | tail -1; echo "try $i"; done

4. Check the block, then check again after 180 s:

        pct exec 121 -- iptables -L INPUT -n --line-numbers
        pct exec 121 -- tail -5 /var/ossec/logs/active-responses.log
        pct exec 121 -- grep -c '"command":"delete"' /var/ossec/logs/active-responses.log

5. Whitelist test: the same attack from the manager (192.168.1.60):

        pct exec 121 -- wc -l /var/ossec/logs/active-responses.log
        pct exec 112 -- bash -c 'for i in $(seq 1 8); do sshpass -p "bad$i" ssh ... haker@192.168.1.61; done'
        pct exec 121 -- iptables -L INPUT -n --line-numbers
        pct exec 121 -- wc -l /var/ossec/logs/active-responses.log
        pct exec 112 -- grep -A 4 "Rule: 5712" /var/ossec/logs/alerts/alerts.log | tail -5

## Results

| Test | Result |
|---|---|
| Tries 1-4 from the laptop | Permission denied (sshd answers) |
| Tries 5-12 from the laptop | Connection timed out (packets dropped) |
| Rule that triggered the response | 5712, level 10, frequency 8, MITRE T1110 |
| Victim firewall after the attack | DROP all from 192.168.1.109 |
| After 180 s | INPUT chain empty, 1 delete command in the AR log |
| Attack from the manager (whitelisted) | alert 5712 with Src IP 192.168.1.60, no DROP, AR log unchanged (13 -> 13 lines) |

## What I learned

1. **Detection vs response.** Lab 11 only raised an alert. Active response
   closes the loop: rule fires -> manager sends a command -> the agent runs a
   script locally. Same idea as IDS vs IPS.
2. **The manager does not know what the agent has installed.** Without
   iptables on the victim, the alert would still appear, but the block would
   fail silently and only the agent's active-responses.log would show it.
   Verify the reaction, not just the alert.
3. **DROP means timeout, REJECT means refused.** After the block, ssh got no
   answer and gave up after 5 s (Connection timed out). DROP also hides that
   the host exists. Same difference as timeout vs unreachable in lab 04.
4. **frequency counts log events, not attacker attempts.** The block came
   after 4 ssh attempts, not 8: each attempt writes two lines (Invalid user +
   Failed password). The counter lives in memory, so a manager restart and
   the 120 s timeframe reset it.
5. **Timeout limits the damage of false positives.** The agent removed the
   block by itself after 180 s. A user who forgot a password is slowed down,
   not locked out forever, and the DROP list does not grow without limit.
6. **The whitelist stops the response, not the detection.** The attack from
   the manager still produced alert 5712, but no command reached the agent.
   Without the manager, gateway and DNS on the whitelist, a SIEM could cut
   itself off or block critical infrastructure.

## Production vs lab

- **Whitelist:** add the manager, gateway, DNS, jump hosts and monitoring.
  Here it was missing three of them by default.
- **Timeouts:** 180 s is for testing. In production use longer timeouts and
  repeated_offenders to block repeat attackers for longer.
- **Blocking by IP is weak:** the laptop has a second address on the same
  network (Wi-Fi 192.168.1.239) that would not be blocked. Attackers behind
  NAT or with many IPs, and real users behind the same NAT, make IP blocks
  imprecise.
- **Time zones:** the victim logs in UTC, the manager in local time
  (18:14 vs 19:14). Use one time zone (UTC or synced NTP + zone) everywhere,
  or correlation becomes guesswork.
- **Resource limits:** wazuh-remoted logs "Could not set resource limit for
  file descriptors" because an unprivileged LXC cannot raise the limit. Fine
  for one agent, not for hundreds.
- **Defense in depth:** the 8th attempt from the manager ended with
  "Connection reset" - most likely OpenSSH's own per-source penalties.
  fail2ban or sshd limits on the host work even if the SIEM is down.

## Next steps

- Second interface bypass test (Wi-Fi 192.168.1.239) and repeated_offenders.
- Active response on other rules (e.g. web attacks) and a custom script.
- Lab 14: Windows Server + Active Directory + GPO, Windows agent in Wazuh (event 4625).
