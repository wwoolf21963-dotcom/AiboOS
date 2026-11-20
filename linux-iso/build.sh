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
  --initsystem systemd \
  --binary-images iso-hybrid --archive-areas "main non-free-firmware" \
  --bootappend-live "boot=live components username=aiboos" \
  --security false \
  --iso-application "AiboOS Linux Edition" \
  --iso-publisher "AiboOS community prototype" \
  --iso-volume "AIBOOS_LINUX" \
  # Ubuntu 24.04 live-build uses 'false', not Debian's newer 'none'.
  --debian-installer false
# Work around Ubuntu runner live-build defaulting to the obsolete /trixie/updates security suite.
# Explicitly install the correct Debian 13 security archive in the build and final OS.
mkdir -p config/archives
printf '%s\n' 'deb http://security.debian.org/debian-security trixie-security main non-free-firmware' > config/archives/aiboos-security.list.chroot
cp config/archives/aiboos-security.list.chroot config/archives/aiboos-security.list.binary
# Abort immediately if the chosen live-build version will attempt to bundle
# the unsupported Debian installer flavour. Calamares is installed in the live OS.
if grep -Eq '^LB_DEBIAN_INSTALLER="?(none|true)"?
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
 config/binary; then
  echo "Invalid Debian installer selection in generated live-build config" >&2
  exit 1
fi
grep '^LB_DEBIAN_INSTALLER=' config/binary || true
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
