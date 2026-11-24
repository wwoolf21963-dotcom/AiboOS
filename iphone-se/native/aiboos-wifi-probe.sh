#!/bin/sh
# Read-only bring-up report for the Samsung A9 iPhone SE (n69u).
# Run inside the booted AiboOS Linux RAM system, not on macOS.
# No module loads, firmware writes, PCI config writes, radio activation or disk access.
set -u
PATH=/bin:/sbin:/usr/bin:/usr/sbin
export PATH

section() { printf '\n=== %s ===\n' "$1"; }
read_attr() { if [ -r "$1" ]; then tr '\000' '\n' < "$1"; else printf '(unavailable)\n'; fi; }
dt=/sys/firmware/devicetree/base
[ -d "$dt" ] || dt=/proc/device-tree

section 'Board and kernel'
uname -a
printf 'compatible: '; read_attr "$dt/compatible"
printf 'model: '; read_attr "$dt/model"
if ! [ -r "$dt/compatible" ] || ! tr '\000' '\n' < "$dt/compatible" | grep -qx 'apple,n69u'; then
    echo 'Not the expected n69u board; report stopped.'
    exit 1
fi

section 'Kernel Wi-Fi / PCI configuration'
if [ -r /proc/config.gz ] && command -v zcat >/dev/null 2>&1; then
    zcat /proc/config.gz | grep -E '^(CONFIG_(PCI|PCIEPORTBUS|PCI_.*APPLE.*|.*DART.*|CFG80211|MAC80211|BRCMFMAC.*|BRCMUTIL|FW_LOADER.*|RFKILL.*)=|# CONFIG_(PCI|PCIEPORTBUS|PCI_.*APPLE.*|.*DART.*|CFG80211|MAC80211|BRCMFMAC.*|BRCMUTIL|FW_LOADER.*|RFKILL.*) is not set)' || :
else
    echo 'Kernel configuration not exposed; inspect matching build config on host.'
fi

section 'PCIe and Wi-Fi device tree nodes'
find "$dt" -type d | grep -Ei '/[^/]*(pcie|pci@|wlan|wifi|wireless|bcm4345)[^/]*$' | while IFS= read -r node; do
    printf '%s\n' "${node#"$dt"}"
    printf '  compatible: '; read_attr "$node/compatible"
    if [ -r "$node/status" ]; then printf '  status: '; read_attr "$node/status"; else echo '  status: absent (defaults to okay)'; fi
done

section 'PCI devices (no configuration-space access)'
found=0
for dev in /sys/bus/pci/devices/*; do
    [ -d "$dev" ] || continue
    found=1
    printf '%s\n' "${dev##*/}"
    for attr in vendor device class; do
        printf '  %s: ' "$attr"; read_attr "$dev/$attr"
    done
    if [ -L "$dev/driver" ]; then printf '  driver: %s\n' "$(readlink "$dev/driver")"; else echo '  driver: unbound'; fi
done
[ "$found" -eq 1 ] || echo 'No PCI devices enumerated.'

section 'Network interfaces and wireless PHY'
for path in /sys/class/net/* /sys/class/ieee80211/*; do
    [ -e "$path" ] && printf '%s\n' "$path"
done

section 'Firmware filenames (no contents)'
if [ -d /lib/firmware ]; then
    find /lib/firmware -type f | grep -Ei '(brcm|bcm4345|hans)' || :
else
    echo 'No /lib/firmware directory.'
fi

section 'Relevant kernel messages'
if command -v dmesg >/dev/null 2>&1; then
    dmesg | grep -Ei 'pcie|pci[ :]|dart|iommu|brcmfmac|bcm4345|cfg80211|rfkill|firmware' || :
else
    echo 'dmesg unavailable.'
fi
echo 'Read-only report complete. No radio or storage operations requested.'
