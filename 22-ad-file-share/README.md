# Lab 22: AD file share permissions (share vs NTFS, group-based access)

A typical service desk ticket is "I have no access to the department folder". This lab builds a department share on the domain controller from labs 19-20 and shows how access really works: two permission layers (share and NTFS), access granted to a group instead of to people, and onboarding/offboarding done by changing group membership only.

Part 1 (this README): share, NTFS, group membership, tests with smbclient from the Linux laptop.
Part 2 (planned): Windows 11 client joined to the domain, GPO linked to an OU (drive mapping M:, screen lock), gpupdate / gpresult.

## Topology

    laptop (Debian 13)                         dc01 (VM 130 on Proxmox)
    smbclient  -----------  LAN  -----------   192.168.1.70
                          192.168.1.0/24       Windows Server 2022, domain homelab.internal
                                               share \\dc01\Magazyn -> C:\Shares\Magazyn

    access path:  user --SMB--> [share permissions] --> [NTFS permissions] --> folder
                  the more restrictive of the two layers wins

Accounts used (from lab 20, password Lab20-Haslo!2026):

    kasia.wojcik       member of group Magazyn at the start
    piotr.wisniewski   not a member at the start

## Run

On the domain controller (ssh Administrator@192.168.1.70, then powershell):

    New-ADOrganizationalUnit -Name "Magazyn"
    New-ADGroup -Name "Magazyn" -GroupScope Global -Path "OU=Magazyn,DC=homelab,DC=internal"
    Add-ADGroupMember -Identity Magazyn -Members kasia.wojcik
    New-Item -Path C:\Shares\Magazyn -ItemType Directory | Out-Null
    New-SmbShare -Name Magazyn -Path C:\Shares\Magazyn -FullAccess "Authenticated Users" | Out-Null
    icacls C:\Shares\Magazyn /inheritance:r /grant "Administrators:(OI)(CI)F" "SYSTEM:(OI)(CI)F" "HOMELAB\Magazyn:(OI)(CI)M"
    Get-SmbShareAccess -Name Magazyn
    icacls C:\Shares\Magazyn

Result of the checks:

    Share:  NT AUTHORITY\Authenticated Users   Allow   Full
    NTFS:   HOMELAB\Magazyn:(OI)(CI)(M)
            NT AUTHORITY\SYSTEM:(OI)(CI)(F)
            BUILTIN\Administrators:(OI)(CI)(F)

Tests from the laptop:

    smbclient //192.168.1.70/Magazyn -U 'HOMELAB\kasia.wojcik%Lab20-Haslo!2026' -c 'put /etc/hostname test-kasia.txt; ls'
    smbclient //192.168.1.70/Magazyn -U 'HOMELAB\piotr.wisniewski%Lab20-Haslo!2026' -c 'ls'

Onboarding and offboarding (on the DC), each followed by the smbclient test again:

    Add-ADGroupMember -Identity Magazyn -Members piotr.wisniewski
    Remove-ADGroupMember -Identity Magazyn -Members kasia.wojcik -Confirm:$false
    Get-ADGroupMember -Identity Magazyn | Select-Object SamAccountName

## Results

| Step | User | Member of Magazyn | Result |
|---|---|---|---|
| 1 | kasia.wojcik | yes | file written, listing works |
| 2 | piotr.wisniewski | no | NT_STATUS_ACCESS_DENIED listing \* (connected to the share, stopped by NTFS) |
| 3 | piotr.wisniewski | added | listing works immediately, sees test-kasia.txt |
| 4 | kasia.wojcik | removed | NT_STATUS_ACCESS_DENIED listing \* |

Predictions: 2/2 (Piotr gets access denied on listing, not a logon error; new membership works at once for a new smbclient session).

## What I learned

1. **Two layers, the stricter one wins.** Share permissions apply only over the network, NTFS always. Piotr connected to the share (Authenticated Users: Full) and was stopped only by NTFS - the error appeared on `ls`, not on logon.
2. **Common practice: open share, strict NTFS.** Keeping the share wide and the real limits in NTFS means access is managed in one place.
3. **Grant access to groups, never to people.** Onboarding and offboarding become one command each (Add/Remove-ADGroupMember); the folder ACL never changes.
4. **OU is not a permission.** Moving a user to another OU does not change access to a folder; only group membership does. When someone changes department, the groups must be changed by hand, otherwise old access stays.
5. **Group membership is read at logon.** smbclient logs on fresh every run, so a new group worked at once. On a Windows PC the groups sit in the logon token: after adding a user to a group, they must log off and on (or purge Kerberos tickets with `klist purge`) before the new access works - a classic "you added me but it still does not work" ticket.
6. **Disable inheritance deliberately.** `icacls /inheritance:r` removed the default Users entries inherited from C:\, otherwise every domain user could still read the folder.

## Production vs lab

- Shares live on a file server, not on a domain controller.
- Best practice is AGDLP: users go into global groups (role), global groups into domain local groups (resource permission), and the ACL holds only the domain local group.
- Access requests are approved by the data owner (for example the department manager) and logged in the ticket.
- Drive letters are usually mapped by GPO or Intune, not by hand.

## Next steps

- Part 2: Windows 11 client in the domain, GPO on OU Magazyn mapping the share as M: and enforcing a screen lock; test gpupdate /force and gpresult /r; troubleshoot "I do not see drive M:".
- Read-only group for the same folder (two groups, two permission levels).
- Audit file access (event 4663) and forward it to Wazuh.
