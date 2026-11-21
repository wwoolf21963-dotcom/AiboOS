#!/bin/sh
# Runs inside Linux, never opens a raw device or modifies firmware.
set -eu
PATH=/bin:/sbin:/usr/bin:/usr/sbin
export PATH
bundle=/opt/aiboos/install
fail() { echo "AiboOS installer: $*" >&2; exit 1; }
probe() {
    echo "Linux storage inventory (read only):"
    found=0
    for b in /sys/class/block/*; do
        [ -r "$b/size" ] || continue
        n=$(basename "$b")
        case "$n" in loop*|ram*|zram*) continue;; esac
        found=1
        printf '%s sectors=%s read_only=%s\n' "$n" "$(cat "$b/size")" "$(cat "$b/ro" 2>/dev/null || echo unknown)"
    done
    [ "$found" = 1 ] || echo "No physical block devices exposed by the Linux kernel."
    echo "Mounted Linux filesystems:"
    awk '$3=="ext4" { print $1, $2, $4 }' /proc/mounts
}
case "${1:-}" in
    --probe) probe; exit 0;;
    --install) ;;
    *) echo "Usage: aiboos-install --probe | --install /mnt/aiboos"; exit 2;;
esac
[ "$#" = 2 ] || fail "Specify one prepared volume."
[ "$(id -u)" = 0 ] || fail "Linux root permissions required."
target=$2
case "$target" in /mnt/*) ;; *) fail "Only explicit /mnt/ targets are supported.";; esac
[ -d "$target" ] || fail "Target not found."
[ "$(readlink -f "$target")" = "$target" ] || fail "Use the exact canonical mount path."
case "$target" in *[!a-zA-Z0-9_./-]*) fail "Unsupported path characters.";; esac
awk -v t="$target" '$2==t && $3=="ext4" && $4 ~ /(^|,)rw(,|$)/ { n++ } END{exit n!=1}' /proc/mounts || fail "Target must itself be a writable ext4 mount."
[ -f "$target/.aiboos-install-target" ] && [ ! -L "$target/.aiboos-install-target" ] || fail "Prepared target marker missing."
[ "$(cat "$target/.aiboos-install-target")" = "AIBOOS-DEDICATED-LINUX-VOLUME" ] || fail "Incorrect target marker."
for p in "$target"/* "$target"/.[!.]* "$target"/..?*; do
    [ -e "$p" ] || [ -L "$p" ] || continue
    case "$p" in "$target/.aiboos-install-target"|"$target/lost+found") ;; *) fail "Target contains existing files; refusing to overwrite.";; esac
done
[ -r "$bundle/rootfs.tar.gz" ] && [ -r "$bundle/SHA256SUMS.txt" ] || fail "Embedded root filesystem missing."
echo "Verifying embedded root filesystem..."
(cd "$bundle" && sha256sum -c SHA256SUMS.txt) || fail "Payload checksum failed."
available=$(df -k "$target" | awk 'END {print $4}')
case "$available" in ''|*[!0-9]*) fail "Cannot determine free space.";; esac
[ "$available" -ge 262144 ] || fail "At least 256 MiB free space required."
stage="$target/.aiboos-incomplete"
mkdir "$stage" || fail "Could not create staging directory."
echo "Installing AiboOS Linux userspace onto the prepared volume..."
tar -xzf "$bundle/rootfs.tar.gz" -C "$stage" || fail "Extraction failed; incomplete data left in staging directory."
[ -x "$stage/bin/busybox" ] && [ -L "$stage/sbin/init" ] || fail "Installed root filesystem verification failed."
grep -qx 'ID=aiboos' "$stage/etc/os-release" || fail "Unexpected installed system identity."
# Record immutable startup payload checksums, without hashing runtime state.
(cd "$stage" && sha256sum bin/busybox bin/aiboos-fb bin/aiboos-usb-serial etc/os-release etc/inittab etc/init.d/rcS > .aiboos-system-sha256)
printf '%s\n' AIBOOS-ROOT-V1 > "$stage/.aiboos-installed"
sync
mv "$stage" "$target/AiboOS"
sync
echo "SUCCESS: AiboOS root filesystem installed at $target/AiboOS."
echo "Installed root is ready for standard Linux root handoff. Firmware startup is not installed; iOS has not been replaced."
