#!/bin/bash
# build-image.sh — Build a self-contained NetBSD-current microSD image for the
# MilkV Mars (StarFive JH7110).
#
# Boot chain: JH7110 BootROM (SD mode) -> mainline U-Boot SPL (GPT part type
# 2E54B353...) -> OpenSBI+U-Boot FIT (GPT part type BC13C2FF...) -> EFI
# bootmeth -> Mars DTB (via compiled-in fdtfile) + bootriscv64.efi -> NetBSD.
#
# Mainline U-Boot 2025.01 (Debian build for the VisionFive 2) is used because:
#  - the MilkV vendor firmware never runs any EFI/generic boot path, and on
#    some boards ignores even its own uEnv.txt hooks (see blog post);
#  - mainline >= v2025.10 removed JH7110 SD-boot SPL support, so 2025.01 is
#    the sweet spot: mature JH7110 support, SD boot still present.
# The Mars EEPROM is blank so stock U-Boot never composes ${fdtfile}; our
# firmware/ build compiles the Mars fdtfile default in (see build-uboot.sh).
#
# Requires: sgdisk (brew install gptfdisk), mtools (brew install mtools),
#           mkimage (brew install u-boot-tools)

set -eu

cd "$(dirname "$0")"

DOWNLOADS=downloads
OUT="netbsd-mars-$(date +%Y%m%d).img"

NETBSD_BASE_URL="https://nycdn.netbsd.org/pub/NetBSD-daily/HEAD/latest/riscv-riscv64/binary/gzimg"

# Debian's u-boot-starfive 2025.01-3.2, pinned via snapshot.debian.org.
UBOOT_DEB_URL="https://snapshot.debian.org/file/142859e0837736e3246ff7014f686e7e7b33ba75"
UBOOT_DEB="u-boot-starfive_2025.01-3.2_riscv64.deb"
SPL_SHA256="aad97eda22135c115725b72b189ed265f2c2b7166fe03f46c42979bfc32378fc"
ITB_SHA256="822ebcd4783f3866f1ff3aba32a9e498f3df9aa84412649da72fbe77662a3298"

# JH7110 BootROM / SPL find these partitions by type GUID.
SPL_TYPE_GUID="2E54B353-1271-4842-806F-E436D6AF6985"
UBOOT_TYPE_GUID="BC13C2FF-59E6-4262-A352-B275FD6F7172"

SECTOR=512

die() { echo "ERROR: $*" >&2; exit 1; }

command -v sgdisk  >/dev/null || die "sgdisk not found (brew install gptfdisk)"
command -v mcopy   >/dev/null || die "mtools not found (brew install mtools)"
command -v mformat >/dev/null || die "mformat not found (brew install mtools)"
command -v mkimage >/dev/null || die "mkimage not found (brew install u-boot-tools)"

mkdir -p "$DOWNLOADS"

# --- NetBSD daily image (cached; verified against its SHA512 file) ---
if [ ! -f "$DOWNLOADS/riscv64.img.gz" ]; then
    echo "Downloading NetBSD-current riscv64 image..."
    curl -sSL -o "$DOWNLOADS/SHA512" "$NETBSD_BASE_URL/SHA512"
    curl -sSL -o "$DOWNLOADS/riscv64.img.gz" "$NETBSD_BASE_URL/riscv64.img.gz"
fi
[ -f "$DOWNLOADS/SHA512" ] || die "missing $DOWNLOADS/SHA512"
want=$(awk '/riscv64.img.gz/ {print $NF}' "$DOWNLOADS/SHA512")
got=$(shasum -a 512 "$DOWNLOADS/riscv64.img.gz" | awk '{print $1}')
[ "$want" = "$got" ] || die "SHA512 mismatch on riscv64.img.gz (delete $DOWNLOADS to re-fetch)"
echo "NetBSD image checksum OK"

if [ ! -f "$DOWNLOADS/riscv64.img" ]; then
    echo "Decompressing NetBSD image..."
    gunzip -k "$DOWNLOADS/riscv64.img.gz"
