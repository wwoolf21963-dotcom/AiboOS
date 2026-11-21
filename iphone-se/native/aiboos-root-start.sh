#!/bin/sh
# Standard Linux-only root handoff, after the Linux kernel has already booted.
# No firmware, DFU, bootloader, partitioning, or raw block write operations.
set -eu
PATH=/bin:/sbin:/usr/bin:/usr/sbin
export PATH
fail() { echo "AiboOS root: $*" >&2; exit 1; }
validate() {
    root=$1
    [ -d "$root" ] && [ ! -L "$root" ] || fail "Installed root missing."
    [ -f "$root/.aiboos-installed" ] && [ ! -L "$root/.aiboos-installed" ] || fail "Installation marker missing."
    [ "$(cat "$root/.aiboos-installed")" = "AIBOOS-ROOT-V1" ] || fail "Unknown installation version."
    [ -f "$root/etc/os-release" ] && grep -qx 'ID=aiboos' "$root/etc/os-release" || fail "System identity mismatch."
    [ -f "$root/bin/busybox" ] && [ -x "$root/bin/busybox" ] || fail "BusyBox missing."
    [ -L "$root/sbin/init" ] && [ "$(readlink "$root/sbin/init")" = "../bin/busybox" ] || fail "Init invalid."
    for d in dev proc sys run; do
        [ -d "$root/$d" ] && [ ! -L "$root/$d" ] || fail "Virtual filesystem mountpoint invalid: $d"
    done
    (cd "$root" && sha256sum -c .aiboos-system-sha256) || fail "Installed system checksum mismatch."
}
case "${1:-}" in
    --verify)
        [ "$#" = 2 ] || fail "Specify installed root."
        validate "$2"
        echo "Verified installed AiboOS root filesystem."
        ;;
    --boot-mounted)
        [ "$#" = 2 ] || fail "Specify an already mounted dedicated Linux volume."
        [ "$$" = 1 ] || fail "Root handoff requires Linux PID 1."
        [ "$(stat -f -c %T /)" = tmpfs ] || [ "$(stat -f -c %T /)" = ramfs ] || fail "Root handoff requires a RAM root."
        target=$2
        [ "$target" = /mnt/aiboos ] || fail "Only the dedicated /mnt/aiboos mount is supported."
        awk -v t="$target" '$2==t && $3=="ext4" && $4 ~ /(^|,)rw(,|$)/ {n++} END{exit n!=1}' /proc/mounts || fail "Dedicated ext4 volume not mounted writable."
        [ -f "$target/.aiboos-install-target" ] && [ ! -L "$target/.aiboos-install-target" ] || fail "Volume marker missing."
        [ "$(cat "$target/.aiboos-install-target")" = AIBOOS-DEDICATED-LINUX-VOLUME ] || fail "Volume marker mismatch."
        root="$target/AiboOS"
        validate "$root"
        # A bind mount makes the installed subdirectory a separate mountpoint.
        mount --bind "$root" "$root"
        # Move the virtual mounts so the root's init can use existing devices.
        for d in run sys proc dev; do
            if mountpoint -q "/$d"; then
                mount --move "/$d" "$root/$d" || fail "Cannot move /$d; restart Linux to recover."
            fi
        done
        echo "Starting installed AiboOS Linux userspace."
        exec /bin/busybox switch_root "$root" /sbin/init
        ;;
    *) fail "Usage: aiboos-root-start --verify ROOT | --boot-mounted /mnt/aiboos";;
esac
