# 11 - Wazuh SIEM: detecting an SSH brute-force attack

A single-node Wazuh deployment on Proxmox that collects logs from an agent,
correlates them, and raises an alert when someone repeatedly fails to log in
over SSH. This is the blue-team side of labs 01-10: instead of building the
network, here I watch it and detect an attack.

Unlike the earlier labs this one is not a single namespace script - Wazuh is a
stateful service (manager + indexer + dashboard), so it lives as a Proxmox LXC
container and the steps below are run by hand.

## Topology

    Proxmox host "nautilus" (192.168.1.100)
      |
      +-- CT 112  wazuh    192.168.1.60   manager + indexer + dashboard (4.14.9)
      +-- CT 121  victim   192.168.1.61   Debian 13 + wazuh-agent, sshd

    test: 12 failed SSH logins   CT112 --> CT121:22   (user "haker", wrong passwords)

Agent -> manager ports: 1514 (events, encrypted), 1515 (registration).

## Run

Manager (community helper script, in the Proxmox host shell):

    bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/wazuh.sh)"
    # Advanced: unprivileged, 4 vCPU, 6 GB RAM, 40 GB disk, IP 192.168.1.60/24

Agent (inside CT 121):

    apt install -y lsb-release
    WAZUH_MANAGER='192.168.1.60' WAZUH_AGENT_NAME='victim' dpkg -i ./wazuh-agent_4.14.9-1_amd64.deb
    sed -i 's|<address>MANAGER_IP</address>|<address>192.168.1.60</address>|' /var/ossec/etc/ossec.conf
    systemctl enable --now wazuh-agent

Generate failed logins (test traffic, from the host shell):

    pct exec 112 -- apt install -y sshpass
    pct exec 112 -- bash -c 'for i in $(seq 1 12); do sshpass -p "bad$i" ssh -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no haker@192.168.1.61 2>/dev/null; done'

Then in the dashboard: Threat Hunting -> Events, filter rule.level >= 10.

## Results

| Rule ID | Description | Level |
|---|---|---|
| 5710 | sshd: Attempt to login using a non-existent user | 5 |
| 5712 | sshd: brute force trying to get access to the system | 10 |
| 5551 | PAM: Multiple failed logins in a small period of time | 10 |

One attack, two detections: the sshd rule and the PAM rule both fired on the
same burst. 12 failures produced 23 auth-failure events and 0 successes.

## What I learned

1. **Correlation is the point.** A single failed login is level 5 (noise).
   Rule 5712 only fires at frequency 8 within 120 s - the pattern is the alert,
   not the event. This is the difference between a log collector and a SIEM.
2. **Agent architecture.** The agent reads local logs (/var/log/auth.log) and
   ships them to the manager over 1514; it first registers over 1515 and gets an
   ID + key. Wazuh does not scan the network - it only sees what an agent sends.
3. **Verify the config, don't trust "install OK".** The .deb left the default
   placeholder MANAGER_IP; the agent installed fine but would never have
   connected. Always grep the config after install.
4. **Rule levels 0-15.** 0-6 low, 7-11 medium, 12-14 high, 15+ critical.
5. **Analyst verdict = true positive, authorized.** Source was my own manager
   during a test window. The same alert from an unknown WAN IP would be an
   incident to escalate. The question is always: did someone plan this change?

## Production vs lab

| | This lab | Production |
|---|---|---|
| Certificate | self-signed (browser warning) | internal CA |
| Enrollment | open auto-enrollment | enrollment password / cert |
| Attack source | from the manager | real traffic from the internet |
| Deployment | all-in-one, 1 node | distributed (indexer cluster) |

## Part 2: File Integrity Monitoring and alert triage

Same two containers. Lab 11 detected behaviour (logins); FIM detects a change
of state - a file that should not change, did.

### Topology

    CT 121 victim                            CT 112 wazuh
    wazuh-agent / syscheck                   manager
      - hashes files, keeps a baseline  -->  rules 550 / 553 / 554  --> alert
      - realtime = inotify               1514

### Run

