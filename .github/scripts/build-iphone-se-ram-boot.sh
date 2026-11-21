#!/usr/bin/env bash
# GitHub Actions build only. Does not access/flash any connected device.
set -euo pipefail
ROOT="$(pwd)"
OUT="$ROOT/iphone-se-ram-boot"
TMP="$RUNNER_TEMP/aiboos-se-ram"
mkdir -p "$TMP" "$OUT" "$OUT/apple-dtbs"
test -s "$ROOT/kernel-dev-kit/Image.gz"
test -d "$ROOT/kernel-dev-kit/apple-dtbs"
(cd "$ROOT/kernel-dev-kit" && sha256sum -c SHA256SUMS.txt)
echo 'Building Hoolock m1n1 (idevice branch)'
git clone --depth 1 --recurse-submodules --shallow-submodules --branch idevice https://github.com/HoolockLinux/m1n1.git "$TMP/m1n1"
git -C "$TMP/m1n1" rev-parse HEAD > "$OUT/m1n1-commit.txt"
rustup target add aarch64-unknown-none-softfloat
make -C "$TMP/m1n1" -j"$(nproc)" ARCH=aarch64-linux-gnu- CHAINLOADING=1
test -s "$TMP/m1n1/build/m1n1.bin"
cp "$TMP/m1n1/build/m1n1.bin" "$OUT/m1n1.bin"

echo 'Fetching checksum-verified Debian ARM64 static BusyBox'
python3 - "$TMP" <<'PY'
import hashlib
import lzma
import pathlib
import sys
from urllib.request import urlopen
root = pathlib.Path(sys.argv[1])
base = "https://deb.debian.org/debian/"
with urlopen(base + "dists/trixie/main/binary-arm64/Packages.xz", timeout=120) as resp:
    packages = lzma.decompress(resp.read()).decode()
item = None
for stanza in packages.split("\n\n"):
    if stanza.startswith("Package: busybox-static\n"):
        item = dict(line.split(": ", 1) for line in stanza.splitlines() if ": " in line)
        break
if not item:
    raise SystemExit("Debian ARM64 busybox-static package missing")
with urlopen(base + item["Filename"], timeout=120) as resp:
    data = resp.read()
if hashlib.sha256(data).hexdigest() != item["SHA256"]:
    raise SystemExit("ARM64 BusyBox checksum mismatch")
