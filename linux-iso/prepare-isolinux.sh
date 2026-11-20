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
for filename in isolinux.bin vesamenu.c32 ldlinux.c32 libcom32.c32 libutil.c32 libmenu.c32; do
  [[ -s "$BOOT_DIR/$filename" && ! -L "$BOOT_DIR/$filename" ]] || { echo "Bootloader check failed: $filename" >&2; exit 1; }
done
echo "Isolinux preflight passed before package downloads."
