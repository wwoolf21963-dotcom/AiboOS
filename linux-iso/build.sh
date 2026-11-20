#!/usr/bin/env bash
# AiboOS Linux Edition — x86_64 Debian live ISO with Calamares.
# This script BUILDS a bootable ISO. It NEVER writes to or formats the host disk.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/linux-iso"
WORK="$DIST/work"
if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root in a disposable Linux build environment: sudo bash linux-iso/build.sh" >&2
  exit 1
fi
for program in lb rsync; do
  command -v "$program" >/dev/null || { echo "Missing $program" >&2; exit 1; }
done
mkdir -p "$WORK"
cd "$WORK"
# Only clean generated live-build paths, never delete arbitrary directories.
lb clean --purge 2>/dev/null || true
rm -rf config
lb config --mode debian --distribution trixie --architectures amd64 \
  --binary-images iso-hybrid --archive-areas "main non-free-firmware" \
  --bootappend-live "boot=live components username=aiboos" \
  --iso-application "AiboOS Linux Edition" \
  --iso-publisher "AiboOS community prototype" \
  --iso-volume "AIBOOS_LINUX" \
  --debian-installer none
mkdir -p config/package-lists
cp "$DIST/packages.list.chroot" config/package-lists/aiboos.list.chroot
mkdir -p config/includes.chroot/opt/aiboos/web
rsync -a --exclude='.DS_Store' "$ROOT/AiboOS/Web/" config/includes.chroot/opt/aiboos/web/
mkdir -p config/includes.chroot/usr/local/bin
cp "$DIST/aiboos-start" config/includes.chroot/usr/local/bin/aiboos-start
chmod +x config/includes.chroot/usr/local/bin/aiboos-start
mkdir -p config/includes.chroot/etc/xdg/autostart
cp "$DIST/aiboos-autostart.desktop" config/includes.chroot/etc/xdg/autostart/aiboos.desktop
mkdir -p config/includes.chroot/usr/share/applications
cp "$DIST/aiboos.desktop" config/includes.chroot/usr/share/applications/aiboos.desktop
mkdir -p config/includes.chroot/usr/share/icons/hicolor/scalable/apps
cp "$ROOT/AiboOS/Web/aibo-icon.svg" config/includes.chroot/usr/share/icons/hicolor/scalable/apps/aiboos.svg
echo "Building AiboOS Linux Edition — this does NOT change the current computer's OS."
lb build
ISO="$(find "$WORK" -maxdepth 1 -name 'live-image-*.iso' -print -quit)"
if [[ -z "$ISO" ]]; then echo "No ISO was produced" >&2; exit 1; fi
cp "$ISO" "$DIST/AiboOS_Linux_amd64.iso"
sha256sum "$DIST/AiboOS_Linux_amd64.iso" > "$DIST/AiboOS_Linux_amd64.iso.sha256"
echo "READY: $DIST/AiboOS_Linux_amd64.iso"