(root / "busybox-static-arm64.deb").write_bytes(data)
print("Verified ARM64 static BusyBox", item["Version"])
PY
mkdir -p "$TMP/unpacked" "$TMP/initramfs"/{bin,dev,proc,sys,etc,run,tmp,opt/aiboos/web}
dpkg-deb -x "$TMP/busybox-static-arm64.deb" "$TMP/unpacked"
BB="$(find "$TMP/unpacked" -type f -name busybox -print -quit)"
test -n "$BB"
file "$BB" | grep -Eiq 'ARM aarch64|ARM64|Aarch64'
cp "$BB" "$TMP/initramfs/bin/busybox"
chmod 755 "$TMP/initramfs/bin/busybox"
cp -a "$ROOT/AiboOS/Web/." "$TMP/initramfs/opt/aiboos/web/"
echo 'Building AiboOS native ARM64 Linux display component'
gcc -std=c11 -O2 -Wall -Wextra -Werror "$ROOT/iphone-se/native/aiboos-fb.c" -o "$TMP/aiboos-fb-host"
"$TMP/aiboos-fb-host" --selftest
aarch64-linux-gnu-gcc -std=c11 -O2 -static -Wall -Wextra -Werror   "$ROOT/iphone-se/native/aiboos-fb.c" -o "$TMP/initramfs/bin/aiboos-fb"
file "$TMP/initramfs/bin/aiboos-fb" | grep -Eiq 'ARM aarch64|ARM64|Aarch64'
chmod 755 "$TMP/initramfs/bin/aiboos-fb"
install -m 755 "$ROOT/iphone-se/native/aiboos-usb-serial.sh" "$TMP/initramfs/bin/aiboos-usb-serial"
sh -n "$TMP/initramfs/bin/aiboos-usb-serial"
sh "$TMP/initramfs/bin/aiboos-usb-serial" --selftest
install -m 755 "$ROOT/iphone-se/native/aiboos-install.sh" "$TMP/initramfs/bin/aiboos-install"
sh -n "$TMP/initramfs/bin/aiboos-install"
mkdir -p "$TMP/initramfs/opt/aiboos/install" "$TMP/install-root"
(cd "$ROOT/install-rootfs" && sha256sum -c SHA256SUMS.txt)
xz -dc "$ROOT/install-rootfs/AiboOS-ARM64-rootfs.ext4.xz" > "$TMP/install.ext4"
mkdir -p "$TMP/install-mount"
sudo mount -o loop,ro,noload "$TMP/install.ext4" "$TMP/install-mount"
trap 'sudo umount "$TMP/install-mount" 2>/dev/null || true' EXIT
sudo tar --numeric-owner --exclude='./lost+found' -czf "$TMP/initramfs/opt/aiboos/install/rootfs.tar.gz" -C "$TMP/install-mount" .
sudo umount "$TMP/install-mount"
trap - EXIT
sudo chown "$(id -u):$(id -g)" "$TMP/initramfs/opt/aiboos/install/rootfs.tar.gz"
(cd "$TMP/initramfs/opt/aiboos/install" && sha256sum rootfs.tar.gz > SHA256SUMS.txt)
tar -tzf "$TMP/initramfs/opt/aiboos/install/rootfs.tar.gz" | grep -x './sbin/init'
# Exercise actual deployment to a disposable Linux ext4 loop volume in CI.
testvol=/mnt/aiboos-ci-test
sudo mkdir -p "$testvol"
truncate -s 384M "$TMP/test-volume.ext4"
mkfs.ext4 -q -F "$TMP/test-volume.ext4"
sudo mount -o loop "$TMP/test-volume.ext4" "$testvol"
trap 'sudo umount "$testvol" 2>/dev/null || true' EXIT
printf '%s\n' AIBOOS-DEDICATED-LINUX-VOLUME | sudo tee "$testvol/.aiboos-install-target" >/dev/null
sed "s|^bundle=/opt/aiboos/install$|bundle=$TMP/initramfs/opt/aiboos/install|" "$TMP/initramfs/bin/aiboos-install" > "$TMP/install-ci.sh"
sudo sh "$TMP/install-ci.sh" --install "$testvol"
sudo test -x "$testvol/AiboOS/bin/busybox"
sudo grep -qx ID=aiboos "$testvol/AiboOS/etc/os-release"
if sudo sh "$TMP/install-ci.sh" --install "$testvol"; then echo "Overwrite refusal test failed"; exit 1; fi
sudo umount "$testvol"
trap - EXIT
cat > "$TMP/initramfs/init" <<'INIT'
#!/bin/busybox sh
export PATH=/bin:/sbin
/bin/busybox --install -s /bin
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sysfs /sys 2>/dev/null || true
echo 'AiboOS SE 2016: experimental Linux RAM boot reached userspace'
echo 'Internal storage is not mounted or modified by this initramfs.'
echo 'AiboOS native framebuffer module available; visual output depends on Linux display driver.'
echo 'Web UI files are bundled but no web runtime is installed.'
/bin/aiboos-usb-serial >/run/aiboos-usb.log 2>&1 &
/bin/aiboos-fb --ui >/run/aiboos-ui.log 2>&1 &
/bin/aiboos-install --probe >/run/aiboos-storage.log 2>&1 || true
cat /run/aiboos-storage.log
echo 'Phone-side Linux volume installation command: aiboos-install --install /mnt/aiboos'
echo 'Requires a dedicated, prepared ext4 mount; never formats or writes raw storage.'
echo 'Native A9 internal storage support is unverified; no permanent installation attempted.'
exec /bin/busybox sh </dev/console >/dev/console 2>&1
INIT
chmod 755 "$TMP/initramfs/init"
sudo mknod -m 600 "$TMP/initramfs/dev/console" c 5 1
sudo mknod -m 666 "$TMP/initramfs/dev/null" c 1 3
(cd "$TMP/initramfs" && find . -print0 | sort -z | cpio --null --quiet -o -H newc | gzip -n -9) > "$OUT/initramfs.cpio.gz"
gzip -t "$OUT/initramfs.cpio.gz"
cp "$ROOT/kernel-dev-kit/Image.gz" "$OUT/Image.gz"
cp -a "$ROOT/kernel-dev-kit/apple-dtbs/." "$OUT/apple-dtbs/"
printf 'Hoolock ARM64 Linux commit: ' > "$OUT/upstream-versions.txt"
cat "$ROOT/kernel-dev-kit/kernel-commit.txt" >> "$OUT/upstream-versions.txt"
printf 'Hoolock m1n1 idevice commit: ' >> "$OUT/upstream-versions.txt"
cat "$OUT/m1n1-commit.txt" >> "$OUT/upstream-versions.txt"

echo 'Assembling the experimental upstream-documented m1n1 payload'
cat "$OUT/m1n1.bin" > "$OUT/m1n1-linux.bin"
printf '%s\n' 'chosen.bootargs=console=tty0 loglevel=7 rdinit=/init' >> "$OUT/m1n1-linux.bin"
while IFS= read -r -d '' DTB; do cat "$DTB" >> "$OUT/m1n1-linux.bin"; done < <(find "$OUT/apple-dtbs" -type f -name '*.dtb' -print0 | sort -z)
cat "$OUT/Image.gz" "$OUT/initramfs.cpio.gz" >> "$OUT/m1n1-linux.bin"
test -s "$OUT/m1n1-linux.bin"

cat > "$OUT/READ_ME_FIRST.txt" <<'INFO'
AiboOS iPhone SE (2016) ARM64 RAM-ONLY boot experiment
=======================================================
NOT an iOS replacement, not boot-tested on an iPhone SE, and NOT flashable.
No checkm8/PongoOS USB transport or phone disk write is included.
DO NOT FLASH this bundle onto any device.

m1n1-linux.bin combines Hoolock m1n1 + bootargs + DTBs + Linux + ARM64
static BusyBox initramfs. The /init script mounts only virtual proc/sys/dev
filesystems, then drops into a local console shell. AiboOS web UI files are bundled as source data but a browser/runtime is NOT
installed. The separate native framebuffer program draws a minimal boot
screen and physical-button navigation if framebuffer and evdev are available.
Experimental USB ACM serial status waits for a Linux UDC. No hardware test.

This may not boot on iPhone8,4: exact A9 board DTB, firmware, USB console,
pongoOS USB transport, and on-device support remain unverified.
See upstream instructions:
https://github.com/HoolockLinux/docs/blob/master/tutorials/SETUP_pongoOS.md

A9 internal flash installation and recovery are not established.
INFO
(cd "$OUT" && sha256sum m1n1.bin m1n1-linux.bin Image.gz initramfs.cpio.gz > SHA256SUMS.txt)
(cd "$OUT" && sha256sum -c SHA256SUMS.txt)
echo 'RAM-only native userspace experiment created in GitHub Actions. No iPhone was accessed.'
