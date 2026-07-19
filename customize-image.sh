#!/bin/bash
# customize-image.sh — Personalize a built Mars NetBSD image for distribution.
#
# Boots the image in QEMU (riscv64 virt + period U-Boot), drops to single-user
# mode via the NetBSD boot loader, and applies shipping configuration over the
# emulated serial console:
#   - root password (default "netbsd" — override with ROOT_PASSWORD=...)
#   - sshd PermitRootLogin yes (SBC-image convention; motd screams about it)
#   - /etc/ifconfig.eqos0 that generates a persistent random MAC on first
#     boot (the Mars EEPROM is blank, so the kernel would otherwise pick a
#     fresh MAC — and a fresh DHCP lease — every single boot)
#   - /etc/motd with credentials and board caveats
#
# Single-user mode means no sshd host keys and no entropy file are created,
# so every recipient's board generates unique keys on its own first boot.
# Verification happens on a throwaway copy; the golden image stays pristine.
#
# Usage: ./customize-image.sh netbsd-mars-YYYYMMDD.img

set -eu
cd "$(dirname "$0")"

IMG="${1:?usage: $0 <image.img>}"
[ -f "$IMG" ] || { echo "ERROR: $IMG not found" >&2; exit 1; }
ROOT_PASSWORD="${ROOT_PASSWORD:-netbsd}"

command -v qemu-system-riscv64 >/dev/null || { echo "ERROR: qemu not found (brew install qemu)" >&2; exit 1; }
command -v expect >/dev/null || { echo "ERROR: expect not found" >&2; exit 1; }

# Period-correct U-Boot for QEMU (2021.10, from Debian snapshot; cached).
QEMU_UBOOT="downloads/qemu-uboot/u-boot.bin"
if [ ! -f "$QEMU_UBOOT" ]; then
    echo "Fetching u-boot-qemu 2021.10..."
    mkdir -p downloads/qemu-uboot
    curl -sSL -o downloads/qemu-uboot/deb "https://snapshot.debian.org/file/$(
        curl -sSL 'https://snapshot.debian.org/mr/package/u-boot/2021.10%2Bdfsg-1/binfiles/u-boot-qemu/2021.10%2Bdfsg-1' \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"][0]["hash"])')"
    (cd downloads/qemu-uboot && ar x deb data.tar.xz && \
     tar xf data.tar.xz --strip-components=5 ./usr/lib/u-boot/qemu-riscv64_smode/u-boot.bin 2>/dev/null || \
     { tar xf data.tar.xz ./usr/lib/u-boot/qemu-riscv64_smode/u-boot.bin && \
       mv usr/lib/u-boot/qemu-riscv64_smode/u-boot.bin . && rm -rf usr; }; rm -f data.tar.xz deb)
fi

echo "Customizing $IMG (root password: $ROOT_PASSWORD)..."

# Auto-enter single user via NetBSD boot.cfg (efiboot keystrokes are
# unreliable under QEMU's EFI console). Removed again after customization.
ESP_OFF=8388608
printf 'menu=Single-user (image customization):boot netbsd -s\ntimeout=0\ndefault=1\n' > /tmp/bootcfg.$$
mcopy -o -i "$IMG@@$ESP_OFF" /tmp/bootcfg.$$ ::/boot.cfg
rm -f /tmp/bootcfg.$$

expect <<EOF
set timeout 180
log_user 1
spawn qemu-system-riscv64 -M virt -m 2G -smp 4 -nographic \
    -kernel "$QEMU_UBOOT" \
    -drive if=none,id=hd0,file=$IMG,format=raw -device virtio-blk-device,drive=hd0
proc await {pat} { expect { -re \$pat {} timeout { puts "TIMEOUT waiting: \$pat"; exit 1 } eof { puts "EOF waiting: \$pat"; exit 1 } } }
await "Enter pathname of shell"
send "\r"
await "# "
send "/sbin/mount -u -w /\r"
await "# "
send "passwd root\r"
await "assword:"
send "$ROOT_PASSWORD\r"
await "assword:"
send "$ROOT_PASSWORD\r"
await "# "
send "echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config\r"
await "# "
send "echo '!test -f /etc/mars_mac || printf f2:%02x:%02x:%02x:%02x:%02x \$(od -An -N5 -tu1 /dev/urandom) > /etc/mars_mac' > /etc/ifconfig.eqos0\r"
await "# "
send "echo '!ifconfig eqos0 link \$(cat /etc/mars_mac) active' >> /etc/ifconfig.eqos0\r"
await "# "
send "echo up >> /etc/ifconfig.eqos0\r"
await "# "
send "cat /etc/ifconfig.eqos0\r"
await "# "
send "echo 'NetBSD-current on the Milk-V Mars  (unofficial community image)' > /etc/motd\r"
await "# "
send "echo '  ** DEFAULT CREDENTIALS: root / $ROOT_PASSWORD  --  CHANGE THIS NOW: run passwd **' >> /etc/motd\r"
await "# "
send "echo '  - Root SSH login with password is ENABLED; consider switching to keys.' >> /etc/motd\r"
await "# "
send "echo '  - reboot/poweroff HANG on this board (firmware cannot reset the PMIC).' >> /etc/motd\r"
await "# "
send "echo '    Power-cycle instead; filesystems are synced first, it is safe.' >> /etc/motd\r"
await "# "
send "echo '  - Serial console: 115200 8N1, header pins 6=GND 8=TX 10=RX.' >> /etc/motd\r"
await "# "
send "echo '  - First boot grows the root filesystem, then INTENTIONALLY hangs at' >> /etc/motd\r"
await "# "
send "echo '    rebooting... -- power-cycle once. Every later boot is normal.' >> /etc/motd\r"
await "# "
send "rm -f /var/db/entropy-file\r"
await "# "
send "sync; sync\r"
await "# "
send "/sbin/halt\r"
await "halted"
exit 0
EOF
echo "Customization applied."
mdel -i "$IMG@@$ESP_OFF" ::/boot.cfg && echo "boot.cfg removed (normal boot restored)"

# --- Verify on a throwaway copy (golden image stays pristine) ---
echo "Verifying on a copy (multiuser boot + console login)..."
cp "$IMG" "$IMG.verify"
expect <<EOF
set timeout 300
log_user 1
spawn qemu-system-riscv64 -M virt -m 2G -smp 4 -nographic \
    -kernel "$QEMU_UBOOT" \
    -drive if=none,id=hd0,file=$IMG.verify,format=raw -device virtio-blk-device,drive=hd0
proc await {pat} { expect { -re \$pat {} timeout { puts "TIMEOUT waiting: \$pat"; exit 1 } eof { puts "EOF waiting: \$pat"; exit 1 } } }
await "login:"
send "root\r"
await "assword:"
send "$ROOT_PASSWORD\r"
await "# "
send "grep -c 'PermitRootLogin yes' /etc/ssh/sshd_config && head -3 /etc/motd\r"
await "CHANGE THIS NOW"
puts "VERIFY_OK: root/$ROOT_PASSWORD login works, sshd + motd in place"
exit 0
EOF
rm -f "$IMG.verify"
echo
echo "Done: $IMG is ready to distribute."
echo "Package with:  xz -9 -T0 -k $IMG && shasum -a 512 $IMG.xz > $IMG.xz.sha512"