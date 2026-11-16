# Lab 20: Password spraying detection (Active Directory + Wazuh)

Password spraying tries one password against many accounts, so every account stays
below the lockout threshold. This lab shows that the domain lockout policy and the
default Wazuh rules both miss it, and adds a custom correlation rule that catches it.

Continues lab 19 (domain controller dc01 with a Wazuh agent).

## Topology

    laptop think14 (192.168.1.254)
        |  smbclient, NTLM logon attempts (logon type 3)
        v
    dc01 (192.168.1.70)  Windows Server 2022, domain homelab.internal
        |  Security log: 4625 / 4740, Wazuh agent 002
        v
    wazuh (192.168.1.60)  manager, rules 60122 / 60115 / 60204 + custom 100200

Lockout policy from lab 19: 5 failed logons, 10 minute window.

## Run

No script. The steps are manual, on three machines.

1. On dc01 (PowerShell), add four more users so there are six targets:

        $p = ConvertTo-SecureString 'Lab20-Haslo!2026' -AsPlainText -Force
        'piotr.wisniewski','ewa.zielinska','marek.lewandowski','kasia.wojcik' | ForEach-Object { New-ADUser -Name $_ -SamAccountName $_ -UserPrincipalName "$_@homelab.internal" -AccountPassword $p -Enabled $true }

2. On the laptop, spray one wrong password across six accounts:

        P='Jesien2026!'
        for u in jan.kowalski anna.nowak piotr.wisniewski ewa.zielinska marek.lewandowski kasia.wojcik; do
          smbclient -L //192.168.1.70 -U "HOMELAB\\$u%$P" 2>&1 | head -1
        done

3. On dc01, list the events and locked accounts:

        Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4625,4740; StartTime=(Get-Date).AddMinutes(-5)}
        Search-ADAccount -LockedOut

4. On the Wazuh manager, back up local_rules.xml, append the rule from
   100200-password-spraying.xml, validate and restart:

        cp /var/ossec/etc/rules/local_rules.xml /var/ossec/etc/rules/local_rules.xml.bak-lab20
        cat 100200-password-spraying.xml >> /var/ossec/etc/rules/local_rules.xml
        /var/ossec/bin/wazuh-analysisd -t && systemctl restart wazuh-manager

5. Repeat the spray (step 2), then run a brute force against one account:

        for p in 'Zima2026!' 'Wiosna2026!' 'Lato2026!' 'Haslo123!' 'Admin2026!'; do
          smbclient -L //192.168.1.70 -U "HOMELAB\\jan.kowalski%$p" 2>&1 | head -1
        done

## The rule

    <group name="local,windows,authentication_failures,">
      <rule id="100200" level="12" frequency="5" timeframe="60">
        <if_matched_sid>60122</if_matched_sid>
        <same_field>win.eventdata.ipAddress</same_field>
        <not_same_field>win.eventdata.targetUserName</not_same_field>
        <description>Password spraying: logon failures for 5 different users from one source IP</description>
        <mitre>
          <id>T1110.003</id>
        </mitre>
      </rule>
    </group>

## Results

| Test | Domain controller | Wazuh |
|---|---|---|
| Spray, 6 accounts, default rules | 6 x 4625, no 4740, nobody locked out | 6 x rule 60122 (level 5), no correlation |
| Spray, 6 accounts, rule 100200 loaded | 6 x 4625, nobody locked out | 4 x 60122, then 100200 (level 12) on the 5th failure, 6th is 60122 again |
| Brute force, 5 passwords, one account | account locked out (4740) | 60122 alerts + 60115 (level 9), rule 100200 silent |

My predictions: 0 of 3. Each time I expected something to block or correlate
by source IP on its own. Nothing does unless a rule says so.

## What I learned

1. **Lockout counts per account, not per source.** Six failures from one IP did not lock
   anything, because each account had only one failure out of five allowed.
2. **The domain controller never blocks an IP address.** It only refuses logons to a
   locked account. Blocking the source is a job for a firewall or active response.
3. **The built-in rule 60204 is too loose for spraying.** It needs 8 failures from one IP
   in 240 seconds (variable MS_FREQ) and ignores user names, so 7 accounts every
   4 minutes stay invisible.
4. **same_field and not_same_field define the attack shape.** Same IP plus different
   user names is spraying. Same IP plus the same user name is brute force.
5. **One event gives one alert.** The 5th failure was reported as 100200 instead of
   60122, and the counter started again afterwards.
6. **The two controls complement each other.** Lockout stops brute force on one account,
   the correlation rule detects spraying across accounts. Neither covers both.
7. **Spraying still uses up attempts.** jan.kowalski already had one failure from the
   spray, so the brute force locked the account one attempt earlier than expected.
8. **A DHCP address is not a stable host identity.** The laptop had a new lease
   (192.168.1.254), and the workstationName field (THINK14) identified it.
9. **Validate before restart.** diff against the backup and wazuh-analysisd -t caught
   nothing this time, but a broken rule file would stop the manager.

## Production vs lab

| Lab | Production |
|---|---|
| 6 accounts, 1 second | hundreds of accounts, slow (one round per lockout window) |
| threshold 5 in 60 s | longer timeframe, tuned against false positives (VPN gateways, NAT, service accounts) |
| NTLM over SMB only | also Kerberos pre-authentication failures (4771) and cloud sign-in logs |
| alert only | alert plus response: block the source, force password reset for any account that logged in successfully from that IP |

## Next steps

- Extend the rule to Kerberos failures (event 4771).
- Detect a successful logon (4624) from an IP that just triggered 100200.
- Windows 11 client joined to the domain and a GPO linked to an OU.
