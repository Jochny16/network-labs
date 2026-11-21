# Lab 21: MikroTik CHR on Proxmox (DHCP, NAT, firewall, port forward, VLAN, backup)

First contact with MikroTik RouterOS. A Cloud Hosted Router (CHR) VM on the Proxmox homelab routes an isolated LAN to the home network. The lab covers what a junior network admin does on a MikroTik every day: DHCP server, masquerade, a stateful firewall, port forwarding, a VLAN subinterface and config backups.

This is a service lab (like labs 11-13): no script, the README documents the manual steps and what each test proved.

## Topology

    home LAN 192.168.1.0/24 (gateway 192.168.1.1)
         |
       vmbr0
         |
    [ether1  DHCP client, 192.168.1.x]
          chr01  (VM 140, RouterOS 7.25.1, 1 GB RAM, 1 vCPU)
    [ether2  10.21.0.1/24]
      `- vlan30  10.21.30.1/24
         |
       vmbr1  (isolated bridge, no physical ports, VLAN-aware)
         |
    CT 122 lanclient (Debian 13)
      eth0  untagged  10.21.0.199 (DHCP from chr01)
      eth1  tag 30    10.21.30.10/24 (static)

## Run

### 1. CHR VM (on the Proxmox host)

    # image from https://download.mikrotik.com (latest stable 7.25.1)
    qm create 140 --name chr01 --memory 1024 --cores 1 --cpu host \
      --net0 virtio,bridge=vmbr0 --serial0 socket --vga serial0 \
      --scsi0 local-lvm:0,import-from=/root/chr-7.25.1.img,discard=on
    qm start 140
    qm terminal 140          # serial console, exit with Ctrl+O

### 2. Basics (RouterOS)

    /system identity set name=chr01
    /system clock set time-zone-name=Europe/Warsaw
    /system ntp client set enabled=yes
    /system ntp client servers add address=pl.pool.ntp.org

### 3. Isolated LAN bridge (Proxmox host)

    # /etc/network/interfaces
    auto vmbr1
    iface vmbr1 inet manual
            bridge-ports none
            bridge-stp off
            bridge-fd 0
            bridge-vlan-aware yes
            bridge-vids 2-4094

    ifreload -a
    qm set 140 -net1 virtio,bridge=vmbr1      # appears as ether2, hotplug, no reboot

### 4. LAN, DHCP server, DNS, NAT (RouterOS)

    /ip address add address=10.21.0.1/24 interface=ether2 comment=LAN
    /ip pool add name=lan-pool ranges=10.21.0.100-10.21.0.199
    /ip dhcp-server add name=lan-dhcp interface=ether2 address-pool=lan-pool lease-time=1h
    /ip dhcp-server network add address=10.21.0.0/24 gateway=10.21.0.1 dns-server=10.21.0.1
    /ip dns set allow-remote-requests=yes
    /ip firewall nat add chain=srcnat out-interface=ether1 action=masquerade comment="LAN to WAN"

### 5. Firewall filter (RouterOS)

    /interface list add name=LAN
    /interface list member add list=LAN interface=ether2
    /interface list member add list=LAN interface=vlan30

    /ip firewall filter
    add chain=input connection-state=established,related action=accept comment="in: established"
    add chain=input connection-state=invalid action=drop comment="in: invalid"
    add chain=input protocol=icmp action=accept comment="in: icmp"
    add chain=input in-interface-list=LAN action=accept comment="in: from LAN"
    add chain=input action=drop comment="in: drop rest"
    add chain=forward connection-state=established,related action=accept comment="fwd: established"
    add chain=forward connection-state=invalid action=drop comment="fwd: invalid"
    add chain=forward connection-state=new in-interface=ether1 connection-nat-state=!dstnat action=drop comment="fwd: drop new from WAN"

### 6. Port forward (RouterOS)

    /ip firewall nat add chain=dstnat in-interface=ether1 protocol=tcp dst-port=8080 \
      action=dst-nat to-addresses=10.21.0.199 to-ports=80 comment="fwd 8080 -> lanclient:80"

### 7. VLAN 30 (RouterOS + Proxmox)

    /interface vlan add name=vlan30 vlan-id=30 interface=ether2
    /ip address add address=10.21.30.1/24 interface=vlan30 comment=VLAN30

    pct set 122 -net1 name=eth1,bridge=vmbr1,tag=30,ip=10.21.30.10/24

### 8. Backups (RouterOS)

    /export file=lab21-part3                       # text, readable, no passwords
    /system backup save name=lab21 dont-encrypt=yes # binary, full (lab only: use password= in production)
    /system backup load name=lab21.backup           # asks for confirmation, then reboots

## Results

| # | Test | Result |
|---|------|--------|
| 1 | Default CHR config | only a DHCP client on ether1, no 192.168.88.1 defconf (that is a hardware-router thing) |
| 2 | WAN via DHCP | 192.168.1.x, dynamic default route (DAd) via 192.168.1.1 |
| 3 | DHCP server on ether2 | CT 122 got 10.21.0.199: RouterOS hands out from the END of the pool |
| 4 | Ping 192.168.1.1 from LAN without NAT | timeout; sniffer on chr01: 3 requests out, no replies (home router has no route back to 10.21.0.0/24) |
| 5 | Same with masquerade | works, src rewritten to the chr01 WAN address, TTL 63 |
| 6 | dig to chr01 from the home LAN before the filter | answered (open resolver) |
| 7 | Same after the filter | timeout, counted by "in: drop rest"; LAN still has DNS and internet |
| 8 | curl WAN:8080 before dstnat | timeout (curl code 28); "in: drop rest" went up (SYN + retransmissions at 1 s and 3 s) |
| 9 | curl WAN:8080 after dstnat | nginx page; dstnat counter = 1 packet, "fwd: drop new from WAN" = 0 |
| 10 | Source IP in the nginx log | the real client, not chr01 (dstnat changes only dst) |
| 11 | VLAN 30 ping after making vmbr1 VLAN-aware | 100% loss: tap140i1 (chr01) allowed only VLAN 1 |
| 12 | bridge vlan add dev tap140i1 vid 30 | ping works; after qm reboot 140 the port gets bridge-vids 2-4094 automatically |
| 13 | dig to 10.21.30.1 from VLAN 30, rule in-interface=ether2 | timeout, "in: drop rest" +1 packet (79 bytes, one query) |
| 14 | Rule changed to in-interface-list=LAN | DNS on VLAN 30 works |
| 15 | Backup, delete the VLAN 30 address, backup load | router asked, rebooted, address back |

Predictions in part 3: 3/6.

## What I learned

1. **No NAT and no return route means timeout, not an error.** The request reaches the home router, the reply follows the home router's default route to the internet. Masquerade fixes it because the new source is on a connected network.
2. **First packet of a connection is always new.** Established only after the reply. NAT rules see only that first packet, the rest is translated by conntrack (dstnat counter = 1 for a whole TCP session).
3. **dstnat happens before routing.** A forwarded packet goes to the forward chain, not input, so "drop new from WAN" needs the `!dstnat` exception and a port forward works without touching the input chain.
4. **dstnat keeps the client source IP.** In my test nginx logged 192.168.1.200: I was outside the LAN over NetBird (WireGuard), and the NetBird routing peer (CT 100) masquerades tunnel traffic. A second NAT in the path hides the client, not chr01.
5. **A WAN address from DHCP can change.** After a reboot chr01 moved from .102 to .251 and curl to the old address failed after ~3 s (ARP, not the firewall). Match port forwards on in-interface, not dst-address; in production use a static WAN or a DHCP reservation.
6. **A VLAN-aware bridge filters per port.** bridge-vids applies when a port is created, so a NIC that was attached before the change keeps only VLAN 1 until the VM restarts. Same idea as `switchport trunk allowed vlan` on Cisco.
7. **A VLAN subinterface is a separate interface for the firewall.** Traffic from vlan30 does not match in-interface=ether2. Interface lists (LAN) make new VLANs a one-line change.
8. **export vs backup.** Export is text without passwords, good for git and other routers. Backup is binary, full and tied to the same model and version. Loading it reboots the router, so it belongs in a maintenance window.
9. **IPv6-only DNS answers can hang apt.** deb.debian.org returned only AAAA records to the LAN client without IPv6; `apt-get -o Acquire::ForceIPv4=true` fixed it.

## Cisco equivalents

| RouterOS | Cisco IOS |
|----------|-----------|
| /ip dhcp-server + /ip pool | ip dhcp pool, network, default-router |
| srcnat masquerade out-interface=ether1 | ip nat inside source list 1 interface g0/1 overload |
| dstnat dst-port=8080 to 10.21.0.199:80 | ip nat inside source static tcp 10.21.0.199 80 interface g0/1 8080 |
| filter connection-state=established | zone-based firewall / reflexive ACL (classic ACLs are stateless) |
| /interface vlan vlan-id=30 interface=ether2 | interface g0/0.30, encapsulation dot1Q 30 |
| /interface list | no direct equivalent (object groups / zones) |
| /export, /system backup | show running-config, copy run tftp / archive |

## Next steps

- VLAN 30 with its own DHCP server and inter-VLAN firewall rules (LAN may not reach VLAN 30)
- WireGuard on RouterOS (site-to-site / road warrior)
- VRRP between two CHR VMs (failover test)
- Send RouterOS logs to Wazuh via remote syslog
