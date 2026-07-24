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

So the panic site is reachable independent of the backing filesystem. A full
ddb forensic session on this instance localized the corruption precisely.
With ubc_object.umap = 0xffffffc005ab9000 (0x1000 windows x 0x60 bytes,
array ends 0xffffffc005b19000 = hash table base, hashmask 0xfff, read out
of ubc_object in ddb), the panicking umap is umap[478]. Its full struct:

    uobj             0xffffffe13ba20a00   (tmpfs node, valid-looking)
    offset/writeoff/writelen  0
    refcount/flags/advice     0           (normal inactive state)
    hash.le_next     0
    hash.le_prev     0xffffffc005b06610   <-- see below
    inactive.tqe_next 0xffffffc005af58a0  (= umap[2583], sane)
    inactive.tqe_prev 0xffffffe23ea4d8c0  (= ubc_object.inactive[0], sane)
    list.le_next     0
    list.le_prev     0xffffffe13ba20a28   (= &uobj->uo_ubc)

The list linkage is provably intact: *0xffffffe13ba20a28 == the umap itself,
i.e. uobj->uo_ubc.lh_first still points at it. The umap body is a
self-consistent inactive umap. The ONLY inconsistency is the hash entry.

hash.le_prev does not point at a hash bucket at all -- it resolves to
umap[3301].hash.le_next (0xffffffc005b065e0 + 0x30), i.e. the umap was
chained in a bucket behind umap[3301]. And umap[3301] is the finding:

    db> x/x 0xffffffc005b065e0,18
    -> ALL 96 BYTES ZERO

An all-zero umap is not a legal state at any point after ubc_init(): every
umap is at minimum linked on an inactive TAILQ (tqe_prev can never be NULL),
and LIST_REMOVE/TAILQ_REMOVE never clear the removed entry's own fields.
Something wrote zeros over umap[3301] -- a static, boot-allocated kernel
array that is never freed -- while its bucket neighbor was chained after it.
Zeroing its hash.le_next is exactly what makes the neighbor's LIST_REMOVE
back-pointer check fire. So Panic B is not a UBC locking bug caught in the
act; it is the UBC DIAGNOSTIC check acting as a tripwire for a foreign
zeroing write over kernel memory. That unifies cleanly with Panic A (a pmap
pointer replaced by a wrong value) and Panic C (a pointer smeared with 0x80):
all three are reads of corrupted kernel memory, with different corruption
patterns, detected by whichever consistency check trips first.

Also captured at freeze time: a second tar process on another hart was
inside ubc_alloc (+0x66, early -- consistent with blocking on the
ubc_object writer lock, which is legal), so the path is under heavy
concurrent load when the tripwire fires, but the frozen lock/list state
itself does not show a locking violation.

## Single-CPU reproduction and zero-write forensics (2026-07-24)

Reproduced with **hw.ncpuonline=1** (cpuctl offline 1/2/3 on the same
11.0_RC7 kernel, same 4x tar-into-tmpfs workload): panicked within
~2 minutes. This eliminates every cross-CPU explanation for the corruption
itself -- rwlock exclusion failure, inter-hart TLB shootdown races,
concurrent ubc_alloc -- the corrupting writes happen with one CPU online.

    panic: TAILQ_* forw 0xffffffc005aea260 /usr/src/sys/uvm/uvm_bio.c:554
    ubc_alloc.constprop.0() at netbsd:ubc_alloc.constprop.0+0x762
    ubc_uiomove ... tmpfs_write ... (same call path as before)

That is the third distinct queue-integrity check to fire inside ubc_alloc
(LIST hash 538, LIST list 539, now TAILQ inactive 554) -- the checks are
tripwires, not suspects.

ddb forensics of this instance (umap array base 0xffffffc005ab9000,
0x60-byte umaps) mapped the corruption precisely. It is **scattered,
16-byte-aligned zero patches** over the static umap array, with valid data
between them:

    0x...a240,0x...a250  umap[2096] inactive+list entries zeroed (latent)
    0x...a260            umap[2097].uobj zeroed  <- the panicking umap
    0x...a300,0x...a310  umap[2098] inactive+list entries zeroed
                         (tqe_prev NULL is what fired TAILQ_* forw)
    0x...a320            umap[2099].uobj zeroed; its flags field 8 bytes
                         later still reads UMAP_MAPPING_CACHED (latent
                         KASSERT violation: uobj NULL + MAPPING_CACHED)
    0x...b5b0            umap[2148].hash.le_next zeroed (broke 2098's
                         hash chain)

Cross-checks proving these are foreign writes, not stale-but-legal state:
umap[2099].inactive.tqe_prev still correctly points at
&umap[2098].inactive.tqe_next, proving 2098 was legitimately queued when
its own tqe fields were wiped; and umap[2097]'s freshly-written
list.le_prev proves ubc_alloc had just stored a real uobj pointer into a
field that subsequently read NULL.

