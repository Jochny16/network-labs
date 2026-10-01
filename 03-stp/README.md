# Lab 03 – Spanning Tree Protocol (STP)

Three Linux bridges with kernel STP, cabled in a triangle. Redundant links create an L2 loop; STP elects a root bridge, blocks one port, and unblocks it when the active path fails.

## Topology

             sw1 (02:..:30)
        s12 /     \ s13   <- blocked
       s21 /       \ s31
        sw2 ------- sw3 (02:..:20)
       ROOT  s23 s32
      (02:..:10)

All bridges use the default priority (32768), so the bridge with the lowest MAC address wins.

## Run

    sudo -i
    ./stp-lab.sh up        # build + show port states
    ./stp-lab.sh fail      # cut sw1-sw2, watch s13 transition
    ./stp-lab.sh restore   # link back, s13 blocks again
    ./stp-lab.sh down

## Results

| Step | Observation |
|---|---|
| Converged | Root bridge = sw2 (lowest bridge ID). All ports forwarding except **s13 (sw1 → sw3): blocking** |
| Cut sw1–sw2 | s13: blocking → listening → learning → forwarding in ~8 s (shortened timers) |
| Restore | s12 forwarding again, s13 back to blocking – the tree returns to the best path |

## What I learned

1. **Why STP exists.** Ethernet frames have no TTL. Without STP, a broadcast in a loop circulates forever and multiplies (broadcast storm, MAC flapping), taking the network down.
2. **Root bridge election.** Lowest bridge ID (priority + MAC) wins. The root never blocks its ports.
3. **Which port blocks.** On the redundant link (here sw1–sw3, since both have a direct path to the root), the side with the higher bridge ID blocks – sw1, port s13.
4. **Port roles.** Root port (best path to root), designated port (forwards on a segment), alternate/blocking (standby).
5. **Convergence is slow in classic STP.** A blocked port goes through listening and learning before forwarding. Default timers: ~30 s (up to ~50 s for indirect failures). This is why RSTP (802.1w) is used in practice.

## Cisco equivalents

| This lab | Cisco IOS |
|---|---|
| `stp_state 1` | `spanning-tree mode pvst` (default) |
| bridge MAC / priority | `spanning-tree vlan 1 priority 4096` |
| `bridge link show` (state) | `show spanning-tree` |
| `forward_delay 400` | `spanning-tree vlan 1 forward-time 4` |

## Next steps

- Force sw3 to become root by lowering its priority and predict the new blocked port.
- RSTP: compare convergence time (needs `mstpd` on Linux, or Cisco IOS in EVE-NG / Packet Tracer).
