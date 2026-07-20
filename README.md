# NetBSD microSD image for the MilkV Mars

Builds a self-contained, bootable NetBSD-current microSD image for the
[MilkV Mars](https://milkv.io/mars) (StarFive JH7110, RISC-V). The card carries
its own bootloader — nothing on the board's SPI flash is used or modified.

Status: **boots and runs with working gigabit Ethernet.** Known issues below.

**Prebuilt image:** [netbsd-mars-20260719.img.xz](https://cdn.tinycomputers.io/milkv-mars/netbsd-mars-20260719.img.xz)
(234 MB, [SHA512](https://cdn.tinycomputers.io/milkv-mars/netbsd-mars-20260719.img.xz.sha512)) —
default login `root`/`netbsd` (change it!), CPU ramped to 750 MHz by the
bundled firmware, unique SSH host keys generated on first boot.

## Build

```sh
brew install gptfdisk mtools u-boot-tools   # one-time
./build-image.sh
```

Produces `netbsd-mars-<date>.img` (~1.9 GB) plus a `.buildinfo.txt` recording
exactly which NetBSD daily build and U-Boot artifacts went in. Downloads are
cached in `downloads/`; delete that directory to fetch a fresh NetBSD daily.

## Write to microSD

```sh
diskutil list                        # identify your card, e.g. /dev/disk4
diskutil unmountDisk /dev/diskN
sudo dd if=netbsd-mars-<date>.img of=/dev/rdiskN bs=1m
diskutil eject /dev/diskN
```

## Boot the board

1. **Set the boot DIP switch to SD-Card.** The 2-position DIP switch sits
   next to the USB3 stack (Mars v1.2+; factory default is SPI flash). Watch
   the numbering — it's reversed from the GPIO names: physical switch **2**
   drives GPIO0 and physical switch **1** drives GPIO1 (ON = High):

   | Boot mode | switch 1 (GPIO1) | switch 2 (GPIO0) |
   |---|---|---|
   | SPI flash (factory default) | OFF | OFF |
   | **SD card (use this)** | **OFF** | **ON** |
   | eMMC | ON | OFF |
   | UART recovery | ON | ON |

   SD mode is required — the card carries mainline U-Boot; the vendor
   firmware in SPI flash cannot boot this card (see "Why mainline U-Boot").
2. **Serial console strongly recommended**: 3.3 V USB-UART on the 40-pin
   header — pin 6 GND, pin 8 board TX, pin 10 board RX, 115200 8N1. There is
   no HDMI under NetBSD (no JH7110 display driver).
3. Power on. U-Boot (our build, with the Mars `fdtfile` compiled in)
   EFI-boots `bootriscv64.efi` with NetBSD's own `jh7110-milkv-mars.dtb`.

First boot: the root filesystem grows to fill the card, then the image
intentionally reboots without syncing (`reboot -n`) — **which hangs on this
board** (PMIC, see Known issues). This is expected and safe: power-cycle
once and every later boot is normal. Do NOT "fix" the postcmd — the no-sync
reboot protects the fresh resize from stale-superblock writeback.

Log in as `root` (no password) on serial, or via SSH if you baked in a key
(below). `dhcpcd` configures Ethernet.

Recommended first-login tweak — pin a MAC (any locally-administered one):

```sh
echo "link f2:00:bc:8e:6b:ba active" > /etc/ifconfig.eqos0
```

The Mars EEPROM is blank, so NetBSD otherwise generates a random MAC each
boot — a new DHCP lease every time. (Images made with `customize-image.sh`
already include a persistent-MAC generator.)

### SSH access

If `~/.ssh/id_ed25519.pub` exists at build time (override with
`SSH_PUBKEY=/path/to/key.pub ./build-image.sh`), the build drops a `creds.txt`
onto the boot partition. NetBSD's `creds_msdos` service authorizes that key
for root on first boot, so `ssh root@<board>` works immediately (key-based
only; sshd's default forbids root passwords).

## How it boots

| # | Contents | Type GUID | Notes |
|---|----------|-----------|-------|
| 1 | mainline U-Boot SPL (2025.01) | `2E54B353-…6985` | loaded by BootROM |
| 2 | OpenSBI + U-Boot FIT (2025.01) | `BC13C2FF-…7172` | loaded by SPL |
| 3 | boot partition (FAT16) | ESP | `EFI/BOOT/bootriscv64.efi`, `/dtb` |
| 4 | NetBSD root | NetBSD FFS | kernel at `/netbsd` |

**Why mainline U-Boot (Debian's `u-boot-starfive` 2025.01):** the MilkV vendor
firmware never runs any EFI or generic distro-boot path — its only supported
flows are its own Linux and uEnv/extlinux, and on our test board it ignored
even its own `uEnv.txt` mechanism. Mainline v2025.01 is the sweet spot:
mature JH7110 support, SD-boot SPL still present (removed in v2025.10).

**Why a custom U-Boot build (`firmware/`, reproduced by `build-uboot.sh`):**
the Mars EEPROM is blank, so U-Boot's VisionFive 2 board code never composes
`${fdtfile}`; the stock defconfig also leaves `CONFIG_DEFAULT_FDT_FILE`
empty, and U-Boot deletes env variables with empty defaults. Result: U-Boot
silently falls back to its built-in VF2 device tree — under which NetBSD
misconfigures the Motorcomm PHY (`unknown drive strength`), drops ~80% of
packets, and probes a phantom second GMAC. Our build adds exactly one line:
`CONFIG_DEFAULT_FDT_FILE="starfive/jh7110-milkv-mars.dtb"`. The ESP is
rebuilt as plain FAT16 (NetBSD `makefs`'s FAT32 layout is exotic enough to
distrust with vendor-era FAT drivers), and the Mars DTB is aliased over the
VF2 filenames as belt-and-suspenders.

**Distribution images:** `./customize-image.sh <image>` boots the image in
QEMU and bakes in `root`/`netbsd` credentials, `PermitRootLogin yes`, a
warning motd, and a persistent-MAC generator — see the script header.

## Known issues

- **Software reset does not work** — OpenSBI/U-Boot's VF2 build cannot drive
  the Mars PMIC (`pmic_ops: cannot read pmic power register`); `reboot`
  hangs after "rebooting...". Every reboot is a power cycle. A Mars-specific
  U-Boot build (`milkv_mars_defconfig`) would likely fix this.
- **Kernel panic under early paging load** (seen on NetBSD-current 11.99.7,
  2026-07-18 daily): assertion
  `pm == l->l_proc->p_vmspace->vm_map.pmap` in `uvm/pmap/pmap_segtab.c:948`
  via `uvm_pageout` → `pmap_clear_attribute`. Full backtrace in
  `docs/netbsd-pmap-panic.md`. Appears load/timing dependent; worth
  reporting to port-riscv@ and retrying newer -current dailies.
- **If the root doesn't auto-grow** (`gpt` errors at first boot): from the
  boot-failure recovery shell (root mounted read-only), run
  `gpt resizedisk ld1`, `gpt resize -i 4 ld1`, `resize_ffs -y /dev/rdk3`,
  `fsck_ffs -f -y /dev/rdk3`, then exit with `reboot -n` (never a syncing
  shutdown — the kernel's stale in-core superblock would clobber the resize)
  and power-cycle.
- JH7110 support exists only in **NetBSD-current**; every build of this image
  tracks a moving target. `.buildinfo.txt` pins what you got.

## History

The full debugging story (vendor firmware archaeology, QEMU time machine,
SD-card flight recorder, serial-console endgame) is written up in
[Four Partitions and a Borrowed Bootloader](https://tinycomputers.io/posts/four-partitions-and-a-borrowed-bootloader-netbsd-on-the-milk-v-mars.html). Design notes:
`docs/superpowers/specs/2026-07-18-mars-netbsd-image-design.md`.
