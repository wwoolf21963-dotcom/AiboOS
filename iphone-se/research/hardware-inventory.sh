#!/bin/sh
# Read-only Linux hardware inventory. No battery/charger control, device
# register access, mounting, firmware modification or block-device reads.
set -eu
root=/sys
if [ "$#" -gt 0 ]; then
    [ "$#" -eq 2 ] && [ "$1" = "--fixture" ] || exit 2
    root=$2
fi
value() {
    if [ -r "$1" ]; then
        tr -d '\000\r\n' < "$1" 2>/dev/null || printf 'unavailable'
    else
        printf 'unavailable'
    fi
}
section() { printf '\n[%s]\n' "$1"; }
count_class() {
    count=0
    for item in "$root/class/$1"/$2; do
        [ -e "$item" ] || continue
        count=$((count+1))
    done
    printf '%s: %s enumerated (not functionality proof)\n' "$1" "$count"
}
printf 'AiboOS read-only Linux hardware inventory\n'
printf 'model: %s\n' "$(value "$root/firmware/devicetree/base/model")"
section power
found=0
for p in "$root"/class/power_supply/*; do
    [ -d "$p" ] || continue
    found=1
    printf '%s\n' "${p##*/}"
    for field in type present online status health capacity voltage_now current_now temp; do
        printf '  %s=%s\n' "$field" "$(value "$p/$field")"
    done
done
[ "$found" = 1 ] || printf 'No power_supply interface exposed; charging and battery state unverified.\n'
section thermal
for p in "$root"/class/thermal/thermal_zone*; do
    [ -d "$p" ] || continue
    printf '%s type=%s temp_mC=%s\n' "${p##*/}" "$(value "$p/type")" "$(value "$p/temp")"
done
section storage
count_class block 'nvme*n*'
section display_and_input
count_class graphics 'fb*'
count_class backlight '*'
count_class input 'event*'
section audio
count_class sound 'card*'
section connectivity
count_class udc '*'
count_class net '*'
count_class bluetooth '*'
section sensors_and_camera
count_class iio '*'
count_class video4linux 'video*'
printf '\nInventory is not hardware validation. Missing readings are not zero values.\n'
