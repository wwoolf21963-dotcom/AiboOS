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
# Inspect the ext4 primary superblock directly: BusyBox blkid output varies
# with build options and is not a reliable machine-readable interface.
# Require extents (the supported AiboOS ext4 format), magic, and exact UUID.
# This function reads only 1024 bytes; it never writes to the device.
match_ext4_uuid() {
    expected=$(printf '%s' "$1" | /bin/busybox tr -d '-')
    hex=$(/bin/busybox dd if="$2" bs=1024 skip=1 count=1 2>/dev/null |
        /bin/busybox od -An -v -tx1 | /bin/busybox tr -d ' \n') || return 1
    [ "${#hex}" = 2048 ] || return 1
    [ "$(printf '%s' "$hex" | /bin/busybox cut -c113-116)" = 53ef ] || return 1
    feature=$(printf '%s' "$hex" | /bin/busybox cut -c193-194)
    [ "$((0x$feature & 0x40))" -ne 0 ] || return 1
    [ "$(printf '%s' "$hex" | /bin/busybox cut -c209-240)" = "$expected" ]
}
valid_uuid() {
    printf '%s\n' "$1" | /bin/busybox grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
}
# Resolve a specific ext4 filesystem UUID, without modifying any volume.
locate_uuid() {
    uuid=$1
    valid_uuid "$uuid" || fail "Invalid filesystem UUID."
    count=0
    selected=
    for entry in /sys/class/block/*; do
        [ -r "$entry/size" ] || continue
        name=$(basename "$entry")
        case "$name" in loop*|ram*|zram*|dm-*|md*) continue;; esac
        dev="/dev/$name"
        [ -b "$dev" ] || continue
        match_ext4_uuid "$uuid" "$dev" || continue
        count=$((count+1))
        selected=$dev
    done
    [ "$count" = 1 ] || fail "Expected exactly one ext4 device with UUID $uuid; found $count."
    printf '%s\n' "$selected"
}
mounted_volume_valid() {
    target=$1
    [ -f "$target/.aiboos-install-target" ] && [ ! -L "$target/.aiboos-install-target" ] || return 1
    [ "$(cat "$target/.aiboos-install-target")" = AIBOOS-DEDICATED-LINUX-VOLUME ] || return 1
    (validate "$target/AiboOS")
}
case "${1:-}" in
    --match-uuid)
        [ "$#" = 3 ] || fail "Specify UUID and a test image or block device."
        valid_uuid "$2" || fail "Invalid filesystem UUID."
        [ -f "$3" ] || [ -b "$3" ] || fail "Not an image or block device."
        match_ext4_uuid "$2" "$3"
        ;;
    --locate-uuid)
        [ "$#" = 2 ] || fail "Specify an ext4 UUID."
        locate_uuid "$2"
        ;;
    --boot-uuid)
        [ "$#" = 2 ] || fail "Specify an ext4 UUID."
        [ "$$" = 1 ] || fail "Root handoff requires Linux PID 1."
        [ "$(stat -f -c %T /)" = tmpfs ] || [ "$(stat -f -c %T /)" = ramfs ] || fail "Root handoff requires a RAM root."
        target=/mnt/aiboos
        mkdir -p "$target"
        [ "$(readlink -f "$target")" = "$target" ] || fail "Mountpoint must be canonical."
        if mountpoint -q "$target"; then fail "Mountpoint already occupied."; fi
        [ -z "$(ls -A "$target")" ] || fail "Mountpoint must be empty."
        tries=0
        while ! dev=$(locate_uuid "$2" 2>/run/aiboos-storage-start.log); do
            tries=$((tries+1))
            [ "$tries" -lt 15 ] || fail "Unable to locate designated ext4 volume."
            sleep 1
        done
        # Check the kernel's major/minor mount records, not just the device alias.
        name=$(basename "$dev")
        number=$(cat "/sys/class/block/$name/dev")
        awk -v n="$number" '$3==n{found=1} END{exit found}' /proc/self/mountinfo || fail "Designated device already mounted."
        mount -t ext4 -o ro,noload "$dev" "$target" || fail "Read-only volume mount failed."
        if ! mounted_volume_valid "$target"; then
            umount "$target" || true
            fail "Volume marker or installed system verification failed."
        fi
        umount "$target" || fail "Cannot unmount read-only volume."
        mount -t ext4 -o rw "$dev" "$target" || fail "Writable volume mount failed."
        if ! mounted_volume_valid "$target"; then
            umount "$target" || true
            fail "Installed root changed after mount."
        fi
        echo "Verified designated AiboOS volume $dev."
        exec /bin/busybox sh /bin/aiboos-root-start --boot-mounted "$target"
        ;;
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
    *) fail "Usage: aiboos-root-start --verify ROOT | --locate-uuid UUID | --boot-uuid UUID | --boot-mounted /mnt/aiboos";;
esac
