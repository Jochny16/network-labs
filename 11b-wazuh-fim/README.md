# Lab 11b: Wazuh File Integrity Monitoring

Extension of lab 11. The Wazuh agent on the victim container watches selected
directories in real time and raises alerts when files are added, changed or
deleted. Also compares real-time and scheduled scanning, and shows that a
change made before an agent restart can go unreported.

## Topology

    Proxmox "nautilus" 192.168.1.100
    +-----------------------------+      +-----------------------------+
    | CT 112 wazuh 192.168.1.60   |<-----| CT 121 victim 192.168.1.61  |
    | manager, indexer, dashboard | 1514 | wazuh-agent 001 (syscheck)  |
    +-----------------------------+      +-----------------------------+

## Run

Agent config (/var/ossec/etc/ossec.conf, inside <syscheck>):

    <directories realtime="yes" check_all="yes" report_changes="yes">/root/fim-test,/root/.ssh</directories>

Restart and verify:

    systemctl restart wazuh-agent
    grep -n 'fim-test' /var/ossec/etc/ossec.conf
    grep -E 'scan (started|ended)' /var/ossec/logs/ossec.log | tail -2

Watch alerts on the manager (from the Proxmox host):

    pct exec 112 -- grep -A1 -E 'Rule: 55[034] ' /var/ossec/logs/alerts/alerts.log | tail -4

## Results

| Test | Action | Result |
|---|---|---|
| 1 | create /root/fim-test/config.txt | 554 file added, realtime |
| 2 | append to config.txt | 550 checksum changed: size 3 to 6, new md5/sha1/sha256 |
| 3 | create new.txt | 554 file added |
| 4 | delete new.txt | 553 file deleted |
| 5 | add fake key to /root/.ssh/authorized_keys | 554 file added, only level 5 |
| 6 | append to /etc/hosts (scheduled, every 43200 s) | no alert |
| 7 | restart agent after test 6 | still no alert: new baseline absorbed the change |
| 8 | frequency 60 s, change /etc/hosts after baseline | 550 after the next scan |

## What I learned

1. **FIM compares against a baseline.** syscheck stores hash, permissions, owner and size; any difference becomes an alert.
2. **Default is scheduled, every 12 hours.** /etc, /usr/bin and /usr/sbin have no realtime attribute, so a change stays invisible until the next scan.
3. **realtime="yes" uses inotify.** Alerts arrive within seconds.
4. **The first scan after agent start is a baseline and sends no alerts.** A change made before a restart, or while the agent was stopped, can pass silently. Attackers stopping the agent is a real risk.
5. **"Hidden" means nothing to FIM.** A dot in the name only hides it from ls; /root/.ssh is a normal watched directory.
6. **authorized_keys is a persistence target but the default level is only 5.** Production needs a custom rule to raise it.
7. **sed on a shared value hits every match.** Changing 43200 to 60 also changed rootcheck; always grep after editing.

## Production vs lab

- Production watches /etc, binaries, web roots and SSH keys in real time, with ignore rules for noisy files.
- whodata (auditd) adds who and which process made the change; it does not work in an unprivileged LXC container.
- Agent stop and disconnect events are alerted on, to cover the baseline gap from point 4.
- A custom rule raises authorized_keys changes to a high level and routes them to the SOC queue.

## Next steps

- Custom rule: authorized_keys change at level 12.
- Active response: block the source IP after the SSH brute-force alert.
- Lab 12: Windows Server + Active Directory + GPO with a Windows agent (event 4625).
