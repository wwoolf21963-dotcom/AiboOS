#!/usr/bin/env bash
# Build-only experiment for the original iPhone SE (A9 / iPhone8,4).
# It does not access an iPhone, flash partitions, or produce an installable OS.
set -euo pipefail

ROOT="$(pwd)"
BUILD="$RUNNER_TEMP/aiboos-iphone-se"
mkdir -p "$BUILD" "$ROOT/iphone-se-artifact"
cd "$BUILD"

echo 'Cloning upstream Hoolock ARM64 Linux source (hoolock branch)...'
git clone --depth 1 --branch hoolock https://github.com/HoolockLinux/linux.git kernel

echo 'Fetching upstream Hoolock 16 KiB page config (A9 family)...'
curl --retry 3 --retry-all-errors -fsSL \
  https://raw.githubusercontent.com/HoolockLinux/docs/master/config_16k \
  -o kernel/.config

git -C kernel rev-parse HEAD > "$ROOT/iphone-se-artifact/kernel-commit.txt"
curl --retry 3 --retry-all-errors -fsSL \
  https://raw.githubusercontent.com/HoolockLinux/docs/master/tutorials/SETUP.md \
  -o "$ROOT/iphone-se-artifact/upstream-setup.md"

echo 'Configuring ARM64 kernel with runner LLVM toolchain...'
make -C kernel LLVM=1 ARCH=arm64 olddefconfig

echo 'Compiling experimental ARM64 kernel and Apple DTBs...'
make -C kernel -j"$(nproc)" LLVM=1 ARCH=arm64 Image.gz dtbs

KERNEL="$BUILD/kernel/arch/arm64/boot/Image.gz"
DTB_DIR="$BUILD/kernel/arch/arm64/boot/dts/apple"
test -s "$KERNEL"
test -d "$DTB_DIR"
if ! find "$DTB_DIR" -type f -name '*.dtb' -size +0c -print -quit | grep -q .; then
  echo 'No Apple device trees produced' >&2
  exit 1
fi
cp "$KERNEL" "$ROOT/iphone-se-artifact/Image.gz"
mkdir -p "$ROOT/iphone-se-artifact/apple-dtbs"
find "$DTB_DIR" -type f -name '*.dtb' -exec cp -t "$ROOT/iphone-se-artifact/apple-dtbs" {} +

mkdir -p "$ROOT/iphone-se-artifact/aiboos-web"
cp -a "$ROOT/AiboOS/Web/." "$ROOT/iphone-se-artifact/aiboos-web/"
cat > "$ROOT/iphone-se-artifact/READ_ME_FIRST.txt" <<'TXT'
AiboOS SE (2016) - Experimental ARM64 kernel BUILD ARTIFACT

This is NOT a phone-flash image, installable OS, full Linux boot package,
or proof of successful booting on an Apple A9/iPhone8,4.

Included:
- Image.gz: Hoolock experimental ARM64 Linux kernel
- apple-dtbs/: device tree files (not yet validated for this handset)
- aiboos-web/: AiboOS web UI source (not yet integrated as an ARM64 bootable image)
- kernel-commit.txt: exact upstream kernel commit
- upstream-setup.md: Hoolock build documentation snapshot

Missing / unverified:
- matching iPhone SE device tree, initramfs, m1n1/pongoOS USB boot chain
- functional on-device input/display/storage and recovery
- safe permanent iOS replacement on A9 internal storage

Do NOT flash this package to your iPhone. The x86_64 PC ISO is not for iPhone.
TXT
cd "$ROOT/iphone-se-artifact"
sha256sum Image.gz apple-dtbs/*.dtb > SHA256SUMS.txt
printf 'AiboOS SE ARM64 development artifact generated. No phone flashed.\n'
