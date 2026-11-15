# Lab 19: Windows Server, Active Directory and Wazuh (Proxmox)

First Windows lab in the homelab. A Windows Server 2022 VM on Proxmox is promoted to a domain controller for a new forest, gets OUs, a group and users, a domain account lockout policy, and a Wazuh agent. A password-guessing attack from the laptop is then traced in three places: the AD account state, the Windows Security log and Wazuh alerts.

No script - this is a service lab. The README documents the manual steps; every output was verified during the lab.

## Topology

    laptop think14 (192.168.1.109)          nautilus (Proxmox, 192.168.1.100)
      smbclient (attacker)                    VM 130 dc01  192.168.1.70  (static)
      ssh -> dc01                               Windows Server 2022 Standard Eval (Desktop Experience)
            |                                   AD DS + DNS, domain homelab.internal (HOMELAB)
            |                                   Wazuh agent 002 -> manager 192.168.1.60
            +------------- LAN 192.168.1.0/24 --+
                                                CT 112 wazuh  192.168.1.60 (manager 4.14.9)
    router 192.168.1.1 (gateway, DNS forwarder for the DC)

    homelab.internal
    +-- CN=Users      Administrator, Guest (disabled), krbtgt (disabled)
    +-- OU=IT         group Helpdesk, user jan.kowalski (member of Helpdesk)
    +-- OU=Ksiegowosc user anna.nowak

## Run

1. VM on nautilus (SATA disk and E1000 NIC so Windows has drivers out of the box; 40 GB thin on local-lvm):

        qm create 130 --name dc01 --ostype win11 --memory 4096 --cores 2 --cpu host \
          --sata0 local-lvm:40 \
          --ide2 local:iso/SERVER_EVAL_x64FRE_en-us.iso,media=cdrom \
          --net0 e1000,bridge=vmbr0 --boot order='ide2;sata0'
        qm start 130

2. Install "Windows Server 2022 Standard Evaluation (Desktop Experience)", custom install on the empty disk. Ctrl-Alt-Del comes from the side panel of the Proxmox noVNC console.

3. Static IP before promotion (ncpa.cpl): 192.168.1.70/24, gateway 192.168.1.1, DNS 192.168.1.1. Then time zone and name (PowerShell):

        Set-TimeZone -Id "Central European Standard Time"
        Rename-Computer -NewName DC01 -Restart

4. Promote to the first DC of a new forest:

        Install-WindowsFeature AD-Domain-Services -IncludeManagementTools
        Install-ADDSForest -DomainName "homelab.internal" -DomainNetbiosName "HOMELAB" -InstallDns

5. OpenSSH server (the noVNC console has no clipboard), then work from the laptop with ssh Administrator@192.168.1.70:

        Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
        Start-Service sshd
        Set-Service sshd -StartupType Automatic

6. OUs, group, users:

        New-ADOrganizationalUnit -Name "IT"
        New-ADOrganizationalUnit -Name "Ksiegowosc"
        New-ADGroup -Name "Helpdesk" -GroupScope Global -Path "OU=IT,DC=homelab,DC=internal"
        $pw = Read-Host "Password" -AsSecureString
        New-ADUser -Name "Jan Kowalski" -SamAccountName jan.kowalski -UserPrincipalName jan.kowalski@homelab.internal -Path "OU=IT,DC=homelab,DC=internal" -AccountPassword $pw -Enabled $true
        New-ADUser -Name "Anna Nowak" -SamAccountName anna.nowak -UserPrincipalName anna.nowak@homelab.internal -Path "OU=Ksiegowosc,DC=homelab,DC=internal" -AccountPassword $pw -Enabled $true
        Add-ADGroupMember -Identity Helpdesk -Members jan.kowalski

7. Account lockout policy (stored in the Default Domain Policy GPO):

        Set-ADDefaultDomainPasswordPolicy -Identity homelab.internal -LockoutThreshold 5 -LockoutDuration 00:10:00 -LockoutObservationWindow 00:10:00

8. Attack from the laptop, then the correct password:

        for i in 1 2 3 4 5; do smbclient -L //192.168.1.70 -U 'HOMELAB\anna.nowak%WrongPass1' 2>&1 | tail -1; done
        smbclient -L //192.168.1.70 -U 'HOMELAB\anna.nowak'

9. Evidence on the DC, then unlock:

        Get-ADUser anna.nowak -Properties LockedOut, BadLogonCount
        Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4625,4740,4767} -MaxEvents 10
        Unlock-ADAccount anna.nowak

10. NTP for the DC (PDC emulator syncs with an external source):

        w32tm /config /manualpeerlist:"pl.pool.ntp.org" /syncfromflags:manual /reliable:yes /update
        Restart-Service w32time
        w32tm /resync

