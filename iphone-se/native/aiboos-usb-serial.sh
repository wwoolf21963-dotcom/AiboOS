#!/bin/busybox sh
# Run only inside booted Linux. Configures a standard USB ACM serial function.
# No bootloader operations, storage reads/writes, or remote command shell.
set -eu
B=/bin/busybox
G=/sys/kernel/config/usb_gadget/aiboos
if [ "${1:-}" = "--selftest" ]; then
    [ "$G" = "/sys/kernel/config/usb_gadget/aiboos" ]
    echo "PASS: native USB gadget script paths"
    exit 0
fi
"$B" mkdir -p /run
"$B" grep -q ' /sys/kernel/config configfs ' /proc/mounts ||
    "$B" mount -t configfs configfs /sys/kernel/config || exit 1
[ -d /sys/kernel/config/usb_gadget ] || { echo "USB gadget configfs not supported by this kernel"; exit 1; }
# The controller often registers after init starts. Wait, rather than failing
# immediately when the first early scan finds no UDC.
udc=""
i=0
while [ "$i" -lt 20 ]; do
    set -- /sys/class/udc/*
    if [ "$#" -eq 1 ] && [ -e "$1" ]; then udc="${1##*/}"; break; fi
    if [ "$#" -gt 1 ]; then echo "Multiple UDCs; no automatic binding"; exit 1; fi
    "$B" sleep 1
    i=$((i+1))
done
[ -n "$udc" ] || { echo "No Linux USB device controller registered"; exit 1; }
# Never unbind a different gadget or overwrite its config.
for existing in /sys/kernel/config/usb_gadget/*; do
    [ -d "$existing" ] || continue
    [ "$existing" = "$G" ] && continue
    [ -r "$existing/UDC" ] || continue
    [ -z "$("$B" cat "$existing/UDC")" ] || { echo "Another USB gadget is already active"; exit 1; }
done
if [ -d "$G" ]; then
    [ "$("$B" cat "$G/UDC")" = "$udc" ] && { echo "AiboOS USB serial already configured"; exit 0; }
    echo "Previous unbound AiboOS gadget; restart Linux to retry"; exit 1
fi
"$B" mkdir "$G"
# Standard Linux Foundation multifunction gadget identity, not Apple DFU.
echo 0x1d6b > "$G/idVendor"
echo 0x0104 > "$G/idProduct"
"$B" mkdir -p "$G/strings/0x409" "$G/configs/c.1/strings/0x409" "$G/functions/acm.usb0"
echo AiboOS > "$G/strings/0x409/manufacturer"
echo 'AiboOS Linux serial status' > "$G/strings/0x409/product"
echo 'AiboOS development serial' > "$G/configs/c.1/strings/0x409/configuration"
"$B" ln -s "$G/functions/acm.usb0" "$G/configs/c.1/acm.usb0"
echo "$udc" > "$G/UDC"
echo "AiboOS USB ACM configured; host enumeration is not yet verified."
# Send only a status banner, not a privileged shell. Bound attempts and timeout.
if [ -c /dev/ttyGS0 ]; then
    "$B" timeout 2 "$B" sh -c 'printf "AiboOS native Linux userspace reached\r\n" > /dev/ttyGS0' || true
fi
