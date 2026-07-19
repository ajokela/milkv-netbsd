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

UBOOT_VER=2025.01
OPENSBI_VER=1.6

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
make olddefconfig >/dev/null
export OPENSBI=$HOME/mars-uboot/opensbi-OPENSBI_VER/build/platform/generic/firmware/fw_dynamic.bin
make CROSS_COMPILE=riscv64-linux-gnu- -j"$(nproc)" >/dev/null
echo BUILD_OK
EOF
)
SCRIPT=${SCRIPT//UBOOT_VER/$UBOOT_VER}
SCRIPT=${SCRIPT//OPENSBI_VER/$OPENSBI_VER}

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
