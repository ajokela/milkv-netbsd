# NetBSD/riscv64 pmap panic on StarFive JH7110 (MilkV Mars)

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
