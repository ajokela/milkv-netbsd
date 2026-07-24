Subject: riscv64/JH7110: repeatable kernel memory corruption; kmem page handed out again as a tmpfs data page

To: port-riscv@NetBSD.org

Hello,

I have been chasing repeatable UVM panics on a Milk-V Mars (StarFive JH7110) and I think I have found what they have in common. Under sustained write load the kernel corrupts its own memory, and in ddb I found a physical page that is in use by kmem (it backs the UBC hash table, allocated once at ubc_init and never freed) while simultaneously holding page 0 of a tmpfs file that tar was extracting at the time. The file bytes got there through ordinary CPU copies, no DMA is involved in that data path, so as far as I can tell uvm_pagealloc handed out a page that kmem already owns. I can reproduce this in about a minute and am happy to run ddb sessions, test patches, or build instrumented kernels.

Environment:

- Milk-V Mars, StarFive JH7110, 4x SiFive U74, 8 GB LPDDR4. RAM is at PA 0x40000000 to 0x240000000, so about 5 GB of it sits above the 4 GB line.
- NetBSD 11.0_RC7 (GENERIC64) #0: Wed Jul 22 05:26:24 UTC 2026, unmodified mkrepro build. First seen on the 11.99.7 -current daily of Jul 18, so both HEAD and the netbsd-11 branch are affected.
- Boot chain: mainline U-Boot 2025.01 with OpenSBI, then bootriscv64.efi; the kernel gets the in-tree jh7110-milkv-mars.dtb.
- GENERIC64 ships with DIAGNOSTIC, which is what turns the corruption into visible panics.

Reproducer:

    mount -t tmpfs -o -s=6g tmpfs /mnt
    cd /mnt
    ftp https://cdn.NetBSD.org/pub/pkgsrc/pkgsrc-2026Q2/pkgsrc.tar.gz
    for w in 1 2 3 4; do mkdir -p w$w; ( cd w$w && while :; do rm -rf pkgsrc; tar xzf ../pkgsrc.tar.gz; done ) & done

This panics in roughly 40 seconds. A single extraction of the same tarball onto FFS on the SD card also panics, it just takes longer. Uptime and free space do not matter.

The panics take three forms. By far the most common is a queue consistency check firing in ubc_alloc(); I have seen the uvm_bio.c line 538 and 539 LIST_* checks and the line 554 TAILQ_* check, via both tmpfs_write and ffs_write. A representative one:

    [ 248.5299832] panic: LIST_* back 0xffffffc005ac4340 /usr/src/sys/uvm/uvm_bio.c:538
    ubc_alloc.constprop.0() at netbsd:ubc_alloc.constprop.0+0x532
    ubc_uiomove() at netbsd:ubc_uiomove+0x7a
    tmpfs_write() at netbsd:tmpfs_write+0xa4
    vn_write() at netbsd:vn_write+0xcc
    dofilewrite() at netbsd:dofilewrite+0x60
    syscall() at netbsd:syscall+0xea

Second, under pagedaemon activity on the -current daily:

    panic: kernel diagnostic assertion "pm == l->l_proc->p_vmspace->vm_map.pmap" failed: file "/usr/src/sys/uvm/pmap/pmap_segtab.c", line 948 pm 0xffffffe050bd92c0 vs 0xffffffc000a2c768
    pmap_update() at netbsd:pmap_update+0x50
    pmap_clear_attribute() at netbsd:pmap_clear_attribute+0xd8
    uvmpdpol_balancequeue() at netbsd:uvmpdpol_balancequeue+0x13a
    uvm_pageout() at netbsd:uvm_pageout+0x43a

Third, once, a fatal load fault on a pointer whose bytes had been replaced with 0x80 fill, during a build whose working set was entirely in tmpfs:

    Trapframe @ 0xffffffc2c3599e40 (cause=13 (load page fault), status=0x120, pc=0xffffffc000013900, va=0xffffff8080808078):
      a0 =0x808080bdbd26e0c8  a4 =0x8080808080808078  s2 =0x8080808080808078

All three are what you would expect from reads of kmem pages that have been overwritten with unrelated data, and I now believe that is exactly what they are.

The direct evidence. In the most recent ddb session (RC7, the panic was LIST_* back 0xffffffc005aed2c0 at uvm_bio.c:538), reading ubc_object gave the umap array at 0xffffffc005ab9000 (0x1000 entries of 0x60 bytes, ending at 0xffffffc005b19000) and the hash bucket array at 0xffffffc005b19000 with hashmask 0xfff. The panicking umap looked like a normal inactive umap whose hash.le_prev pointed at the bucket at 0xffffffc005b1c6a0. That bucket does not contain pointers:

    db{1}> x/x 0xffffffc005b1c690,8
    ffffffc005b1c690:       74616c2f    652f7865    706f7275    63737361    63692f76

which is little-endian ASCII for "/latex/europasscv/ic". The start of the same kernel page:

    db{1}> x/x 0xffffffc005b1c000,10
    ffffffc005b1c000:       6d6f6340    746e656d    654e2420    44534274    4c50203a

