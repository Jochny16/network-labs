# Lab 16: Port security on a Cisco 2960 (Packet Tracer)

Port security limits which source MAC addresses may send frames into an access port. In this lab one switch port is locked to a single sticky MAC address, then a second device (the "intruder") is plugged into the same port. The three violation modes (shutdown, restrict, protect) are compared by what the switch does with the port, the log and the violation counter.


## Topology

        PC0 192.168.10.1/24          PC1 192.168.10.2/24
        (legitimate device)                  |
              |                              |
           Fa0/1 ---------- SW1 ---------- Fa0/2
           (port security,  2960
            max 1 MAC,
            sticky)
              |
        intruder 192.168.10.3/24
        (plugged into Fa0/1 after PC0 is unplugged)

One VLAN (VLAN 1), one subnet, no router. Pings go from PC0 or the intruder to PC1.

## Run

Base configuration on SW1:

    configure terminal
    no ip domain-lookup
    interface fa0/1
     switchport mode access
     switchport port-security
     switchport port-security mac-address sticky
    end

Defaults that apply without extra commands: maximum 1 MAC address, violation mode shutdown.

Changing the violation mode:

    interface fa0/1
     switchport port-security violation restrict
     switchport port-security violation protect

Recovering a port from err-disabled:

    interface fa0/1
     shutdown
     no shutdown

Checking the result:

    show port-security interface fa0/1
    show running-config
    show ip interface brief

## Results

| Step | What was done | Result |
|---|---|---|
| 1 | switchport port-security on a port in the default dynamic mode | Command rejected: FastEthernet0/1 is a dynamic port |
| 2 | switchport mode access, then port security + sticky | Port Security Enabled, Secure-up, Total MAC 0 |
| 3 | Ping PC0 to PC1 | Sticky MAC 1; running-config gets "switchport port-security mac-address sticky 000D.BDC1.4E0D" |
| 4 | PC0 unplugged, intruder on Fa0/1, mode shutdown | Ping times out; Secure-shutdown, Fa0/1 down/down, violation count 1; log PM-4-ERR_DISABLE and PORT_SECURITY-2-PSECURE_VIOLATION |
| 5 | shutdown / no shutdown with the intruder still plugged in | Port goes Secure-up with count 0, then back to Secure-shutdown (count 1) on the intruder's first frame |
| 6 | Mode restrict, intruder pings | Port stays Secure-up, ping fails, violation count 4, one PSECURE_VIOLATION log line per dropped frame |
| 7 | clear port-security all | Sticky MAC of PC0 erased (Total 0), violation count unchanged (4) |
| 8 | Intruder pings again | Ping succeeds; the intruder's MAC 0030.A390.C698 becomes the new sticky address |
| 9 | Mode protect, a different PC pings from Fa0/1 | Port stays Secure-up, ping fails, no log, violation count stays 0; Last Source Address shows the dropped MAC |

## What I learned

1. **Port security needs a static access port.** A port in dynamic mode can negotiate a trunk with DTP, and a trunk carries many MAC addresses from many VLANs, so IOS rejects the command until switchport mode access is set.
2. **Sticky learns the source MAC of frames entering the port.** The learned address is written to running-config only. Without copy running-config startup-config it is lost after a reload.
3. **The first frame from a new device is ARP, not the ping.** With restrict the counter went up by 4 for 4 pings, because each ping attempt started with an ARP request that was dropped. The ICMP packet never left the intruder.
4. **shutdown puts the whole port in err-disabled.** Even the legitimate device is cut off. The port does not recover by itself; shutdown / no shutdown brings it up, but it fails again as soon as the unknown MAC sends a frame. Remove the cause first, then recover the port.
5. **restrict keeps the port up and logs every violation.** Good for monitoring: the SOC sees the MAC address and the port in syslog.
6. **protect drops silently.** No log, no counter. From a monitoring point of view it is the weakest mode.
7. **clear port-security removes learned addresses, not the counter.** Running it while the wrong device is plugged in hands the port to that device: the intruder became the sticky owner.
8. **Last Source Address is not the secure address.** It is only the last source MAC the switch saw on the port, including dropped frames. The secure (sticky) address is in running-config.
9. **no ip domain-lookup saves time.** A mistyped command in privileged EXEC mode is treated as a hostname and IOS waits for a DNS lookup.

## Mode comparison

| Mode | Frames from an unknown MAC | Log and counter | Port |
|---|---|---|---|
| shutdown (default) | dropped | yes | err-disabled, manual recovery |
| restrict | dropped | yes, per frame | stays up |
| protect | dropped | no | stays up |

## Production vs lab

- In production, errdisable recovery cause psecure-violation with an interval can bring ports back automatically. That is convenient but also lets an attacker retry every interval.
- Sticky addresses must be saved with copy running-config startup-config, or the port learns from scratch after a reload.
- Maximum 2 or 3 is common where an IP phone and a PC share one port.
- Port security only checks the source MAC. MAC spoofing (copying the legitimate MAC) defeats it; 802.1X is the stronger control.
- Restrict plus syslog to a SIEM (for example Wazuh from labs 11-13) turns violations into alerts.

## Packet Tracer notes

- On KDE with a dark colour scheme, device labels are white on white. Fix: launch Packet Tracer with XDG_CURRENT_DESKTOP=GNOME (set it in the application launcher's environment variables).
- This IOS version does not support show running-config interface; use show running-config.

## Next steps

- errdisable recovery and the aging timer.
- Maximum 2 with a second MAC address on the port.
- DHCP snooping and Dynamic ARP Inspection on Cisco IOS.
