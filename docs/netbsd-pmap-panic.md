# NetBSD/riscv64 UVM panics on StarFive JH7110 (MilkV Mars)

Draft material for a port-riscv@ / send-pr report. Captured over serial
console on 2026-07-19.

## Environment

- Board: MilkV Mars (StarFive JH7110, 4x SiFive U74, 8 GB RAM)
- Kernel: `NetBSD 11.99.7 (GENERIC64) #0: Sat Jul 18 15:41:53 UTC 2026`
  (mkrepro daily build of -current, riscv-riscv64)
- Boot chain: mainline U-Boot 2025.01 (Debian u-boot-starfive, VF2 build) →
  `bootriscv64.efi` → `/netbsd`, with `jh7110-milkv-mars.dtb` passed
  explicitly (`fdtfile` set via boot.scr)
- Root: FFS on SD (dk3), **102% full** at time of panic (first-boot resize
  had failed; heavy churn during `Building databases: dev`)

## Panic (verbatim from serial)

```
[  13.8099930] panic: kernel diagnostic assertion "pm == l->l_proc->p_vmspace->vm_map.pmap" failed: file "/usr/src/sys/uvm/pmap/pmap_segtab.c", line 948 pm 0xffffffe050bd92c0 vs 0xffffffc000a2c768
[  13.8299890] have_addr: true
[  13.8299890] addr: ffffffc2c10cfb90
[  13.8299890] count: 65535
[  13.8399887] modif:
[  13.8399887] trace fp ffffffc2c10cfb90
[  13.8399887] fp ffffffc2c10cfbd0 vpanic() at ffffffc000357940 netbsd:vpanic+0x140
[  13.8499920] fp ffffffc2c10cfbf0 kern_assert() at ffffffc0004801b6 netbsd:kern_assert+0x3a
[  13.8599887] fp ffffffc2c10cfc50 pmap_update() at ffffffc00001b848 netbsd:pmap_update+0x50
[  13.8699887] fp ffffffc2c10cfcd0 pmap_clear_attribute() at ffffffc00001b934 netbsd:pmap_clear_attribute+0xd8
[  13.8799892] fp ffffffc2c10cfdb0 uvmpdpol_balancequeue() at ffffffc0002df378 netbsd:uvmpdpol_balancequeue+0x13a
[  13.8899887] fp ffffffc2c10cfee0 uvm_pageout() at ffffffc0002de004 netbsd:uvm_pageout+0x43a
[  13.8999885] fp 0000000000000000 exception_kernexit() at ffffffc0000116de netbsd:exception_kernexit+0x5e
[  13.9099900] rebooting...
```

## Notes

- The assertion fires in the **pagedaemon** context (`uvm_pageout` →
  `uvmpdpol_balancequeue` → `pmap_clear_attribute` → `pmap_update`): the
  common pmap code asserts the pmap being updated is the current lwp's
  active pmap, which cannot hold for the pagedaemon walking arbitrary
  pmaps. Likely a MD/MI mismatch in the riscv `PMAP_SEGTAB`-based pmap's
  TLB update path rather than memory corruption.
- Trigger appears load/timing dependent: two earlier boots of the same
  kernel survived 5+ minutes of multiuser activity (including sshd and
  package I/O); this boot panicked at ~13.8 s during `Building databases`
  with the root filesystem over-full.
- Same kernel under QEMU (`-M virt`, 4 harts) boots and runs without
  incident, though with different memory pressure.
- Earlier boots on this board, which "went dark" minutes after boot with no
  console attached, are retroactively consistent with this panic followed by
  the (separately broken) SBI system reset hanging the board.

## To do

- Re-test with a newer -current daily.
- If reproducible, file send-pr with this trace; CC port-riscv@.

## Second occurrence (2026-07-19, different assertion, same subsystem)

Uptime ~54 min, during extraction of the pkgsrc tarball (heavy small-file
write load) onto SD. Root filesystem healthy and only ~7% full this time.

```
[ 3240.6254594] panic: LIST_* back 0xffffffc0057d87a0 /usr/src/sys/uvm/uvm_bio.c:538
[ 3240.6454595] trace fp ffffffc2c3402a20
[ 3240.6454595] fp ffffffc2c3402a60 vpanic() at netbsd:vpanic+0x140
[ 3240.6554638] fp ffffffc2c3402a80 panic() at netbsd:panic+0x24
[ 3240.6654601] fp ffffffc2c3402b40 ubc_alloc.constprop.0() at netbsd:ubc_alloc.constprop.0+0x322
[ 3240.6854605] fp ffffffc2c3402c40 ubc_uiomove() at netbsd:ubc_uiomove+0x7a
[ 3240.6954608] fp ffffffc2c3402d00 ffs_write() at netbsd:ffs_write+0x210
[ 3240.7054641] fp ffffffc2c3402d60 VOP_WRITE() at netbsd:VOP_WRITE+0x5a
[ 3240.7154632] fp ffffffc2c3402db0 vn_write() at netbsd:vn_write+0xa0
[ 3240.7254617] fp ffffffc2c3402e30 dofilewrite() at netbsd:dofilewrite+0x5e
[ 3240.7354620] fp ffffffc2c3402ee0 syscall() at netbsd:syscall+0xe8
```