That is "@comment $NetBSD: PL", the first line of a pkgsrc PLIST file, at file offset 0, at page offset 0. The damage stops exactly at page boundaries. The end of the previous page still holds valid bucket pointers (0xffffffc005ac0200 and 0xffffffc005b01300 below are umap addresses):

    db{1}> x/x 0xffffffc005b1bfe0,8
    ffffffc005b1bfe0:       0           0           5ac0200     ffffffc0    5b01300
    ffffffc005b1bff4:       ffffffc0    0           0

The tail of the PLIST page is zero fill past EOF and the page after it is normal. So one physical page holds part of the UBC hash bucket array and page 0 of a tmpfs file at the same time. Extracting a tarball from tmpfs to tmpfs moves data with CPU copies through UBC windows (PMAP_DIRECT is not defined on riscv, so ubc_uiomove_direct is compiled out), the window PTEs are built from VM_PAGE_TO_PHYS of whatever page uvm_pagealloc returned, and no device DMA touches this path. I do not see how the file bytes could land on that page unless the allocator handed out kmem's page a second time.

A second instrumented look at an earlier instance points the same way. With hw.ncpuonline=1 the panic was TAILQ_* forw 0xffffffc005aea260 at uvm_bio.c:554, and the umap array around the victim contained several 16-byte-aligned runs of zeros with intact data between them: umap[2098] had a valid uobj and flags but zeroed inactive and list entries (its zeroed tqe_prev is what fired the check), and umap[2097] and umap[2099] each had a zeroed uobj. Two details show these were foreign writes rather than stale state: umap[2099].inactive.tqe_prev still pointed correctly at &umap[2098].inactive.tqe_next, so 2098 was legitimately queued when its fields were wiped; and umap[2097]'s freshly written list.le_prev proved ubc_alloc had just stored a real uobj pointer into the field that then read NULL. Zero runs are unsurprising if the overwriting pages are file data, since plenty of tarball content is zeros.

Things I have ruled out:

- SMP races: reproduces with cpuctl offline 1, 2, 3 (hw.ncpuonline=1).
- NIC DMA: reproduces with dhcpcd killed and eqos0 down.
- The filesystem: reproduces via both tmpfs_write and ffs_write.
- Memory exhaustion: show uvmexp at one panic reported 2025557 pages total and 1072720 free. The total matches the 8 GB, so RAM is not being registered twice wholesale. What does matter is churn: quiet boots survive indefinitely, and the corruption shows up once a few GB of pages have been cycled through the allocator.
- The same kernel under qemu -M virt (4 harts) does not reproduce, which fits a machine-dependent memory accounting problem rather than an MI bug.

Code I have read while chasing this (netbsd-11; uvm_bio.c is byte-identical to HEAD): the pte.h PA/PTE macros, the direct map setup in cpu_kernel_vm_init (the gigapage loop covers 0x40000000 to 0x240000000 correctly for this DTB), RISCV_PA_TO_KVA / RISCV_KVA_TO_PA, and the riscv membar ops all look correct to me, so I do not think the bad address is manufactured at map or copy time. My working guess is that some pages end up tracked twice somewhere in the boot path (bootstrap reservations versus what gets handed to uvm_page_physload), and that the first reuse corrupts allocator or kmem state and snowballs, which would explain the variety of victims. I have not found the seam yet.

One unrelated thing I noticed while auditing riscv_machdep.c: the msgbuf reservation passes an end address where fdt_memory_remove_range() takes a size:

    fdt_memory_remove_range(msgbufaddr, msgbufaddr + MSGBUFSIZE);

Harmless by accident, since msgbuf is taken from the top of RAM and the oversized range clamps, but it presumably wants to be MSGBUFSIZE.

The pmap_segtab panic above may also have an independent component: pmap_update()'s deferred-activate path calls pmap_segtab_activate(pm, curlwp) for whatever pmap is being updated, and when the pagedaemon calls pmap_update() on a user pmap with PMAP_DEFERRED_ACTIVATE pending, the assertion that pm equals curlwp's own vmspace pmap cannot hold. I mention it in case it is a separate MI issue, though the wrong pointer value I saw also fits the corruption.

Next I plan to build a kernel that records the physical pages backing the ubc_init allocations and asserts in uvm_pagealloc that none of them is ever handed out again, to catch the double allocation in the act with a backtrace of the guilty path. If someone who knows the riscv boot memory accounting has a better idea of where to look, I am glad to test patches; the reproducer is fast and the board has a serial console with ddb.onpanic=1. For what it is worth, a DEBUG+LOCKDEBUG kernel does not boot on this board (OpenSBI reports an unhandled trap during secondary hart bringup), so I have not been able to use those.

(I also have an unrelated eqos transmit throughput problem on this board, roughly 2.45 Mbit/s TX against 388 Mbit/s RX. I will report that separately.)

Thanks,
Alex Jokela