The signature -- 16-byte-aligned, 16-32 byte zero writes scattered across
physical memory, under I/O+memory pressure, independent of CPU count --
looks like **DMA descriptor/status writeback landing at stale or wrong
physical addresses**. struct eqos_dma_desc (dwc_eqos) is exactly 16 bytes
and the controller writes status back into ring slots; this board's eqos
already exhibits a severe TX-path misbehavior (~2.45 Mbit/s TX vs
388 Mbit/s RX, reported separately), so the driver/attachment is a proven
misbehaver on JH7110. tmpfs-only load still leaves eqos RX DMA active
(LAN broadcast traffic) and dwcmmc mostly idle.

## eqos exonerated; physical page double-use proven (2026-07-24, later)

Identical stressor with eqos0 administratively down (dhcpcd killed, no set
RUNNING flag, RX DMA ring stopped): panicked in ~40 s anyway
(LIST_* back, uvm_bio.c:538, umap[2226]). So the corrupting writes are
not eqos DMA either. Every partition so far: 4 CPUs or 1 CPU -- panics;
NIC up or down -- panics; FFS or tmpfs -- panics.

ddb forensics of this instance produced the decisive evidence. The
panicking umap's hash.le_prev pointed at hash bucket 1748
(0xffffffc005b1c6a0). Examining that bucket found not pointers but ASCII:

    x/x 0xffffffc005b1c690,8
    -> "/latex/europasscv/ic..."  (a pkgsrc pathname)

and the beginning of that kernel page:

    x/x 0xffffffc005b1c000,10
    -> "@comment $NetBSD: PL..."  (first line of a pkgsrc PLIST file)

The corruption is **page-boundary-delimited**: the previous page ends with
valid bucket pointers right up to 0xffffffc005b1bfff, the page at
0xffffffc005b1c000 contains a complete tmpfs file page (PLIST content
from file offset 0, zero-filled tail), and the next page is clean.

That is: **a physical page backing the kernel's UBC hash-bucket array
(kmem, allocated once at ubc_init and never freed) is simultaneously in
use as page 0 of a tmpfs file being extracted.** The file content reached
it by ordinary CPU copies (tmpfs-to-tmpfs extraction; no DMA in that data
path), so the fault is in physical page accounting/allocation, not in any
device driver: uvm_pagealloc handed out a page that kmem already owns.
The earlier "scattered zero patches" instances are consistent with the
same mechanism (file pages containing zero runs).

This explains every observation: victim structures are arbitrary
(whatever kmem object lives on the reused page -- umaps, pmaps (Panic A),
random pointers (Panic C)); reproduction needs sustained allocation churn
but not literal memory exhaustion (ddb show uvmexp at panic: 1,072,720
pages free of 2,025,557 total -- and note total pages match the 8 GB of
RAM, so there is no gross double-registration of whole RAM); CPU count
and DMA activity are irrelevant; and qemu (different memory map) never
reproduces.

Code audit so far (netbsd-11):
- riscv pte.h PA<->PTE macros: 64-bit clean, no truncation.
- cpu_kernel_vm_init direct-map gigapage loop: correct for this memory
  map (slots 385-392 covering PA 0x40000000-0x240000000).
- RISCV_PA_TO_KVA/KVA_TO_PA: clean for a 128 GiB window.
- UBC's PMAP_DIRECT fast path: compiled out on riscv (PMAP_DIRECT is
  never defined; only PMAP_DIRECT_MAP/_UNMAP exist), so file writes go
  through UBC windows via pmap_kenter_pa(VM_PAGE_TO_PHYS(pg)) -- the bad
  PA comes from the allocated page itself.
- Found while auditing (probably unrelated to this bug, but a real API
  misuse): riscv_machdep.c passes an END address as the SIZE argument:
      fdt_memory_remove_range(msgbufaddr, msgbufaddr + MSGBUFSIZE);
  where the API is fdt_memory_remove_range(start, size). Benign by
  accident because msgbuf is taken from the top of RAM (the over-large
  range clamps), but it should be msgbufaddr, MSGBUFSIZE.

Working hypothesis: a small number of physical pages are doubly tracked
from boot (a seam between bootstrap-time reservations and
uvm_page_physload ranges, or bootstrap memory returned to UVM while still
referenced), and the first reuse under churn corrupts allocator/kmem
state, snowballing into the observed variety of panics.

Planned next step: an instrumented kernel that records the physical
addresses of the ubc_init allocations and KASSERTs in uvm_pagealloc that
none of them is ever handed out again -- catching the double-allocation
at the moment it happens, with a backtrace of the guilty path.

Source note: on the netbsd-11 branch, sys/uvm/uvm_bio.c is byte-identical to
HEAD, and the pmap deferred-activate/segtab_activate code (Panic A) is present
though pmap.c otherwise differs by ~400 lines from HEAD.