fi
SRC="$DOWNLOADS/riscv64.img"

# --- U-Boot: prefer our patched build (firmware/), else Debian snapshot ---
# firmware/ contains U-Boot 2025.01 built with
# CONFIG_DEFAULT_FDT_FILE="starfive/jh7110-milkv-mars.dtb" (see build-uboot.sh)
# so every Mars boots with the right DTB regardless of EEPROM/env state.
# The Debian binary lacks that default and needs a one-time `env save` fixup.
if [ -f "firmware/u-boot.itb" ] && [ -f "firmware/u-boot-spl.bin.normal.out" ]; then
    SPL_FILE="firmware/u-boot-spl.bin.normal.out"
    ITB_FILE="firmware/u-boot.itb"
    UBOOT_PROVENANCE="local build (firmware/, see build-uboot.sh): U-Boot 2025.01 + Mars fdtfile default"
    echo "Using patched Mars U-Boot from firmware/"
else
    UBOOT_DIR="$DOWNLOADS/u-boot-starfive"
    if [ ! -f "$UBOOT_DIR/u-boot.itb" ]; then
        echo "Downloading mainline U-Boot 2025.01 (Debian u-boot-starfive)..."
        curl -sSL -o "$DOWNLOADS/$UBOOT_DEB" "$UBOOT_DEB_URL"
        rm -rf "$UBOOT_DIR" && mkdir -p "$UBOOT_DIR"
        (cd "$UBOOT_DIR" && ar x "../$UBOOT_DEB" data.tar.xz && \
            tar xf data.tar.xz --strip-components=4 ./usr/lib/u-boot/starfive_visionfive2 && \
            mv starfive_visionfive2/* . 2>/dev/null; rmdir starfive_visionfive2 2>/dev/null; \
            rm -f data.tar.xz)
    fi
    SPL_FILE="$UBOOT_DIR/u-boot-spl.bin.normal.out"
    ITB_FILE="$UBOOT_DIR/u-boot.itb"
    [ "$(shasum -a 256 "$SPL_FILE" | awk '{print $1}')" = "$SPL_SHA256" ] || die "SPL sha256 mismatch"
    [ "$(shasum -a 256 "$ITB_FILE" | awk '{print $1}')" = "$ITB_SHA256" ] || die "u-boot.itb sha256 mismatch"
    UBOOT_PROVENANCE="Debian u-boot-starfive 2025.01-3.2 ($UBOOT_DEB_URL) — needs one-time env save for Mars DTB"
    echo "U-Boot artifacts checksum OK"
fi

# --- Read source GPT (ground truth, not hardcoded) ---
part_start() { sgdisk -i "$2" "$1" | awk '/^First sector:/ {print $3}'; }
part_size()  { sgdisk -i "$2" "$1" | awk '/^Partition size:/ {print $3}'; }

SRC_ESP_START=$(part_start "$SRC" 1)
SRC_ESP_SIZE=$(part_size "$SRC" 1)
SRC_ROOT_START=$(part_start "$SRC" 2)
SRC_ROOT_SIZE=$(part_size "$SRC" 2)
[ -n "$SRC_ESP_START" ] && [ -n "$SRC_ROOT_START" ] || die "could not parse source GPT"
echo "Source ESP:  start=$SRC_ESP_START size=$SRC_ESP_SIZE sectors"
echo "Source root: start=$SRC_ROOT_START size=$SRC_ROOT_SIZE sectors"

# --- Output layout (sectors; 1 MiB aligned) ---
P1_START=2048;  P1_SIZE=4096        # SPL, 2 MiB
P2_START=8192;  P2_SIZE=8192        # U-Boot FIT, 4 MiB
P3_START=16384; P3_SIZE=$SRC_ESP_SIZE
P4_START=$(( (P3_START + P3_SIZE + 2047) / 2048 * 2048 ))
P4_SIZE=$SRC_ROOT_SIZE
TOTAL_SECTORS=$(( P4_START + P4_SIZE + 2048 ))

echo "Creating $OUT ($(( TOTAL_SECTORS / 2048 )) MiB)..."
rm -f "$OUT"
dd if=/dev/zero of="$OUT" bs=$SECTOR count=0 seek=$TOTAL_SECTORS 2>/dev/null

sgdisk -Z "$OUT" >/dev/null 2>&1 || true
sgdisk \
    -n 1:$P1_START:$((P1_START + P1_SIZE - 1)) -t 1:$SPL_TYPE_GUID   -c 1:spl \
    -n 2:$P2_START:$((P2_START + P2_SIZE - 1)) -t 2:$UBOOT_TYPE_GUID -c 2:uboot \
    -n 3:$P3_START:$((P3_START + P3_SIZE - 1)) -t 3:EF00 -c 3:EFI \
    -n 4:$P4_START:$((P4_START + P4_SIZE - 1)) -t 4:A902 -c 4:netbsd-root \
    -A 3:set:2 \
    "$OUT" >/dev/null
echo "GPT written"

dd if="$SPL_FILE" of="$OUT" bs=$SECTOR seek=$P1_START conv=notrunc 2>/dev/null
echo "Copied mainline U-Boot SPL"
dd if="$ITB_FILE" of="$OUT" bs=$SECTOR seek=$P2_START conv=notrunc 2>/dev/null
echo "Copied mainline OpenSBI+U-Boot FIT"

# NetBSD root filesystem, lifted from the source image by sector range.
dd if="$SRC" of="$OUT" bs=1048576 skip=$((SRC_ROOT_START / 2048)) \
   seek=$((P4_START / 2048)) count=$((SRC_ROOT_SIZE / 2048)) conv=notrunc 2>/dev/null
echo "Copied NetBSD root filesystem"

# --- Build the ESP as a plain FAT16 (NOT NetBSD makefs's exotic FAT32) ---
# Parameters mirror MilkV's own mkfs.fat layout, proven on the board; hidden
# sectors are set to the true partition offset.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

ESP_IMG="$WORK/esp.img"
mformat -C -i "$ESP_IMG" -T $P3_SIZE -h 128 -s 63 -H $P3_START -R 4 -c 4 -m 0xf8 -r 32 -v NETBSD ::

# Extract the NetBSD ESP contents (EFI/ + dtb/) and copy them in.
SRC_ESP_OFFSET=$((SRC_ESP_START * SECTOR))
mkdir -p "$WORK/espfiles"
mcopy -s -i "$SRC@@$SRC_ESP_OFFSET" ::/EFI ::/dtb "$WORK/espfiles/"
(cd "$WORK/espfiles" && mcopy -s -i "$ESP_IMG" EFI dtb ::)
echo "ESP rebuilt as FAT16 with NetBSD boot files"

# Mars DTB aliases: cover every name a VF2-flavored U-Boot might look up.
mcopy -i "$ESP_IMG" ::/dtb/starfive/jh7110-milkv-mars.dtb "$WORK/mars.dtb"
for alias in jh7110-visionfive-v2.dtb jh7110-starfive-visionfive-2-v1.3b.dtb \
             jh7110-starfive-visionfive-2-v1.2a.dtb; do
    mcopy -o -i "$ESP_IMG" "$WORK/mars.dtb" ::/dtb/starfive/$alias
done
echo "Mars DTB aliased over VF2 filenames"

# uEnv.txt: kept for MilkV vendor-firmware compatibility (harmless under
# mainline U-Boot, which ignores it).
cat > "$WORK/uEnv.txt" <<'UENV'
# NetBSD boot hook for MilkV Mars vendor U-Boot (SDK firmware).
kernel_addr_r=0x44000000
fdt_addr_r=0x48000000
netbsd_efi=fatload ${bootdev} ${devnum}:${bootpart} ${fdt_addr_r} /dtb/starfive/jh7110-milkv-mars.dtb; fatload ${bootdev} ${devnum}:${bootpart} ${kernel_addr_r} /efi/boot/bootriscv64.efi; bootefi ${kernel_addr_r} ${fdt_addr_r}
fdt_loaddtb=run netbsd_efi
boot2=run netbsd_efi
UENV
mcopy -o -i "$ESP_IMG" "$WORK/uEnv.txt" ::/uEnv.txt
echo "Installed uEnv.txt vendor-firmware hook"

# First-boot credentials: authorize an SSH key for root (creds_msdos).
SSH_PUBKEY="${SSH_PUBKEY:-$HOME/.ssh/id_ed25519.pub}"
if [ -f "$SSH_PUBKEY" ]; then
    printf 'sshkey root %s\n' "$(cat "$SSH_PUBKEY")" > "$WORK/creds.txt"
    mcopy -o -i "$ESP_IMG" "$WORK/creds.txt" ::/creds.txt
    echo "Authorized $SSH_PUBKEY for root SSH login (creds.txt)"
else
    echo "No SSH public key at $SSH_PUBKEY; skipping creds.txt (set SSH_PUBKEY to override)"
fi

# Drop the finished ESP into the image.
dd if="$ESP_IMG" of="$OUT" bs=1048576 seek=$((P3_START / 2048)) conv=notrunc 2>/dev/null
echo "ESP installed into image"

# --- Self-checks ---
echo
echo "--- Verification ---"
sgdisk -v "$OUT" | grep -q "No problems found" || die "GPT verification failed"
echo "GPT: no problems found"
ESP_OFFSET=$((P3_START * SECTOR))
cmp -s -n "$(stat -f %z "$SPL_FILE")" "$SPL_FILE" \
    <(dd if="$OUT" bs=$SECTOR skip=$P1_START count=$P1_SIZE 2>/dev/null) || die "SPL readback mismatch"
cmp -s -n "$(stat -f %z "$ITB_FILE")" "$ITB_FILE" \
    <(dd if="$OUT" bs=$SECTOR skip=$P2_START count=$P2_SIZE 2>/dev/null) || die "FIT readback mismatch"
echo "Bootloader readback OK"
for f in "::/EFI/BOOT" "::/dtb/starfive" "::"; do mdir -i "$OUT@@$ESP_OFFSET" $f >/dev/null || die "ESP dir $f unreadable"; done
mdir -i "$OUT@@$ESP_OFFSET" ::/EFI/BOOT | grep -qi bootriscv64.efi || die "bootriscv64.efi missing"
mdir -i "$OUT@@$ESP_OFFSET" ::/dtb/starfive | grep -qi jh7110-milkv-mars.dtb || die "Mars DTB missing"
echo "ESP: bootriscv64.efi and Mars DTB present"
sgdisk -p "$OUT"

# --- Provenance ---
{
    echo "Built: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "NetBSD image: $NETBSD_BASE_URL/riscv64.img.gz"
    echo "NetBSD SHA512: $got"
    echo "U-Boot: $UBOOT_PROVENANCE"
    echo "SPL sha256: $(shasum -a 256 "$SPL_FILE" | awk '{print $1}')"
    echo "u-boot.itb sha256: $(shasum -a 256 "$ITB_FILE" | awk '{print $1}')"
} > "${OUT%.img}.buildinfo.txt"

echo
echo "Done: $OUT"
echo
echo "Write to microSD (replace diskN with your card, check with: diskutil list):"
echo "  diskutil unmountDisk /dev/diskN"
echo "  sudo dd if=$OUT of=/dev/rdiskN bs=1m"
echo "  diskutil eject /dev/diskN"
echo
echo "Board notes:"
echo "  - Set the Mars boot DIP switch to SD (GPIO_0 ON, GPIO_1 OFF)."
echo "  - Serial console 115200 8N1 on header pins 6 (GND), 8 (TX), 10 (RX)."
echo "  - Software reset does not work under this firmware (PMIC mismatch):"
echo "    every reboot needs a power cycle."
echo "  - First boot grows the root filesystem, then tries to self-reboot and"
echo "    HANGS (see above). Power-cycle once; afterwards consider setting"
echo "    resize_root_postcmd=\"\" in /etc/rc.conf on the board."