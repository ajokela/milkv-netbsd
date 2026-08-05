#!/bin/bash
# build-uboot.sh — Build the Mars-patched mainline U-Boot on a Debian/Ubuntu
# Linux builder (native or over SSH) and place the artifacts in firmware/.
#
# The patch is a single config line: CONFIG_DEFAULT_FDT_FILE points at
# NetBSD's jh7110-milkv-mars.dtb, so U-Boot's EFI boot path picks the Mars
# device tree with no EEPROM data, no saved environment, and no boot.scr.
# (The Milk-V Mars ships with a blank EEPROM; the stock VisionFive 2 target
# composes fdtfile from EEPROM contents and otherwise leaves it empty, which
# U-Boot's env import treats as "delete the variable".)
#
# U-Boot v2025.01 is the sweet spot: mature JH7110 support, SD-boot SPL
# still present (removed upstream in v2025.10).
#
# Usage:
#   ./build-uboot.sh                      # build on this (Linux) machine
#   BUILDER=user@debian-box ./build-uboot.sh   # build remotely over SSH

set -eu

UBOOT_VER="${UBOOT_VER:-2025.01}"
OPENSBI_VER="${OPENSBI_VER:-1.6}"
CLOCK_RAMP="${CLOCK_RAMP:-0}"

SCRIPT=$(cat <<'EOF'
set -e
sudo apt-get install -y -q gcc-riscv64-linux-gnu make bison flex libssl-dev \
    device-tree-compiler python3-dev python3-setuptools swig bc \
    libgnutls28-dev uuid-dev >/dev/null
mkdir -p ~/mars-uboot && cd ~/mars-uboot
[ -d opensbi-OPENSBI_VER ] || { curl -sSL -o opensbi.tar.gz \
    https://github.com/riscv-software-src/opensbi/archive/refs/tags/vOPENSBI_VER.tar.gz \
    && tar xf opensbi.tar.gz; }
make -C opensbi-OPENSBI_VER PLATFORM=generic FW_TEXT_START=0x40000000 \
    CROSS_COMPILE=riscv64-linux-gnu- -j"$(nproc)" >/dev/null
[ -d u-boot-UBOOT_VER ] || { curl -sSL -o u-boot.tar.gz \
    https://github.com/u-boot/u-boot/archive/refs/tags/vUBOOT_VER.tar.gz \
    && tar xf u-boot.tar.gz; }
cd u-boot-UBOOT_VER
make starfive_visionfive2_defconfig >/dev/null
grep -q 'CONFIG_DEFAULT_FDT_FILE="starfive/jh7110-milkv-mars.dtb"' .config || \
    echo 'CONFIG_DEFAULT_FDT_FILE="starfive/jh7110-milkv-mars.dtb"' >> .config
# Optional PLL0 500MHz -> 750MHz ramp in bootcmd (CLOCK_RAMP=1).
#
# DISABLED BY DEFAULT. The ramp parks the CPU on the 24MHz oscillator, rewrites
# PLL0's fbdiv, then switches back. If PLL0 does not relock, the SoC stops dead
# the instant bootcmd runs: serial goes silent right after the autoboot
# countdown, no kernel, no network -- while the power LED and ethernet link
# lights stay on (the PHY is hardware). That failure was observed on this board
# and cost a lot of debugging time, so the ramp is now opt-in. Prefer raising
# the clock at runtime instead of in the boot path.
if [ "CLOCKRAMPFLAG" = "1" ]; then
grep -q 'CONFIG_BOOTCOMMAND=' .config && sed -i 's|^CONFIG_BOOTCOMMAND=.*|CONFIG_BOOTCOMMAND="mw.l 13020000 0; mw.l 1303001c 7d; mw.l 13020000 01000000; bootflow scan"|' .config || \
    echo 'CONFIG_BOOTCOMMAND="mw.l 13020000 0; mw.l 1303001c 7d; mw.l 13020000 01000000; bootflow scan"' >> .config
else
grep -q 'CONFIG_BOOTCOMMAND=' .config && sed -i 's|^CONFIG_BOOTCOMMAND=.*|CONFIG_BOOTCOMMAND="bootflow scan"|' .config || \
    echo 'CONFIG_BOOTCOMMAND="bootflow scan"' >> .config
fi
make olddefconfig >/dev/null
export OPENSBI=$HOME/mars-uboot/opensbi-OPENSBI_VER/build/platform/generic/firmware/fw_dynamic.bin
make CROSS_COMPILE=riscv64-linux-gnu- -j"$(nproc)" >/dev/null
echo BUILD_OK
EOF
)
SCRIPT=${SCRIPT//UBOOT_VER/$UBOOT_VER}
SCRIPT=${SCRIPT//OPENSBI_VER/$OPENSBI_VER}
SCRIPT=${SCRIPT//CLOCKRAMPFLAG/$CLOCK_RAMP}

mkdir -p firmware
if [ -n "${BUILDER:-}" ]; then
    echo "Building on $BUILDER..."
    ssh "$BUILDER" 'bash -s' <<<"$SCRIPT"
    scp "$BUILDER:~/mars-uboot/u-boot-$UBOOT_VER/spl/u-boot-spl.bin.normal.out" \
        "$BUILDER:~/mars-uboot/u-boot-$UBOOT_VER/u-boot.itb" firmware/
else
    bash -c "$SCRIPT"
    cp ~/mars-uboot/u-boot-$UBOOT_VER/spl/u-boot-spl.bin.normal.out \
       ~/mars-uboot/u-boot-$UBOOT_VER/u-boot.itb firmware/
fi
ls -l firmware/
echo "Done. build-image.sh will now prefer these artifacts."
