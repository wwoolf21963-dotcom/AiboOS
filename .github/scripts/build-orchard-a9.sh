#!/usr/bin/env bash
set -euo pipefail
ROOT="$PWD"
PIN=ef92d0d3b34aecba1fca233c4b983f89d1dbaaa1
K="$RUNNER_TEMP/orchard-a9"
OUT="$ROOT/orchard-a9-artifact"
mkdir -p "$K" "$OUT/apple-dtbs"
git -C "$K" init
git -C "$K" remote add origin https://github.com/OrchardLinux/linux.git
git -C "$K" fetch --depth=1 origin "$PIN"
git -C "$K" checkout --detach FETCH_HEAD
test "$(git -C "$K" rev-parse HEAD)" = "$PIN"
printf '%s\n' "$PIN" > "$OUT/kernel-commit.txt"
PATCH="$ROOT/iphone-se/kernel-patches/0001-h9p-independent-phy-resources.patch"
git -C "$K" apply --check "$PATCH"
git -C "$K" apply "$PATCH"
git -C "$K" diff --check
cp "$PATCH" "$OUT/"
make -C "$K" ARCH=arm64 LLVM=1 orchard_apple16k_defconfig
# Standard Linux runtime features only. Preserve all upstream board definitions.
"$K/scripts/config" --file "$K/.config" \
  --enable BLK_DEV_INITRD --enable RD_GZIP --enable DEVTMPFS \
  --enable DEVTMPFS_MOUNT --enable EXT4_FS --enable INPUT_EVDEV \
  --enable KEYBOARD_GPIO --enable USB_CONFIGFS_ACM \
  --enable PCI --enable PCI_MSI --enable PCIE_APPLE_H9P \
  --enable APPLE_DART --enable BLK_DEV_NVME --enable NVME_APPLE \
  --enable NVME_VERBOSE_ERRORS
make -C "$K" ARCH=arm64 LLVM=1 olddefconfig
for key in ARM64_16K_PAGES BLK_DEV_INITRD RD_GZIP DEVTMPFS EXT4_FS INPUT_EVDEV KEYBOARD_GPIO PCI PCI_MSI PCIE_APPLE_H9P APPLE_DART BLK_DEV_NVME NVME_CORE NVME_VERBOSE_ERRORS; do
    grep -qx "CONFIG_$key=y" "$K/.config"
done
make -C "$K" -j"$(nproc)" ARCH=arm64 LLVM=1 Image.gz dtbs
cp "$K/arch/arm64/boot/Image.gz" "$OUT/"
cp "$K/.config" "$OUT/kernel.config"
for board in s8000-n69u s8003-n69; do
    cp "$K/arch/arm64/boot/dts/apple/$board.dtb" "$OUT/apple-dtbs/"
    dtc -q -I dtb -O dts "$OUT/apple-dtbs/$board.dtb" > "$OUT/$board.dts"
done
python3 - "$OUT" <<'PY'
import pathlib, subprocess, gzip, sys
out=pathlib.Path(sys.argv[1])
with gzip.open(out/"Image.gz","rb") as f:
    assert f.read(64)[56:60]==b"ARM\x64"
report=["OrchardLinux A9 build: static inspection only, not hardware tests.", "AiboOS H9P independent PHY-resource patch applied; S8000 initialization unfinished."]
def fdt(p,node,prop):
    return subprocess.check_output(["fdtget","-t","s",str(p),node,prop],text=True).strip()
for board,compatible in [("s8000-n69u","apple,n69u"),("s8003-n69","apple,n69")]:
    p=out/"apple-dtbs"/(board+".dtb")
    assert compatible in fdt(p,"/","compatible").split()
    report.append(board+": "+fdt(p,"/","model"))
    def walk(node):
        children=subprocess.check_output(["fdtget","-l",str(p),node],text=True).splitlines()
        for child in children:
            sub=node.rstrip("/")+"/"+child
            if child.startswith(("pcie@","iommu@","nvme@","ans@","nand@")):
                props=subprocess.check_output(["fdtget","-p",str(p),sub],text=True).splitlines()
                status=fdt(p,sub,"status") if "status" in props else "okay (implicit)"
                report.append("  "+sub+": "+status)
                if board=="s8003-n69" and child=="pcie@610000000":
                    assert status=="disabled", "Unexpected upstream SE PCIe status"
            walk(sub)
    walk("/")
report.append("No A9 storage driver has been validated on an iPhone. No phone accessed.")
report.append("Selected effective kernel configuration:")
for line in (out/"kernel.config").read_text().splitlines():
    if any(x in line for x in ("CONFIG_NVME","CONFIG_BLK_DEV_NVME","CONFIG_PCIE_APPLE","CONFIG_APPLE_DART","CONFIG_TOUCHSCREEN_APPLE","CONFIG_SND_SOC_APPLE","CONFIG_USB_CONFIGFS_ACM","CONFIG_DRM_SIMPLEDRM")):
        report.append(line)
(out/"HARDWARE-REPORT.txt").write_text("\n".join(report)+"\n")
print("\n".join(report))
PY
(cd "$ROOT/current-rootfs" && sha256sum -c SHA256SUMS.txt)
cp "$ROOT/current-rootfs/AiboOS-ARM64-rootfs.ext4.xz" "$OUT/"
cat > "$OUT/READ_ME.txt" <<'TXT'
AiboOS native OrchardLinux A9 kernel evaluation
Includes both original iPhone SE board trees, kernel configuration, hardware
audit and current ARM64 root filesystem. No phone transport or flash operation.
This is NOT an iPhone installer. The kernel and root filesystem have not been
boot-tested together on an iPhone. The TSMC storage controller remains disabled
for the SE in the upstream device tree. No speculative hardware definitions.
TXT
(cd "$OUT" && sha256sum Image.gz apple-dtbs/*.dtb kernel.config kernel-commit.txt 0001-h9p-independent-phy-resources.patch AiboOS-ARM64-rootfs.ext4.xz HARDWARE-REPORT.txt > SHA256SUMS.txt && sha256sum -c SHA256SUMS.txt)
