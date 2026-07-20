# Benchmarks: NetBSD vs vendor Debian on identical Milk-V Mars hardware

Two Milk-V Mars boards, same JH7110 silicon, measured 2026-07-20.

- **10.1.1.17** — NetBSD-current 11.99.7, mainline U-Boot 2025.01, CPU 750 MHz
  (raised from the 500 MHz mainline reset clock by our firmware's bootcmd;
  NetBSD has no cpufreq driver for this SoC, so the boot clock is the clock)
- **10.1.1.26** — vendor Debian bookworm, Linux 5.15, CPU up to 1500 MHz via
  cpufreq `ondemand`

## CPU and memory

| Test | NetBSD @ 750 MHz | Debian @ 1500 MHz | Ratio | Per-clock |
|------|------------------|-------------------|-------|-----------|
| OpenSSL sha256 (16 KB) | 19.7 MB/s | 35.2 MB/s | 1.79× | NetBSD ahead |
| OpenSSL aes-256-cbc (16 KB) | 16.7 MB/s | 25.1 MB/s | 1.50× | NetBSD ahead |
| OpenSSL rsa2048 sign/s | 52.3 | 63.5 | 1.21× | NetBSD well ahead |
| gzip -9, 1 GB of zeros | 70 s | 34 s | 2.06× | parity |
| dd zero→null, 4 GB | 734 MB/s | 2.3 GB/s | 3.13× | **NetBSD behind** |

The clock ratio is 2.0×. Anything below that means NetBSD does more work per
cycle (its OpenSSL is much newer, which explains the RSA gap). The outlier is
the memory-path `dd`: 3.13× against a 2.0× clock difference implies roughly
1.5× less memory bandwidth, which likely means mainline U-Boot's SPL also
configures DDR more conservatively than the vendor firmware. Not yet
investigated.

Caveats: OpenSSL versions differ (NetBSD 3.x-current vs Debian 3.0.7), gzip
implementations differ, and SD-card write tests were dropped from this table
because the two boards have different cards.

## Network: the eqos transmit bug

**NetBSD's `eqos0` transmit path is capped at ~2.45 Mbit/s. Receive runs at
388 Mbit/s.** A 158× asymmetry on the same interface.

| Direction | Throughput |
|-----------|-----------|
| NetBSD → Debian (NetBSD TX) | 2.45 Mbit/s |
| Debian → NetBSD (NetBSD RX) | 388 Mbit/s |

Measured with iperf 2.1.9 (NetBSD, pkgsrc) and iperf 2.1.7 (Debian), TCP and
UDP, repeatedly, in both directions.

### Evidence that this is a driver bug, not congestion

- **UDP shows the same cap with zero loss.** Asking for 100 Mbit/s delivered
  2.46 Mbit/s, `0/1684 (0%)` datagrams lost. The receiver got everything the
  sender emitted; the sender could not emit faster.
- **No retransmits, no checksum errors.** `netstat -s -p tcp` after a full
  transfer: `0 data packets retransmitted`, `0 discarded for bad checksums`,
  `0 retransmit timeouts`.
- **The link is healthy.** `1000baseT full-duplex`, ping RTT 0.4–0.5 ms,
  0% ICMP loss, and the same cable/switch path carries 388 Mbit/s inbound.
- **TX completion interrupts are far too rare.** Over a 5-second transfer:

  ```
  =IRQ BEFORE=            =IRQ AFTER=
  eqos0 interrupts 337140  eqos0 interrupts 337220   (+80)
  eqos0 rxintr     326213  eqos0 rxintr     326227   (+14)
  eqos0 txintr      11184  eqos0 txintr      11250   (+66)
  ```

  66 TX interrupts in 5 seconds ≈ 13 Hz, while ~1050 packets were sent —
  about 16 packets drained per interrupt. Observed rate ≈ 209 packets/sec ≈
  (TX ring depth) × 13 Hz, i.e. throughput is gated by how often completed
  descriptors are reclaimed, not by the wire.

The shape of this says TX descriptors are being reclaimed on a slow periodic
event rather than on per-completion interrupts: the ring fills, transmission
stalls until the next reclaim, repeat.

### Why it went unnoticed for so long

Everything interactive works fine, so the board feels healthy: ssh, ping,
DNS, and `pkgin` package installs are all either small-packet or
receive-dominated. Only bulk *outbound* transfer exposes it.

### To do

- Report to port-riscv@ alongside the UVM panics (see
  `netbsd-pmap-panic.md`).
- Compare `sys/dev/fdt/eqos*` TX interrupt enable / coalescing setup against
  the Linux `stmmac` driver's for this SoC.
- Re-test on a newer -current daily.
