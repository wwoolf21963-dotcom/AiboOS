#!/usr/bin/env bash
# Windows MSYS2 build of a guarded upstream openra1n first-stage experiment.
# Does not access an actual iPhone.
set -euo pipefail
UPSTREAM="49fb794cde1f73cc7a00b502a42b994926c64c63"
git clone --quiet https://github.com/palera1n/openra1n.git upstream-openra1n
git -C upstream-openra1n checkout --quiet "$UPSTREAM"
test "$(git -C upstream-openra1n rev-parse HEAD)" = "$UPSTREAM"
cd upstream-openra1n
python3 ../windows-pongo-stage1/patch-upstream.py
mkdir -p include/payloads ../dist/native-first-stage
python3 - <<'PY'
from pathlib import Path
for source in Path("payloads").glob("*"):
    if not source.is_file():
        continue
    data = source.read_bytes()
    name = "payloads_" + source.name.replace(".","_").replace("-","_")
    out = Path("include/payloads") / (source.name + ".h")
    rows = [", ".join("0x%02x" % b for b in data[i:i+12]) for i in range(0,len(data),12)]
    out.write_text("unsigned char "+name+"[] = {\n  "+",\n  ".join(rows)+"\n};\n"
                   +"unsigned int "+name+"_len = "+str(len(data))+";\n")
    print("Embedded upstream payload:",source.name,len(data),"bytes")
PY
gcc -std=gnu11 -O2 -Wall -fcommon -DWIN32 -DHAVE_LIBUSB -I./include \
  ../windows-pongo-stage1/guarded-main.c \
  common.c checkm8.c usb.c usb_libusb.c lz4/lz4.c lz4/lz4hc.c \
  -lusb-1.0 -o ../dist/native-first-stage/aiboos-pongo-stage1.exe
cp /ucrt64/bin/libusb-1.0.dll ../dist/native-first-stage/
cp ../windows-pongo-stage1/Start-Stage1-Diagnostics.cmd ../dist/native-first-stage/
cp ../windows-pongo-stage1/AiboOS-Windows-Setup.ps1 ../dist/native-first-stage/
cp ../windows-pongo-stage1/Start-AiboOS-Setup.cmd ../dist/native-first-stage/
cp ../windows-pongo-stage1/README_FIRST.txt ../dist/native-first-stage/
printf 'Pinned upstream palera1n/openra1n revision: %s\n' "$UPSTREAM" > ../dist/native-first-stage/UPSTREAM.txt
../dist/native-first-stage/aiboos-pongo-stage1.exe --selftest
../dist/native-first-stage/aiboos-pongo-stage1.exe --help
../dist/native-first-stage/aiboos-pongo-stage1.exe --probe
(cd ../dist/native-first-stage && sha256sum aiboos-pongo-stage1.exe libusb-1.0.dll > SHA256SUMS.txt)
