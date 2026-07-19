# NetBSD microSD Image for MilkV Mars — Design

Date: 2026-07-18
Status: Approved (user approved design in conversation; implementation authorized)

## Goal

A `build-image.sh` script that produces `netbsd-mars-<date>.img`, a self-contained
GPT-partitioned microSD image for the MilkV Mars (StarFive JH7110). With the board's
boot-mode switch set to SD, the card boots NetBSD-current with no dependency on the
SPI flash contents.

## Why these choices

- **Board**: MilkV Mars — JH7110 SoC, effectively a VisionFive 2 clone. JH7110 is
  supported in NetBSD-current (not in any numbered release yet).
- **Self-contained boot**: SPL + U-Boot live on the card in dedicated GPT partitions,
  found by the JH7110 BootROM via partition *type GUIDs*. No SPI flash update needed.
- **Prebuilt ingredients, no cross-build**: assembling from published binaries takes
  minutes and is reproducible; a full `build.sh` cross-build was rejected as overkill.
- **Vendor bootloader, not mainline U-Boot**: mainline U-Boot dropped JH7110 SD-boot
  SPL support in v2025.10+. MilkV's prebuilt vendor bootloader targets exactly this
  boot path.

## Ingredients (downloaded + checksum-verified by the script)

1. NetBSD-current daily `riscv64.img.gz`
   `https://nycdn.netbsd.org/pub/NetBSD-daily/HEAD/latest/riscv-riscv64/binary/gzimg/`
   Provides the EFI system partition (`EFI/BOOT/bootriscv64.efi`) and FFS root.
2. MilkV Mars bootloader, GitHub release `milkv-mars/mars-buildroot-sdk` V1.0.6:
   - `mars_u-boot-spl.bin.normal.out` (SPL, StarFive header)
   - `mars_visionfive2_fw_payload.img` (FIT: OpenSBI + vendor U-Boot)

## Image layout

| # | Type GUID                              | Contents            | Size    |
|---|----------------------------------------|---------------------|---------|
| 1 | `2E54B353-1271-4842-806F-E436D6AF6985` | SPL                 | 2 MB    |
| 2 | `BC13C2FF-59E6-4262-A352-B275FD6F7172` | U-Boot FIT payload  | 4 MB    |
| 3 | EFI System (`EF00`)                    | ESP from NetBSD img + DTB + boot env | ≥ source ESP |
| 4 | FFS (NetBSD root)                      | root fs from NetBSD img | source size |

Boot flow: BootROM reads GPT at sector 1 → loads SPL from partition with the SPL type
GUID → SPL loads FIT from the U-Boot type-GUID partition → vendor U-Boot distro-boots
the ESP → loads a mainline-compatible DTB + `bootriscv64.efi` → `bootefi` → NetBSD.

**2026-07-19 correction (post-debugging):** the vendor SDK U-Boot does NOT run the
standard EFI distro scan — its bootcmd only tries `vf2_uEnv.txt` (vendor Linux) and
`/uEnv.txt` + `/extlinux/extlinux.conf` (sysboot). The image therefore ships a
`/uEnv.txt` on the ESP that redefines `fdt_loaddtb` to chain into
`bootefi` of `bootriscv64.efi` with the Mars DTB — MilkV's own env-patching
mechanism. Verified under QEMU with U-Boot 2021.10 (vendor-era EFI) both via the
hijack path and the standard EFI scan path.

## Build flow (macOS-native)

1. Verify prerequisites (`sgdisk` from gptfdisk, `mtools`), download + verify inputs.
2. Decompress the NetBSD image; read its GPT with `sgdisk` to find ESP and root
   partition offsets/sizes (ground truth, not hardcoded).
3. Create blank output image; write GPT with the four partitions above.
4. `dd` SPL and FIT into partitions 1–2.
5. `dd` the ESP and root partition contents from the NetBSD image into partitions 3–4.
6. With `mtools`, add to the ESP: the JH7110 DTB (mainline-compatible, so the NetBSD
   kernel gets bindings it understands — NOT the vendor U-Boot's embedded DTB) and a
   `uEnv.txt`/boot script directing vendor U-Boot to load that DTB and
   `bootriscv64.efi` explicitly.
7. Self-check: `sgdisk -p` layout verification, `mdir` listing of the ESP.

## Risks / caveats (accepted in design review)

- NetBSD-current is a moving target; the script records the build date it fetched.
- DTB compatibility between vendor U-Boot expectations and the NetBSD kernel is the
  highest-risk seam; may need iteration over serial console.
- First boot is serial-console (3.3 V UART); HDMI not assumed. Ethernet/USB expected
  to work per NetBSD JH7110 support.
- Root FS auto-resize on first boot expected (standard NetBSD image behavior); verify.

## Testing

- Script self-validates output (GPT check, ESP listing).
- Hardware validation requires the user's board + serial console.
- QEMU can smoke-test the NetBSD portion but cannot exercise the JH7110 boot chain.