Two distinct assertions (pmap_segtab active-pmap check; UBC list-integrity
check) both in the UVM layer under memory/IO pressure suggest a common
underlying riscv MD issue (TLB/pmap coherency?) rather than two separate
bugs. Both boots used the jh7110-milkv-mars.dtb from the same kernel build.

## Third occurrence (2026-07-20) — and a reliable reproducer

Extracting the 228 MB Rust bootstrap tarball (`tar xf`, ~1.5 GB of files)
onto the SD root panicked the kernel at the same place as the pkgsrc
extraction:

```
[ 48614.9107664] panic: LIST_* back 0xffffffc0057d7360 /usr/src/sys/uvm/uvm_bio.c:539
  vpanic <- panic <- ubc_alloc.constprop.0 <- ubc_uiomove <- ffs_write
  <- VOP_WRITE <- vn_write <- dofilewrite <- syscall
```

**Reproducer:** extract any large multi-hundred-MB tarball containing many
files onto an FFS filesystem on this board. Two for two so far (pkgsrc
tarball, Rust bootstrap tarball); uptime and free space are irrelevant (this
run had 25 GB free and the machine had been up ~13 hours).

The UBC (buffer cache) list-integrity assertion at `uvm_bio.c:538/539` fires
in `ubc_alloc()` under sustained `ffs_write()` pressure. The earlier
`pmap_segtab.c:948` panic in the pagedaemon is likely the same underlying
problem seen from a different angle: both are UVM structures being corrupted
or raced under memory pressure on riscv64.

### Practical consequence

Bulk writes to FFS on this port are unreliable. The workaround adopted here:
keep large read-mostly trees (pkgsrc, the Rust toolchain) on NFS and do
build-time writes in a tmpfs, so the FFS write path is never driven hard.
Note that NFS *writes* are also impractical on this board for a different
reason — see the `eqos` TX bug in `benchmarks-and-eqos-tx.md` (2.45 Mbit/s
outbound) — so tmpfs is the only fast writable scratch space available.

## Fourth occurrence (2026-07-20) -- memory-corruption load fault, NO FFS writes

During a Rust compile (ballistics-engine v0.27.1) built entirely in tmpfs --
source, CARGO_HOME, and target dir all in RAM, so ffs_write was not on the
hot path -- the kernel took a fatal load page fault on a corrupted pointer:

    Trapframe cause=13 (load page fault) va=0xffffff8080808078
      a4=0x8080808080808078  s2=0x8080808080808078  a0=0x808080bdbd26e0c8
    panic: cpu_trap: fatal kernel trap  (recursive; faulted mid-traceback)

The 0x80-byte smear across the faulting VA and several registers is a
corrupted structure field. This is important: it happened with the FFS write
path idle, so the earlier "keep bulk writes off FFS" workaround does NOT make
the machine safe -- the underlying bug is memory corruption under pressure,
and a large enough build (this one was compiling `ring`, heavy on RAM) can
trigger it even in tmpfs. Smaller builds (ballistics-engine v0.4.3) completed
in tmpfs without incident, so it is pressure/duration dependent.

## Retest on the fix (2026-08-05): assertion gone, corruption remains

Kernel: NetBSD 11.99.7 (GENERIC64) #0: Wed Aug 5 09:51:05 UTC 2026 (-current
daily), i.e. one week after skrll's pmap.c 1.107 ("Don't use pmap_update in
pmap_{page_protect,clear_attribute}... instead create a new pmap_shootdown").
pmap_shootdown is static and inlined, so it is absent from the symbol table;
presence verified by revision date and source, not by nm.

- The pmap_segtab.c:948 assertion has NOT recurred. 1.107 appears to fix it.
- The memory corruption is unchanged: panic ~20 s under the standard tmpfs
  reproducer (32 s on the previous kernel; not a meaningful difference,
  one sample each and this board now runs at 500 MHz, no clock ramp).

Panic was TAILQ_* forw 0xffffffc005804960 at uvm_bio.c:554 via ubc_alloc <-
ubc_uiomove <- tmpfs_write.

### Page-aligned damage (clearest evidence so far)

umap array 0xffffffc0057b9000 (0x1000 x 0x60), hash 0xffffffc005819000,
hashmask 0xfff.

The element in the panic message, umap[3225] @ 0xffffffc005804960, is itself
intact. QUEUEDEBUG's "forw" check dereferences the successor, umap[2354] @
0xffffffc0057f02c0, which is entirely zero. Boundaries:

    0xffffffc0057effe0  intact  (valid pointers, flags=2)
    0xffffffc0057f0000  zero    <- damaged page starts exactly here
    0xffffffc0057f0ff0  zero    <- and ends exactly here
    0xffffffc0057f1000  intact  (valid pointers)

Exactly one 4 KiB page of the umap array zeroed, neighbours untouched.

Same class as the earlier instance where a page of the UBC hash bucket array
held tmpfs file data; only the content written by the other owner differs
(file bytes then, zeroes now -- consistent with the page being reallocated
and zero-filled for a new owner).

Follow-up mail drafted in port-riscv-followup-still-corrupting.md.
