Subject: Repeatable UVM/pmap memory-corruption panics on riscv64 (JH7110/Milk-V Mars) under memory pressure

To: port-riscv@NetBSD.org

Hello,

I have several repeatable panics (three distinct manifestations) on NetBSD/riscv64 running on a Milk-V Mars
(StarFive JH7110, 4x SiFive U74, 8 GB RAM). All are in the UVM/pmap layer and appear under memory pressure
(one of them with no filesystem writes at all -- see Panic C). The kernel is an
unmodified official daily build, and GENERIC64 ships with `options
DIAGNOSTIC`, so these consistency checks are active on every -current
riscv64 kernel, not a custom debug build.

I would appreciate guidance on whether these are known, and I am happy to
run a ddb session, test patches, or gather more data on request.

## Environment

- Kernel: NetBSD 11.99.7 (GENERIC64) #0: Sat Jul 18 15:41:53 UTC 2026
    mkrepro@mkrepro.NetBSD.org:/usr/src/sys/arch/riscv/compile/GENERIC64
  (official daily gzimg build, unmodified; kernel not rebuilt by me)
- Board: Milk-V Mars, StarFive JH7110, 4x SiFive U74 @ 750 MHz, 8 GB LPDDR4
- Bootloader: mainline U-Boot 2025.01 -> OpenSBI -> bootriscv64.efi, with the
  in-tree jh7110-milkv-mars.dtb passed to the kernel
- Root: FFS on microSD (ld1/dwcmmc). SMP, all 4 harts running.

## Panic A -- pmap_segtab_activate assertion, from the pagedaemon

Occurs under memory pressure. Assertion is the KASSERTMSG in
pmap_segtab_activate() (sys/uvm/pmap/pmap_segtab.c:948):

    KASSERTMSG(pm == l->l_proc->p_vmspace->vm_map.pmap, "pm %p vs %p", ...)

Verbatim from serial console:

    panic: kernel diagnostic assertion "pm == l->l_proc->p_vmspace->vm_map.pmap" failed: file "/usr/src/sys/uvm/pmap/pmap_segtab.c", line 948 pm 0xffffffe050bd92c0 vs 0xffffffc000a2c768
    vpanic() at netbsd:vpanic+0x140
    kern_assert() at netbsd:kern_assert+0x3a
    pmap_update() at netbsd:pmap_update+0x50
    pmap_clear_attribute() at netbsd:pmap_clear_attribute+0xd8
    uvmpdpol_balancequeue() at netbsd:uvmpdpol_balancequeue+0x13a
    uvm_pageout() at netbsd:uvm_pageout+0x43a
    exception_kernexit() at netbsd:exception_kernexit+0x5e