11. Wazuh agent (version must not be newer than the manager), then check the config and the manager:

        Invoke-WebRequest -Uri https://packages.wazuh.com/4.x/windows/wazuh-agent-4.14.9-1.msi -OutFile $env:TEMP\wazuh-agent.msi
        msiexec.exe /i $env:TEMP\wazuh-agent.msi /q WAZUH_MANAGER='192.168.1.60' WAZUH_AGENT_NAME='dc01'
        NET START Wazuh
        # on nautilus:
        pct exec 112 -- /var/ossec/bin/agent_control -l
        pct exec 112 -- grep -A2 "dc01" /var/ossec/logs/alerts/alerts.log | grep "Rule:"

## Results

| Test | Result |
|---|---|
| IP right after install | 192.168.1.110 from the router (DHCP is on by default) |
| DNS after promotion | Preferred DNS changed to 127.0.0.1 by the wizard; old DNS moved to forwarders |
| nslookup homelab.internal / google.com | 192.168.1.70 / non-authoritative answer via forwarder |
| Get-ADDomain | homelab.internal, HOMELAB, DomainMode Windows2016Domain (2022 has no new functional level) |
| 5 wrong passwords via SMB | 5x NT_STATUS_LOGON_FAILURE, 5x event 4625 |
| 6th try with the correct password | NT_STATUS_ACCOUNT_LOCKED_OUT, LockedOut True, BadLogonCount 5, event 4740 |
| Unlock-ADAccount | LockedOut False, event 4767 (written a few seconds later) |
| Events from install/promotion | timestamped 16.11 01:27 (clock was hours ahead before time zone + NTP fix) |
| Wazuh agent | ID 002 dc01, connected to 192.168.1.60:1514, SCA scan with CIS Windows Server 2022 |
| Attack before the agent existed | 0 alerts - the agent reads only new events |
| Attack with the agent | 5x rule 60122 (level 5, logon failure), 1x rule 60115 (level 9, account locked out) |

Predictions: 3/4 + one half (DHCP on by default, DNS 127.0.0.1 after promotion, no old events in Wazuh correct; lockout first predicted as IP block like Wazuh active response, corrected to account lockout after a hint).

## What I learned

1. **A DC needs a static IP.** Clients use the DC's IP as their DNS server; a DHCP address that changes would break logons for the whole domain.
2. **AD stands on DNS.** Clients find the DC through DNS (SRV records), so the DC runs DNS for the domain and clients must point to it, not to the router. The promotion wizard sets the DC's own DNS to loopback and keeps the old server as a forwarder.
3. **Rename and set the clock before promotion.** The computer name becomes part of the DC identity; Kerberos rejects logons when clocks differ by more than 5 minutes.
4. **Containers are not OUs.** CN=Users is a container and a GPO cannot be linked to it, so users go into their own OUs.
5. **krbtgt signs every Kerberos ticket.** A stolen krbtgt hash allows forged tickets for any account (Golden Ticket).
6. **Password and lockout policy for domain accounts works only at the domain level** (Default Domain Policy). Linked to an OU it is ignored; per-group exceptions need fine-grained password policies.
7. **Lockout blocks the account, not the attacker.** Even the correct password is refused (NT_STATUS_ACCOUNT_LOCKED_OUT), the real user is locked out too (possible DoS), and an attacker from another IP is still blocked. Wazuh active response in lab 13 did the opposite: it blocked an IP on one host.
8. **Password spraying avoids lockout** - one password tried once against many accounts never reaches the per-account threshold; it has to be caught in the SIEM (many 4625 from one source).
9. **Key event IDs:** 4624 logon, 4625 failed logon, 4740 locked out, 4767 unlocked, 4768/4769 Kerberos TGT/service ticket, 4720 user created.
10. **A SIEM sees only what happened after the agent started.** Older evidence has to be collected from the host itself (Get-WinEvent).
11. **Wrong timestamps break the timeline.** Events written while the clock was off landed hours in the future - the same class of problem as UTC vs local time between agent and manager in lab 13.

## Production vs lab

- Production has at least two DCs (redundancy for logon and DNS); here one evaluation DC.
- Preferred DNS on a DC: its own IP (or another DC), loopback as alternate.
- VirtIO disk and NIC with the virtio-win drivers would be faster; SATA and E1000 avoid a second ISO.
- Admins use separate admin accounts and do not log on with Domain Admin for daily work.
- Lockout thresholds are a trade-off between brute force protection and user DoS; many organisations combine a higher threshold with SIEM alerting.

## Next steps

- Windows 11 client joined to the domain, GPO linked to an OU (e.g. block Control Panel for Ksiegowosc).
- Wazuh custom rule for password spraying (many 4625 for different users from one IP).
- Review the CIS Windows Server 2022 SCA results in the Wazuh dashboard.
