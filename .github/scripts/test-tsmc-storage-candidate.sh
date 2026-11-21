#!/usr/bin/env bash
set -euo pipefail
ROOT="$PWD"
K="$RUNNER_TEMP/tsmc-source"
OUT="$ROOT/tsmc-storage-review"
PIN=ef92d0d3b34aecba1fca233c4b983f89d1dbaaa1
git init "$K"
git -C "$K" remote add origin https://github.com/OrchardLinux/linux.git
git -C "$K" fetch --depth=1 origin "$PIN"
git -C "$K" checkout --detach FETCH_HEAD
test "$(git -C "$K" rev-parse HEAD)" = "$PIN"
make -C "$K" ARCH=arm64 LLVM=1 orchard_apple16k_defconfig
DIR="$K/arch/arm64/boot/dts/apple"
# Compile original and private review variant independently. Never replace
# the normal kernel artifact or deploy either DTB to a phone.
make -C "$K" ARCH=arm64 LLVM=1 apple/s8003-n69.dtb apple/s8000-n69u.dtb
cp "$DIR/s8003-n69.dtb" "$RUNNER_TEMP/original-n69.dtb"
cat "$ROOT/iphone-se/research/s8003-n69-storage-candidate.dtsi" >> "$DIR/s8003-n69.dts" 
make -C "$K" ARCH=arm64 LLVM=1 apple/s8003-n69.dtb
mkdir -p "$OUT"
python3 - "$RUNNER_TEMP/original-n69.dtb" "$DIR/s8003-n69.dtb" "$DIR/s8000-n69u.dtb" "$OUT" <<'PY'
import subprocess, sys, pathlib
original, candidate, samsung, out = sys.argv[1:]
def get(f,n,p,t="s"):
    return subprocess.check_output(["fdtget","-t",t,f,n,p], text=True).strip()
def walk(f,n="/"):
    nodes=[n]
    for child in subprocess.check_output(["fdtget","-l",f,n],text=True).splitlines():
        nodes+=walk(f,n.rstrip("/")+"/"+child)
    return nodes
def find(f,suffix):
    matches=[n for n in walk(f) if n.endswith("/"+suffix)]
    assert len(matches)==1, matches
    return matches[0]
pcie=find(original,"pcie@610000000")
dart0=find(original,"iommu@601008000")
dart1=find(original,"iommu@602008000")
assert get(original,pcie,"status")=="disabled"
assert get(original,dart0,"status")=="disabled"
assert get(candidate,pcie,"status")=="okay"
assert get(candidate,dart0,"status")=="okay"
assert get(candidate,dart1,"status")=="disabled"
assert "apple,n69" in get(candidate,"/","compatible").split()
assert "apple,n69u" in get(samsung,"/","compatible").split()
assert len(get(candidate,pcie,"iommu-map","x").split())==8
assert [n for n in walk(candidate,pcie) if "/pci@" in n]==[pcie+"/pci@0,0"]
for p in ["reg","interrupts","power-domains","reg-names","apple,nvme-hmb"]:
    t="s" if p=="reg-names" else "x"
    assert get(original,pcie,p,t)==get(candidate,pcie,p,t),p
for p in ["reg","reset-gpios","num-lanes","max-link-speed"]:
    assert get(original,pcie+"/pci@0,0",p,"x")==get(candidate,pcie+"/pci@0,0",p,"x"),p
report="PASS: TSMC storage-only device-tree candidate compiles; Samsung original unchanged; upstream resource layout preserved; only DART0 and storage port enabled. No hardware test. NVMe HMB reserved memory and boot support remain unresolved."
print(report)
(pathlib.Path(out)/"result.txt").write_text(report+"\n")
PY
# Source + report only. No bootable candidate distributed.
cp "$ROOT/iphone-se/research/s8003-n69-storage-candidate.dtsi" "$OUT/"
