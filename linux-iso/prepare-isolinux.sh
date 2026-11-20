#!/usr/bin/env bash
set -euo pipefail
# Run immediately after lb config, BEFORE expensive bootstrap/downloads.
TEMPLATE="${AIBO_BOOT_TEMPLATE:-/usr/share/live/build/bootloaders/isolinux}"
BOOT_DIR=config/bootloaders/isolinux
ISOLINUX="${AIBO_ISOLINUX_BIN:-/usr/lib/ISOLINUX/isolinux.bin}"
MODULE_ROOT="${AIBO_SYSLINUX_MODULES:-/usr/lib/syslinux/modules/bios}"
[[ -d "$TEMPLATE" ]] || { echo "Missing live-build Isolinux template: $TEMPLATE" >&2; exit 1; }
[[ -s "$ISOLINUX" ]] || { echo "Missing Isolinux boot binary: $ISOLINUX" >&2; exit 1; }
mkdir -p "$BOOT_DIR"
cp -a "$TEMPLATE/." "$BOOT_DIR/"
# The Ubuntu live-build template has symlinks that break when resolved inside
# the newer Debian chroot. Include actual matching host binaries instead.
for filename in isolinux.bin vesamenu.c32 ldlinux.c32 libcom32.c32 libutil.c32 libmenu.c32; do
  source="$MODULE_ROOT/$filename"
  [[ "$filename" == isolinux.bin ]] && source="$ISOLINUX"
  [[ -s "$source" ]] || { echo "Missing required bootloader component: $source" >&2; exit 1; }
  rm -f "$BOOT_DIR/$filename"
  cp "$source" "$BOOT_DIR/$filename"
done
shopt -s nullglob
for file in "$BOOT_DIR"/*; do
  if [[ -L "$file" ]]; then
    target="$(readlink -f "$file" || true)"
    [[ -n "$target" && -s "$target" ]] || { echo "Unresolved bootloader symlink: $file" >&2; exit 1; }
    rm -f "$file"
    cp "$target" "$file"
  fi
done
shopt -u nullglob
# Ubuntu's legacy live-build incorrectly reads a bootlogo cpio archive even in
# Debian mode, although only Ubuntu mode generates it automatically. Its next
# Syslinux step uses: cpio -i < binary/isolinux/bootlogo.
# Supply a valid empty archive to be copied with the custom isolinux theme.
command -v cpio >/dev/null || { echo "Missing cpio for Isolinux bootlogo" >&2; exit 1; }
if [[ ! -s "$BOOT_DIR/bootlogo" ]]; then
  printf '' | cpio --quiet -o -H newc > "$BOOT_DIR/bootlogo"
fi
[[ -s "$BOOT_DIR/bootlogo" && ! -L "$BOOT_DIR/bootlogo" ]] || { echo "Missing valid Isolinux bootlogo" >&2; exit 1; }
cpio --quiet -t < "$BOOT_DIR/bootlogo" >/dev/null || { echo "Invalid bootlogo cpio archive" >&2; exit 1; }
for filename in isolinux.bin vesamenu.c32 ldlinux.c32 libcom32.c32 libutil.c32 libmenu.c32; do
  [[ -s "$BOOT_DIR/$filename" && ! -L "$BOOT_DIR/$filename" ]] || { echo "Bootloader check failed: $filename" >&2; exit 1; }
done
echo "Isolinux preflight passed before package downloads."