Observation (hypothesis, not a conclusion): the call arrives from the
pagedaemon (uvm_pageout), which operates on foreign pmaps, while the
assertion requires the pmap being activated to equal curlwp's own vmspace
pmap. The failing `pm` (0xffffffe0_50bd92c0) lies in the direct-map region
(pmap_direct_base = 0xffffffe000000000) rather than where a struct pmap
would normally live, whereas the expected value (0xffffffc0_00a2c768) is in
the kernel VA range. Reading the source, the mechanism appears to be:

  1. pmap_remove_all(pm) sets PMAP_DEFERRED_ACTIVATE on a user pmap and
     releases its ASID, expecting the *owning* lwp to reactivate on its
     next pmap_update() (sys/uvm/pmap/pmap.c, pmap_update() lines ~965-972:
     "If pmap_remove_all was called, we deactivated ourselves ... Now we
     have to reactivate ourselves").
  2. Before that process runs again, the pagedaemon touches a page mapped
     in that pmap (pmap_clear_reference/attribute from uvmpdpol_balancequeue)
     and calls pmap_update(that_user_pmap).
  3. pmap_update() sees PMAP_DEFERRED_ACTIVATE and calls
     pmap_segtab_activate(that_user_pmap, curlwp), where curlwp is the
     pagedaemon.
  4. pmap_segtab_activate() asserts the pmap equals curlwp's own vmspace
     pmap, which is false (the pagedaemon's vmspace is the kernel's).

If that reading is right this is an MI issue in sys/uvm/pmap/ (shared with
mips and others), where pmap_update()'s "reactivate ourselves" path fires
for a pmap that is not curlwp's active pmap. It may only manifest on riscv64
in practice due to timing/ASID usage. This is distinct from the memory
corruption in Panic C. (Hypothesis from source reading; not yet confirmed in
ddb.)

## Panic B -- UBC hash/list corruption in ubc_alloc(), from ffs_write

This one is **reliably reproducible**: extracting any large (multi-hundred-MB,
many-file) tarball onto an FFS filesystem panics the machine. Observed at
least three times (pkgsrc-2026Q2 tarball twice, the Rust bootstrap tarball
once). Free space and uptime are irrelevant -- one instance had 25 GB free
after ~13 hours uptime.

The panic is the sys/queue.h back-pointer consistency check firing inside
LIST_REMOVE() in ubc_alloc()'s rehash path (sys/uvm/uvm_bio.c:538-539):

    LIST_REMOVE(umap, hash);
    LIST_REMOVE(umap, list);   /* <- line 539 */

Verbatim from serial console:

    panic: LIST_* back 0xffffffc0057d7360 /usr/src/sys/uvm/uvm_bio.c:539
    vpanic() at netbsd:vpanic+0x140
    panic() at netbsd:panic+0x24
    ubc_alloc.constprop.0() at netbsd:ubc_alloc.constprop.0+0x344
    ubc_uiomove() at netbsd:ubc_uiomove+0x7a
    ffs_write() at netbsd:ffs_write+0x210
    VOP_WRITE() at netbsd:VOP_WRITE+0x5a
    vn_write() at netbsd:vn_write+0xa0
    dofilewrite() at netbsd:dofilewrite+0x5e
    syscall() at netbsd:syscall+0xe8

A second instance reported uvm_bio.c:538 (LIST_REMOVE(umap, hash)) with an
otherwise identical backtrace, i.e. the same corrupted umap being unlinked.

Confirmed 2026-07-20 with ddb.onpanic=1 (interactive ddb on the serial
console), triggered by a `cargo build` (many concurrent ffs_write). Panic and
auto-backtrace verbatim:

    panic: LIST_* back 0xffffffc0057b9b40 /usr/src/sys/uvm/uvm_bio.c:538
    cpu2: Begin traceback...
    vpanic() at netbsd:vpanic+0x140
    panic() at netbsd:panic+0x24
    ubc_alloc.constprop.0() at netbsd:ubc_alloc.constprop.0+0x322
    ubc_uiomove() at netbsd:ubc_uiomove+0x7a
    ffs_write() at netbsd:ffs_write+0x210
    VOP_WRITE() at netbsd:VOP_WRITE+0x5a
    vn_write() at netbsd:vn_write+0xa0
    dofilewrite() at netbsd:dofilewrite+0x5e
    syscall() at netbsd:syscall+0xe8

I can reproduce this in ddb on demand and gather more state (ps, memory dump
of the corrupted umap, etc.) on request. I also have a GENERIC64_DEBUG kernel
(DEBUG + LOCKDEBUG + PMAP_DEBUG) cross-built and ready to boot for a
higher-resolution capture.

### Reproducer

    # on the target, root FFS on SD:
    ftp https://cdn.NetBSD.org/pub/pkgsrc/pkgsrc-2026Q2/pkgsrc.tar.gz
    tar xzf pkgsrc.tar.gz          # panics partway through extraction

Two-for-two on the pkgsrc tarball. The common factor is a high, sustained
rate of ffs_write() with UBC window churn.

## Panic C -- fatal load page fault on a 0x80-smeared pointer (memory corruption)

Occurred during a heavy Rust compile whose intermediate files were all in
tmpfs (i.e. NO bulk FFS writes -- this rules out ffs_write as the sole
trigger and points at memory pressure generally). cause=13 load page fault
in the kernel, recursing into a second fatal trap during traceback:

    panic: cpu_trap: fatal kernel trap
    Trapframe @ 0xffffffc2c3599e40 (cause=13 (load page fault), status=0x120, pc=0xffffffc000013900, va=0xffffff8080808078):
      ra =0xffffffc000013d48  ...
      a0 =0x808080bdbd26e0c8  a4 =0x8080808080808078  s2 =0x8080808080808078
    Skipping crash dump on recursive panic
    panic: cpu_trap: fatal kernel trap
    Faulted in mid-traceback; aborting...

The faulting VA and several registers (a4, s2, and the low bytes of a0) are
smeared with a repeating 0x80 byte pattern -- a corrupted pointer/structure
field. The kernel dereferenced it and took a load fault.

## Relationship between the three

All three fail under memory pressure on SMP riscv64, and Panic C's 0x80-byte
pointer smear is direct evidence of kernel memory corruption. Taken together
-- a pmap pointer that is wrong (A), a UBC list back-pointer that is wrong
(B), and a structure field smeared with 0x80 (C) -- these look like three
faces of a single memory-corruption root cause rather than three unrelated
bugs, though I leave that judgment to those who know the code. Panic B (the
tarball extraction) is by far the easiest to reproduce on demand.

## What I can provide

- A ddb backtrace with `bt`, `ps`, and register state. My rc currently sets
  ddb.onpanic=0 so the box reboots on panic; I can set ddb.onpanic=1 and
  reproduce Panic B on demand to capture a full ddb session.
- Testing of any diagnostic patch or DEBUG/LOCKDEBUG/UVMHIST kernel.
- I have not yet attempted to reproduce under qemu-system-riscv64; happy to
  try if it would help establish whether this is MI-riscv or JH7110-specific.

I also have a separate, unrelated issue on this board -- the `eqos` (DWC
EQOS) transmit path is limited to ~2.45 Mbit/s while receive runs at
388 Mbit/s -- which I am glad to report separately if useful.

Thanks for the RISC-V port; happy to help chase these down.

-- 
Alex Jokela

## Confirmed on NetBSD 11.0_RC7 (release branch), via tmpfs

The same panic reproduces on the **netbsd-11 release branch** (11.0_RC7,
GENERIC64, built 2026-07-22), so this is not a -current-only regression. It
also reproduces through **tmpfs**, not just FFS -- 4 concurrent
`tar xzf pkgsrc.tar.gz` loops into a tmpfs panicked the box in ~40 s:

    panic: LIST_* back 0xffffffc005ac4340 /usr/src/sys/uvm/uvm_bio.c:538
    ubc_alloc.constprop.0() at netbsd:ubc_alloc.constprop.0+0x532
    ubc_uiomove() at netbsd:ubc_uiomove+0x7a
    tmpfs_write() at netbsd:tmpfs_write+0xa4
    vn_write() at netbsd:vn_write+0xcc
    dofilewrite() at netbsd:dofilewrite+0x60
    syscall() at netbsd:syscall+0xea

So the corruption is in the UBC layer itself (ubc_alloc's umap hash/list
management), independent of the backing filesystem. ddb examine of the
corrupted umap showed it **largely zeroed**:

    db> x/x 0xffffffc005ac4340,c
    ffffffc005ac4340: 3ba20a00 ffffffe1 0 0 0 0 0 0 0 0 0 0

i.e. the umap being LIST_REMOVE'd has a mostly-zeroed body -- consistent with
a use-after-free / double-unlink of the umap, rather than the wild 0x80 write
of Panic C. These may be two views of one race in ubc_alloc/ubc_purge under
concurrent access, or distinct issues.

Source note: on the netbsd-11 branch, sys/uvm/uvm_bio.c is byte-identical to
HEAD, and the pmap deferred-activate/segtab_activate code (Panic A) is present
though pmap.c otherwise differs by ~400 lines from HEAD.
