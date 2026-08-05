# Agent handoff: NetBSD on the Milk-V Mars

Read this before touching anything. It exists so you do not have to re-derive
a week of debugging.

## What this repo is

Scripts that build a bootable NetBSD-current microSD image for a Milk-V Mars
(StarFive JH7110, 4x SiFive U74, 8 GB). The image build works and is done.
`build-image.sh`, `build-uboot.sh`, `customize-image.sh`. See README.md.

## The open problem

**NetBSD/riscv64 corrupts kernel memory under sustained write load on this
board.** Reported to port-riscv@; still unsolved. Full history in
`docs/netbsd-pmap-panic.md`, the original report in
`docs/port-riscv-panic-report.md`, latest findings in
`docs/port-riscv-followup-still-corrupting.md`. Read all three.

Short version: a physical page owned by kmem (it backs the UBC umap/hash
arrays, allocated once at ubc_init and never freed) gets handed out again to
another owner. Evidence is page-aligned: exactly one 4 KiB page of the umap
array is either overwritten with tmpfs file data or zero-filled, with the
pages either side intact. Best guess is that some pages end up tracked twice
between the boot-time reservations and what reaches uvm_page_physload, but
the seam has not been found.

skrll (Nick Hudson) fixed a *separate* bug that fired in the same storm
(pmap.c 1.107, the pmap_segtab.c:948 assertion via pmap_update's deferred
activate). That assertion is gone. The corruption is not.

## Machines

| Host | Address | Role | Login |
|---|---|---|---|
| Mars board | 10.1.1.32 (DHCP, changes) | the subject | `ssh root@` with the Mac's `~/.ssh/id_ed25519` |
| rpi5-2 | 10.1.1.11 | serial console host, USB-UART at `/dev/ttyUSB0` | `ssh alex@` |
| bosgame | 10.1.1.27 | Linux build host, 32 cores, NetBSD cross-build tree in `~/netbsd-src` | `ssh alex@` |
| fileserver | 10.1.1.18 | NFS, hosts pkgsrc + a riscv64 Rust toolchain on `/nvme0/riscv64` | `ssh alex@` |
| router | 10.1.1.1 | MikroTik, use it to find the board's current lease | ssh admin@, password in shell history |

**The board's IP changes on every boot.** Its EEPROM is blank so NetBSD
generates a random MAC each time. Find it via the router:
`/ip dhcp-server lease print without-paging where last-seen<5m`

## Hard constraints — read these or waste hours

