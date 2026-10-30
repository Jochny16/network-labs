# Lab 12: Wazuh File Integrity Monitoring (FIM)

File Integrity Monitoring with the Wazuh agent (syscheck) on the lab 11 setup.
The agent watches selected directories in realtime, the manager raises alerts
for modified, added and deleted files, and a custom rule escalates changes in
/root/.ssh (SSH key persistence, MITRE ATT&CK T1098.004) to level 12.

## Topology

    Proxmox "nautilus" 192.168.1.100

    +------------------------------+          +------------------------------+
    | CT 121 victim 192.168.1.61   |  events  | CT 112 wazuh 192.168.1.60    |
    | wazuh-agent 001              | -------> | wazuh-manager (analysisd)    |
    | syscheck: realtime (inotify) | tcp/1514 | rules 550/553/554 + 100100   |
    | /root/fim-test, /root/.ssh   |          | alerts.log, dashboard        |
    +------------------------------+          +------------------------------+

## Setup (manual, on the Proxmox host)

Start the containers (indexer needs 2-3 minutes before the dashboard answers):

    pct start 112
    pct start 121

Agent config, CT 121, /var/ossec/etc/ossec.conf, inside <syscheck>:

    <directories realtime="yes" check_all="yes" report_changes="yes">/root/fim-test,/root/.ssh</directories>

The directories must exist before the agent starts, then:

    pct exec 121 -- systemctl restart wazuh-agent

Custom rule, CT 112, /var/ossec/etc/rules/local_rules.xml:

    <group name="local,syscheck,">
      <rule id="100100" level="12">
        <if_sid>550,554</if_sid>
        <field name="file">/root/.ssh/</field>
        <description>File changed or added in /root/.ssh - possible SSH persistence</description>
        <group>persistence,</group>
      </rule>
    </group>

Rules are loaded by the manager, so restart the manager and check the log:

    pct exec 112 -- systemctl restart wazuh-manager
    pct exec 112 -- tail -50 /var/ossec/logs/ossec.log | grep -iE "error|critical"

## Run

    pct exec 121 -- sh -c 'echo "haslo=zmienione" >> /root/fim-test/config.txt'
    pct exec 121 -- sh -c 'echo test > /root/fim-test/nowy.txt'
    pct exec 121 -- rm /root/fim-test/nowy.txt
    pct exec 121 -- sh -c 'echo "ssh-ed25519 AAAAC3NzaFAKEKEYFAKEKEY atakujacy@evil" >> /root/.ssh/authorized_keys'

Check alerts on the manager:

    pct exec 112 -- grep -B6 -A30 "fim-test/config.txt' modified" /var/ossec/logs/alerts/alerts.log
    pct exec 112 -- grep -B6 "authorized_keys' modified" /var/ossec/logs/alerts/alerts.log | grep "Rule:"

Cleanup:

    pct exec 121 -- sh -c ': > /root/.ssh/authorized_keys'

## Results

| # | Action | Rule | Level | Notes |
|---|---|---|---|---|
| 1 | Append a line to config.txt | 550 | 7 | realtime; size 6 -> 22; md5, sha1, sha256 changed; diff "2a3 > haslo=zmienione" |
| 2 | Create nowy.txt | 554 | 5 | File added to the system |
| 3 | Delete nowy.txt | 553 | 7 | File deleted |
| 4 | Fake key into empty authorized_keys (no custom rule) | 550 | 7 | diff "0a1 > ssh-ed25519 ... atakujacy@evil" |
| 5 | Second fake key (custom rule loaded) | 100100 | 12 | one alert only, the child rule replaces 550 |

## What I learned

1. **Scheduled scan vs realtime.** frequency 43200 means a full scan every 12 h. realtime="yes" uses inotify and alerts within seconds, but only for directories that existed when the agent started.
2. **Hashes are the evidence.** Changing one byte gives completely different md5/sha1/sha256, so FIM does not need to understand the file content to detect a change.
3. **report_changes sends only the diff.** The agent keeps a copy of the previous version (/var/ossec/queue/diff) and sends standard diff output ("2a3", ">" added, "<" removed). Secrets end up in the SIEM, so files with passwords should use <nodiff>.
4. **Added files score lower.** 554 is level 5, while 550 and 553 are level 7. New files appear all the time (logs, temp, packages); changing or deleting an existing watched file is more suspicious. Less noise, less alert fatigue.
5. **Agent collects, manager decides.** Rules live on the manager (wazuh-analysisd), so a new rule needs a manager restart. Changes to <syscheck> in the agent ossec.conf need an agent restart.
6. **A child rule replaces its parent.** The event matched 550 and then 100100; the alert gets the deepest matching rule, so there is one alert, not two.
7. **Default levels do not know context.** A new SSH key for root got the same level 7 as an edit to a test file. A custom rule with if_sid + field adds that context.

## Production vs lab

- Production FIM watches /etc, /usr/bin, /usr/sbin, /boot and every user's .ssh directory, not a test folder.
- Noisy paths are excluded with <ignore>, otherwise FIM floods the SIEM.
- whodata mode (auditd) records which user and process changed the file; realtime only says that it changed.
- Files with secrets use <nodiff>: hashes still checked, content not sent.
- High-level alerts (12+) go to notifications or active response instead of waiting in the dashboard.

## Next steps

- Active response on rule 100100 (for example remove the added key or block the source).
- whodata mode with auditd.
- Lab 14: Windows Server + Active Directory + GPO, Windows agent in Wazuh (event 4625).