Watch one directory in realtime, with diffs (inside CT 121, via the host):

    pct exec 121 -- mkdir -p /root/fim-test
    pct exec 121 -- sed -i '0,/<syscheck>/s|<syscheck>|<syscheck>\n    <directories realtime="yes" check_all="yes" report_changes="yes">/root/fim-test</directories>|' /var/ossec/etc/ossec.conf
    pct exec 121 -- grep -n -A2 "<syscheck>" /var/ossec/etc/ossec.conf
    pct exec 121 -- systemctl restart wazuh-agent

Wait for "File integrity monitoring scan ended" in /var/ossec/logs/ossec.log,
then create, modify and delete a file:

    pct exec 121 -- bash -c 'echo "haslo=tajne123" > /root/fim-test/secret.txt'
    pct exec 121 -- bash -c 'echo "haslo=zmienione_przez_atakujacego" > /root/fim-test/secret.txt'
    pct exec 121 -- rm /root/fim-test/secret.txt

Dashboard: Threat Hunting -> Events, rule.id:554 or rule.id:550 or rule.id:553.

### Results: FIM

| Time | Rule | Level | Event | Detail |
|---|---|---|---|---|
| 19:57:23 | 554 | 5 | File added to the system | secret.txt, 15 bytes |
| 19:58:44 | 550 | 7 | Integrity checksum changed | MD5 changed, 15 -> 34 bytes, diff shown |
| 20:03:23 | 553 | 7 | File deleted | alert kept on the manager |

The diff field (report_changes) showed the exact change:

    1c1
    < haslo=tajne123
    ---
    > haslo=zmienione_przez_atakujacego

### Results: triaging the rootcheck noise

The agent restart also produced ~99 alerts of rule 510 (level 7) within
a few milliseconds:

    File '/dev/.lxc/proc/schedstat' present on /dev. Possible hidden file.

| Step | Finding |
|---|---|
| Evidence | data.file under /dev/.lxc/, fired only at agent start, firedtimes 85+ |
| Context | victim is an LXC container; LXC puts virtual /proc files in /dev/.lxc |
| Verdict | false positive - container infrastructure, not a hidden attacker file |
| Tuning | rootcheck ignore for /dev/.lxc, agent restarted |
| Retest | 1 alert left: /dev/.lxc-boot-id (separate file, also LXC) |
| Tuning 2 | second ignore for /dev/.lxc-boot-id |
| Retest 2 | 0 new rule 510 alerts after restart |

Final agent config:

    <rootcheck>
      <ignore>/dev/.lxc</ignore>
      <ignore>/dev/.lxc-boot-id</ignore>
      <disabled>no</disabled>

Ticket note:

    FP. Rule 510 on agent victim (LXC container): files in /dev/.lxc/proc/ are
    virtual /proc files created by LXC, not hidden attacker files. Fires only
    at agent start, same pattern every time. Fix: rootcheck ignore /dev/.lxc
    and /dev/.lxc-boot-id. Retested: 0 new alerts.

### What I learned (part 2)

1. **FIM reports change, not badness.** The first scan builds a silent
   baseline. A file added after it is rule 554; a file planted before the
   agent was installed becomes part of "normal".
2. **Levels follow risk.** New file = 5, changed or deleted file = 7.
   Where the file is matters more than the rule: /tmp vs ~/.ssh/authorized_keys.
3. **Deleting evidence locally does not help the attacker.** The 553 alert
   and the diff live on the manager, not on the victim.
4. **The security tool can leak data.** report_changes keeps a copy of the
   file and puts the diff in the index - here a password in clear text.
   Use nodiff for files with secrets.
5. **No verdict without evidence.** My first guess was "true positive" from
   the rule name alone. full_log and data.file turned it into a clear FP.
6. **Exceptions must be narrow.** /dev/.lxc did not cover /dev/.lxc-boot-id.
   That is correct: a prefix match would also hide /dev/.lxc-backdoor.
7. **Check the time zone.** Agent log is UTC, dashboard is local time (+1 h).

## Next steps

- Active response: auto-block the source IP after the SSH brute-force alert.
- FIM with whodata (auditd): who changed the file and with which process.
- Watch ~/.ssh/authorized_keys and /etc/passwd - realistic persistence targets.
- Add a Windows agent (ties into the planned AD lab) and watch event 4625.