1. **The board cannot reboot itself.** `reboot` syncs, unmounts, prints
   `rebooting...`, then hangs forever at `pmic_ops: cannot read pmic power
   register` (firmware can't drive the Mars PMIC). **Every restart needs a
   human to physically power cycle.** This is the main limit on autonomous
   work: you get one boot per human intervention. Batch everything you want
   to do into each boot, and stage files *before* triggering a reboot.
2. **Outbound network is ~2.45 Mbit/s** (eqos TX driver bug, receive is
   388 Mbit/s). Downloads to the board are fine; uploads from it are not.
   See `docs/benchmarks-and-eqos-tx.md`.
3. **The root filesystem does not auto-grow** (`gpt: /dev/rld1: Can't
   delete, next map is in use`) and ships 102% full. Do work in tmpfs.
4. **NetBSD has no `setsid`.** Backgrounded work started over ssh dies when
   the session ends. Either hold the ssh session open from your side, or use
   a script that ends in `wait`.
5. Root's PATH lacks `/sbin` and `/usr/sbin` in non-interactive ssh. Use
   absolute paths (`/sbin/sysctl`, `/sbin/mount`, `/bin/df`).

## Serial console

The only way to see panics. Set it up before any test:

```sh
ssh alex@10.1.1.11 'pkill -f "ca[t] /dev/ttyUSB0"; \
  stty -F /dev/ttyUSB0 115200 cs8 -parenb -cstopb raw -echo -ixon -ixoff -crtscts clocal'
# then hold a capture open, with reconnect:
while true; do ssh alex@10.1.1.11 'exec cat /dev/ttyUSB0' >> /tmp/mars-serial.log; sleep 3; done
```

`clocal` is not optional — without it every write to the port blocks forever.
Send input with `ssh alex@10.1.1.11 "printf 'cmd\r' > /dev/ttyUSB0"`.

## ddb rules

`sysctl -w ddb.onpanic=1` before a test to halt in the debugger instead of
rebooting (rc sets it to 0 at boot).

- **First thing in ddb: `set $lines 0`.** Otherwise the pager emits
  `--db_more--` and eats your output.
- **Never type `q` at the `db{N}>` prompt.** At the main prompt it quits the
  debugger, which post-panic means reboot, which means a lost session and a
  wasted power cycle. (Learned the hard way.)
- `x/x <addr>,<count>` dumps 4-byte words.

## Reproducer

Panics in 20-40 seconds. Everything in tmpfs, no disk writes needed:

```sh
/sbin/mount -t tmpfs -o -s=6g tmpfs /mnt
cd /mnt && ftp -o pkgsrc.tar.gz https://cdn.NetBSD.org/pub/pkgsrc/pkgsrc-2026Q2/pkgsrc.tar.gz
for w in 1 2 3 4; do mkdir -p /mnt/w$w; \
  ( cd /mnt/w$w && while :; do rm -rf pkgsrc; tar xzf /mnt/pkgsrc.tar.gz; done ) & done
wait
```

A *light* workload does not reproduce (4 workers copying /usr/share survived
15 minutes). It appears to need several GB actually in use, which may matter:
reaching pages above the 4 GB line seems to require consuming enough memory
to get there.

## Already ruled out — do not redo these

- SMP races: reproduces with `hw.ncpuonline=1`
- NIC DMA: reproduces with eqos0 down
- Filesystem: reproduces via both tmpfs_write and ffs_write
- Memory exhaustion: `show uvmexp` showed plenty free
- MI-only bug: does **not** reproduce under `qemu -M virt`
- The `fdt_memory_remove_range` size/end bugs: real, fixed upstream
  (riscv_machdep.c 1.51, pulled up to netbsd-11 as ticket #400), but they
  were benign here and did not fix anything
- The direct map: the gigapage loop in `cpu_kernel_vm_init` correctly covers
  0x40000000-0x240000000 (indices 385-392); verified by hand

## Built and staged, never tested

On the Mac in the session scratchpad (rebuild if gone):

- `netbsd.4gb` — HEAD GENERIC64 with `memory_limit` clamped to 0x100000000,
  to test skrll's suggestion that memory above the 4 GB line is implicated.
  Clamp verified working in QEMU (reports 2035 MB where the control reports
  8179 MB). **Caveat:** the clamped kernel only has ~3 GB, so it cannot run
  the 6 GB reproducer. You need a workload that fits and still panics an
  8 GB machine, or you are comparing nothing. Run the control first.
- `netbsd.fix` — same HEAD build without the clamp, as the control.
- `fw2024/` — U-Boot 2024.04 + OpenSBI 1.4, matching the firmware skrll runs
  on his VisionFive 2 where a DEBUG+LOCKDEBUG kernel boots fine. Ours (2025.01
  + OpenSBI 1.6) fails LOCKDEBUG boot with an unhandled machine software
  interrupt on secondary hart bringup. Flash to wedges dk0 (spl) and dk1
  (uboot) from the running system; back up first.

## Kernel cross-builds

Fast (~1 min for a kernel) on bosgame:

```sh
ssh alex@10.1.1.27
cd ~/netbsd-src   # CVS checkout; update with cvs, the GitHub mirror lags days
./build.sh -m riscv64 -U -j32 -O ~/netbsd-obj -T ~/netbsd-tools kernel=GENERIC64
```

`GENERIC64_DEBUG` (DEBUG + LOCKDEBUG + PMAP_DEBUG) exists but **does not boot
on this board** — see the firmware note above.

## Suggested next steps

1. The instrumented kernel Alex proposed to port-riscv and never built:
   record the physical pages backing the `ubc_init` allocations, then assert
   in `uvm_pagealloc` if one of them is ever handed out again. That catches
   the double allocation in the act with a backtrace of the guilty path.
   This is probably the highest-value experiment available.
2. The 4 GB clamp test (see caveat above).
3. The firmware A/B, which might also unblock LOCKDEBUG.

## Safety

- **Confirm with the human before any `dd` to a disk.** The Mac has many
  external volumes; the SD card has been `/dev/disk29` but that is not
  stable. Identify by GPT type GUID (`2E54B353-…` = the StarFive SPL
  partition), not by size or index.
- Do not push to `origin` without being asked.
- Commit messages: no AI attribution (see the user's global CLAUDE.md).
