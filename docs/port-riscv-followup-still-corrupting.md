Subject: Re: riscv64/JH7110: repeatable kernel memory corruption

To: port-riscv@NetBSD.org

Hello,

Thanks for the pmap fix. I retested on the Milk-V Mars and I am afraid the
corruption is still there, although the pmap_segtab assertion is gone.

What I tested:

- NetBSD 11.99.7 (GENERIC64) #0: Wed Aug 5 09:51:05 UTC 2026, the -current
  daily riscv64 gzimg, unmodified. That is a week after pmap.c 1.107, so the
  pmap_{page_protect,clear_attribute} change is in it. (pmap_shootdown is
  static and gets inlined, so it does not appear in the kernel symbol table;
  I checked the revision date and the source rather than the symbols.)
- Same board and same reproducer as before: 6 GB tmpfs, pkgsrc-2026Q2
  tarball, four workers looping "rm -rf pkgsrc; tar xzf".
- Firmware differs slightly from my last report: mainline U-Boot 2025.01
  built without the PLL clock ramp I had been using, so the CPU runs at its
  500 MHz boot clock rather than 750 MHz.

Result: panic in about 20 seconds. The previous kernel panicked in 32
seconds under the same reproducer, so the difference is not meaningful
(one sample each, and the clock differs).

I have not seen the pmap_segtab.c:948 assertion again, so 1.107 does appear
to have fixed that one. What remains is the UBC queue corruption:

    panic: TAILQ_* forw 0xffffffc005804960 /usr/src/sys/uvm/uvm_bio.c:554
    vpanic() at netbsd:vpanic+0x140
    panic() at netbsd:panic+0x24
    ubc_alloc.constprop.0() at netbsd:ubc_alloc.constprop.0+0x4f0
    ubc_uiomove() at netbsd:ubc_uiomove+0x7a
    tmpfs_write() at netbsd:tmpfs_write+0xa4
    VOP_WRITE() at netbsd:VOP_WRITE+0x5a
    vn_write() at netbsd:vn_write+0xa0
    dofilewrite() at netbsd:dofilewrite+0x5e
    syscall() at netbsd:syscall+0xe8

New evidence from this ddb session, which I think is the cleanest picture of
the failure so far: the damage is exactly one page wide and page aligned.

ubc_object gave the umap array at 0xffffffc0057b9000 (0x1000 entries of 0x60
bytes) and the hash bucket array at 0xffffffc005819000, hashmask 0xfff.

The element named in the panic, 0xffffffc005804960, is umap[3225] and is
itself intact: valid uobj, sane hash.le_prev into the bucket array, and
inactive.tqe_prev pointing at the queue head. The QUEUEDEBUG "forw" check
fails because it dereferences the successor:

    elm->inactive.tqe_next             = 0xffffffc0057f02c0
    &elm->inactive.tqe_next            = 0xffffffc0058049a0
    required: *(tqe_next + offsetof(inactive.tqe_prev)) == 0xffffffc0058049a0

That successor, 0xffffffc0057f02c0, is umap[2354], and it is entirely zero,
all 0x60 bytes. Looking at the page it lives on:

    db{1}> x/x 0xffffffc0057effe0,8      <- end of the preceding page
    ffffffc0057effe0:  0  2  0  0  57c1f40
    ffffffc0057efff4:  ffffffc0  581ee08  ffffffc0

    db{1}> x/x 0xffffffc0057f0000,10     <- start of the damaged page
    ffffffc0057f0000:  0  0  0  0  0
    ... all zero ...

    db{1}> x/x 0xffffffc0057f0ff0,4      <- end of the damaged page
    ffffffc0057f0ff0:  0  0  0  0

    db{1}> x/x 0xffffffc0057f1000,8      <- start of the following page
    ffffffc0057f1000:  2b33c000  ffffffe1  376d7000  ffffffe1  52
    ffffffc0057f1014:  0  57c6170  ffffffc0

So exactly one 4 KiB page of the kmem-allocated umap array has been zeroed,
with intact umap entries immediately before and after, and the damage stops
precisely on both page boundaries.

This is the same shape as the instance in my earlier mail, where a page of
the UBC hash bucket array simultaneously contained page 0 of a tmpfs file.
The difference is only what the other owner wrote: file bytes then, zeroes
now. A page of zeroes is what you would expect if the page was handed out
again and zero filled for its new owner, e.g. a fresh anonymous or tmpfs
page. Either way the umap array's backing page is being used by something
else while kmem still owns it.

For completeness, unchanged from the previous report: reproduces with
hw.ncpuonline=1, reproduces with the network interface down, reproduces via
both tmpfs_write and ffs_write, and does not reproduce under qemu -M virt.

The board is sitting in ddb now and I can keep it there. I am happy to run
more commands in this session, test patches, or build instrumented kernels;
the reproducer takes well under a minute so turnaround is quick.

Thanks,
Alex Jokela
