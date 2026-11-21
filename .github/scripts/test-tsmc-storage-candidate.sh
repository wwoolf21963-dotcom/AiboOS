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
# DTC allocates phandles independently for each compilation. Compare reference
# targets and argument cells instead of treating generated IDs as hardware data.
def phandles(f):
    result={}
    for node in walk(f):
        proc=subprocess.run(["fdtget","-t","x",f,node,"phandle"],text=True,capture_output=True)
        if proc.returncode == 0:
            value=int(proc.stdout.strip(),16)
            assert value not in result
            result[value]=node
    return result

def refs(f, node, prop, handles, count_property=None):
    cells=[int(x,16) for x in get(f,node,prop,"x").split()]
    result=[]
    while cells:
        target=handles[cells.pop(0)]
        count=int(get(f,target,count_property,"x"),16) if count_property else 0
        assert len(cells)>=count
        result.append((target,tuple(cells[:count])))
        del cells[:count]
    return result

orig_handles=phandles(original)
test_handles=phandles(candidate)
for p in ["reg","interrupts","reg-names"]:
    t="s" if p=="reg-names" else "x"
    assert get(original,pcie,p,t)==get(candidate,pcie,p,t),p
for p,count in [("power-domains","#power-domain-cells"),("apple,nvme-hmb",None)]:
    assert refs(original,pcie,p,orig_handles,count)==refs(candidate,pcie,p,test_handles,count),p
for p in ["reg","num-lanes","max-link-speed"]:
    assert get(original,pcie+"/pci@0,0",p,"x")==get(candidate,pcie+"/pci@0,0",p,"x"),p
assert refs(original,pcie+"/pci@0,0","reset-gpios",orig_handles,"#gpio-cells")==refs(candidate,pcie+"/pci@0,0","reset-gpios",test_handles,"#gpio-cells"),"reset-gpios"
cells=[int(x,16) for x in get(candidate,pcie,"iommu-map","x").split()]
assert test_handles[cells[1]]==dart0 and cells[0]==0x100 and cells[2:]==[0,0,0x80000000,0,0x3c000000,1],"storage IOMMU mapping"
report="PASS: TSMC storage-only device-tree candidate compiles; Samsung original unchanged; upstream resource layout preserved; only DART0 and storage port enabled. No hardware test. NVMe HMB reserved memory and boot support remain unresolved."
print(report)
(pathlib.Path(out)/"result.txt").write_text(report+"\n")
PY
# Source + report only. No bootable candidate distributed.
cp "$ROOT/iphone-se/research/s8003-n69-storage-candidate.dtsi" "$OUT/"
