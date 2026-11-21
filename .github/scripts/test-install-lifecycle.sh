#!/usr/bin/env bash
# CI only: uses a disposable regular-file virtual disk, no phone or host disks.
set -euo pipefail
ROOT="$PWD"
TMP="$RUNNER_TEMP/aiboos-install-lifecycle"
REPORT="$ROOT/install-lifecycle-report"
mkdir -p "$TMP" "$REPORT"
K="$TMP/linux"
git init "$K"
git -C "$K" remote add origin https://github.com/OrchardLinux/linux.git
git -C "$K" fetch --depth=1 origin ef92d0d3b34aecba1fca233c4b983f89d1dbaaa1
git -C "$K" checkout --detach FETCH_HEAD
make -C "$K" ARCH=arm64 LLVM=1 defconfig
"$K/scripts/config" --file "$K/.config" \
 --enable BLK_DEV_INITRD --enable RD_GZIP --enable DEVTMPFS \
 --enable TMPFS --enable VIRTIO --enable VIRTIO_MMIO --enable VIRTIO_BLK \
 --enable EXT4_FS --enable SERIAL_AMBA_PL011 --enable SERIAL_AMBA_PL011_CONSOLE
make -C "$K" ARCH=arm64 LLVM=1 olddefconfig
for f in BLK_DEV_INITRD RD_GZIP DEVTMPFS TMPFS VIRTIO_MMIO VIRTIO_BLK EXT4_FS SERIAL_AMBA_PL011_CONSOLE; do
 grep -qx "CONFIG_$f=y" "$K/.config"
done
make -C "$K" -j"$(nproc)" ARCH=arm64 LLVM=1 Image
cp "$K/.config" "$REPORT/virtual-kernel.config"
(cd current-rootfs && sha256sum -c SHA256SUMS.txt)
xz -dc current-rootfs/AiboOS-ARM64-rootfs.ext4.xz > "$TMP/source.ext4"
mkdir -p "$TMP/source" "$TMP/ram"/{bin,dev,proc,sys,run,mnt/aiboos,opt/aiboos/install}
sudo mount -o loop,ro,noload "$TMP/source.ext4" "$TMP/source"
trap 'sudo umount "$TMP/source" 2>/dev/null || true' EXIT
sudo cp "$TMP/source/bin/busybox" "$TMP/ram/bin/busybox"
# Add a CI-only test hook to the archive; never ship this as a phone image.
sudo mkdir -p "$TMP/staged"
sudo cp -a "$TMP/source/." "$TMP/staged/"
sudo umount "$TMP/source"
trap - EXIT
sudo rm -rf "$TMP/staged/lost+found"
cat > "$TMP/verify-ci" <<'EOF'
#!/bin/sh
set -eu
PATH=/bin:/sbin
grep -qx ID=aiboos /etc/os-release
[ -f /.aiboos-installed ]
[ "$(cat /var/lib/aiboos/ci-persistence)" = "installed-before-poweroff" ]
/bin/aiboos-fb --selftest
echo "AIBOOS_CI_INSTALLED_ROOT_STARTED"
sync
/bin/busybox poweroff -f
EOF
sudo install -m 755 "$TMP/verify-ci" "$TMP/staged/etc/verify-ci"
printf '\n::once:/etc/verify-ci\n' | sudo tee -a "$TMP/staged/etc/inittab" >/dev/null
sudo tar --numeric-owner -czf "$TMP/ram/opt/aiboos/install/rootfs.tar.gz" -C "$TMP/staged" .
sudo chown "$(id -u):$(id -g)" "$TMP/ram/opt/aiboos/install/rootfs.tar.gz"
(cd "$TMP/ram/opt/aiboos/install" && sha256sum rootfs.tar.gz > SHA256SUMS.txt)
install -m 755 iphone-se/native/aiboos-install.sh "$TMP/ram/bin/aiboos-install"
install -m 755 iphone-se/native/aiboos-root-start.sh "$TMP/ram/bin/aiboos-root-start"
cat > "$TMP/ram/init" <<'EOF'
#!/bin/busybox sh
set -eu
export PATH=/bin:/sbin
/bin/busybox --install -s /bin
mount -t devtmpfs devtmpfs /dev
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t tmpfs tmpfs /run
# The VM has exactly one test disk, supplied as a regular file by CI.
i=0
while [ ! -b /dev/vda ]; do
 i=$((i+1)); [ "$i" -lt 30 ] || exit 1
 sleep 1
done
mount -t ext4 /dev/vda /mnt/aiboos
case " $(cat /proc/cmdline) " in
 *" aiboos_ci=install "*)
  echo AIBOOS-DEDICATED-LINUX-VOLUME > /mnt/aiboos/.aiboos-install-target
  /bin/aiboos-install --install /mnt/aiboos
  /bin/aiboos-root-start --verify /mnt/aiboos/AiboOS
  echo installed-before-poweroff > /mnt/aiboos/AiboOS/var/lib/aiboos/ci-persistence
  sync
  umount /mnt/aiboos
  echo AIBOOS_CI_INSTALL_COMPLETE
  poweroff -f
  ;;
 *" aiboos_ci=restart "*)
  exec /bin/busybox sh /bin/aiboos-root-start --boot-mounted /mnt/aiboos
  ;;
 *) exit 1;;
esac
EOF
chmod 755 "$TMP/ram/init"
sudo mknod -m 600 "$TMP/ram/dev/console" c 5 1
sudo mknod -m 666 "$TMP/ram/dev/null" c 1 3
(cd "$TMP/ram" && sudo find . -print0 | sudo cpio --null -o -H newc --quiet | gzip -n) > "$TMP/ram.cpio.gz"
truncate -s 512M "$TMP/test-disk.ext4"
mkfs.ext4 -q -F "$TMP/test-disk.ext4"
test -f "$TMP/test-disk.ext4" && test ! -L "$TMP/test-disk.ext4"
run_vm() {
 timeout 240 qemu-system-aarch64 -machine virt -cpu cortex-a57 -smp 2 -m 1024 \
  -nodefaults -nographic -serial stdio -monitor none -no-reboot \
  -kernel "$K/arch/arm64/boot/Image" -initrd "$TMP/ram.cpio.gz" \
  -append "console=ttyAMA0 rdinit=/init aiboos_ci=$1" \
  -drive "file=$TMP/test-disk.ext4,if=none,format=raw,id=testdisk" \
  -device virtio-blk-device,drive=testdisk 2>&1 | tee "$REPORT/$1.log"
}
run_vm install
grep -q AIBOOS_CI_INSTALL_COMPLETE "$REPORT/install.log"
run_vm restart
grep -q AIBOOS_CI_INSTALLED_ROOT_STARTED "$REPORT/restart.log"
e2fsck -fn "$TMP/test-disk.ext4" | tee "$REPORT/filesystem-check.log"
echo "PASS: guest installation, shutdown, restart, installed init and persistence on a virtual ARM64 disk." | tee "$REPORT/result.txt"
