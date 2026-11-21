#!/usr/bin/env bash
# Packages board-specific A9 iPhone SE (2016) RAM-only Linux bring-up experiments.
# This does NOT run a USB exploit, flash storage, or modify a phone.
set -euo pipefail
ROOT="$(pwd)"
SRC="$ROOT/previous-ram-kit"
OUT="$ROOT/iphone-se-a9-targeted"
test -s "$SRC/m1n1.bin"
test -s "$SRC/Image.gz"
test -s "$SRC/initramfs.cpio.gz"
test -d "$SRC/apple-dtbs"
(cd "$SRC" && sha256sum -c SHA256SUMS.txt)
gzip -t "$SRC/Image.gz"
gzip -t "$SRC/initramfs.cpio.gz"
mkdir -p "$OUT/Samsung-S8000" "$OUT/TSMC-S8003"
cp "$SRC/READ_ME_FIRST.txt" "$OUT/UPSTREAM_EXPERIMENT_NOTES.txt"

for variant in Samsung-S8000 TSMC-S8003; do
  case "$variant" in
    Samsung-S8000)
      dtb="s8000-n69u.dtb"
      compatibility="apple,n69u"
      ;;
    TSMC-S8003)
      dtb="s8003-n69.dtb"
      compatibility="apple,n69"
      ;;
  esac
  test -s "$SRC/apple-dtbs/$dtb"
  actual="$(fdtget -t s "$SRC/apple-dtbs/$dtb" / compatible)"
  echo "$actual" | grep -Fq "$compatibility" || { echo "Wrong DTB for $variant: $actual" >&2; exit 1; }
  dir="$OUT/$variant"
  cp "$SRC/m1n1.bin" "$dir/m1n1.bin"
  cp "$SRC/Image.gz" "$dir/Image.gz"
  cp "$SRC/initramfs.cpio.gz" "$dir/initramfs.cpio.gz"
  cp "$SRC/apple-dtbs/$dtb" "$dir/$dtb"
  printf '%s\n' 'chosen.bootargs=console=tty0 loglevel=7 rdinit=/init' > "$dir/bootargs.txt"
  cat "$dir/m1n1.bin" "$dir/bootargs.txt" "$dir/$dtb" "$dir/Image.gz" "$dir/initramfs.cpio.gz" > "$dir/m1n1-linux.bin"
  (cd "$dir" && sha256sum m1n1.bin bootargs.txt "$dtb" Image.gz initramfs.cpio.gz m1n1-linux.bin > SHA256SUMS.txt)
  (cd "$dir" && sha256sum -c SHA256SUMS.txt)
  python3 - "$dir" "$dtb" <<'PY'
import pathlib,sys
folder=pathlib.Path(sys.argv[1]); dtb=sys.argv[2]
parts=["m1n1.bin","bootargs.txt",dtb,"Image.gz","initramfs.cpio.gz"]
expect=b"".join((folder/p).read_bytes() for p in parts)
actual=(folder/"m1n1-linux.bin").read_bytes()
assert actual==expect, "Payload integrity/order failure"
assert all((folder/p).stat().st_size>0 for p in parts)
print(folder.name,"payload exact byte-layout checked:",len(actual))
PY
done
cp iphone-se/Windows-Readiness.ps1 "$OUT/Windows-Readiness.ps1"
cp iphone-se/Start-Readiness.cmd "$OUT/Start-Readiness.cmd"
cp iphone-se/README_FIRST.txt "$OUT/READ_ME_FIRST.txt"
cat > "$OUT/BUILD_PROVENANCE.txt" <<'TXT'
Source build: GitHub Actions run 44907245315
Kernel source: HoolockLinux/linux (hoolock branch)
m1n1 source: HoolockLinux/m1n1 (idevice branch)
Target: first-generation iPhone SE, iPhone8,4, Apple A9
This is NOT flashable and is NOT a phone operating-system installer.
TXT
echo 'A9 board-specific experimental packages validated. No USB/device access performed.'
