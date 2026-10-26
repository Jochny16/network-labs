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

## Next steps

- File Integrity Monitoring: edit a file on victim, watch the FIM alert.
- Active response: auto-block the source IP after the brute-force alert.
- Add a Windows agent (ties into the planned AD lab) and watch event 4625.
