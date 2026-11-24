#!/usr/bin/env python3
"""Inventory S8000 PCIe routine identifiers in public restore firmware.
No execution of firmware, device access, register writes, or binary redistribution.
"""
import hashlib
import importlib.util
import json
import pathlib
import re
import sys
import urllib.request
import zipfile

spec = importlib.util.spec_from_file_location("adt", pathlib.Path(__file__).with_name("compare-firmware-trees.py"))
adt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(adt)

class KernelRange(adt.RangeFile):
    def read(self, n=-1):
        n = adt.SIZE - self.pos if n < 0 else min(n, adt.SIZE - self.pos)
        if self.received + n > 128 * 1024 * 1024:
            raise ValueError("kernel research download budget exceeded")
        pieces = []
        while n:
            count = min(n, 4 * 1024 * 1024)
            end = self.pos + count - 1
            request = urllib.request.Request(adt.URL, headers={
                "Range": f"bytes={self.pos}-{end}", "Accept-Encoding": "identity"})
            with urllib.request.urlopen(request, timeout=60) as response:
                if response.status != 206 or response.headers.get("Content-Range") != f"bytes {self.pos}-{end}/{adt.SIZE}":
                    raise ValueError("incorrect range response")
                data = response.read(count + 1)
            if len(data) != count:
                raise ValueError("short range")
            pieces.append(data)
            self.pos += count
            self.received += count
            n -= count
        return b"".join(pieces)

def unpack_kernel(blob):
    tag, seq, end = adt.tlv(blob, 0)
    if tag != 0x30 or end != len(blob):
        raise ValueError("unexpected IM4P")
    pos = 0
    for expected in (b"IM4P", b"krnl"):
        tag, value, pos = adt.tlv(seq, pos)
        if tag != 0x16 or value != expected:
            raise ValueError("not kernel IM4P")
    tag, _, pos = adt.tlv(seq, pos)
    if tag != 0x16:
        raise ValueError("missing description")
    tag, raw, pos = adt.tlv(seq, pos)
    if tag != 4:
        raise ValueError("missing payload")
    if raw.startswith((b"bvx2", b"bvx1", b"bvx-", b"bvxn")):
        import lzfse
        raw = lzfse.decompress(raw)
    if not raw.startswith(b"\xcf\xfa\xed\xfe") or len(raw) > 256 * 1024 * 1024:
        raise ValueError("unsupported compressed/encrypted kernel or size")
    return raw

# Only collect identifiers relevant to the PCIe driver, not arbitrary firmware strings.
PATTERN = re.compile(rb"[A-Za-z0-9_.$:]{0,40}AppleS800[03xX]PCIe[A-Za-z0-9_.$:]{0,100}")
def inventory(raw):
    return sorted({m.group().decode("ascii") for m in PATTERN.finditer(raw)})

def main():
    assert inventory(b"\0AppleS8000PCIe\0unrelated\0AppleS8003PCIePort\0") == ["AppleS8000PCIe", "AppleS8003PCIePort"]
    if "--selftest" in sys.argv:
        print("PASS restricted identifier inventory")
        return
    report = {"firmware": adt.URL, "scope": "static PCIe identifier inventory; not initialization evidence"}
    with KernelRange() as remote, zipfile.ZipFile(remote) as archive:
        candidates = [i for i in archive.infolist() if pathlib.PurePosixPath(i.filename).name.startswith("kernelcache.release.")]
        report["candidate_names"] = [i.filename for i in candidates]
        results = []
        # Inspect at most two candidate caches. Refuse ambiguous archives.
        if not 1 <= len(candidates) <= 2:
            raise ValueError(f"unexpected kernelcache candidates: {report['candidate_names']}")
        for item in candidates:
            if item.file_size > 64 * 1024 * 1024:
                raise ValueError("kernelcache member exceeds limit")
            blob = archive.read(item)
            entry = {"member": item.filename, "sha256": hashlib.sha256(blob).hexdigest()}
            try:
                raw = unpack_kernel(blob)
                entry["identifiers"] = inventory(raw)
                entry["status"] = "inspected"
            except ValueError as exc:
                entry["status"] = str(exc)
            results.append(entry)
        report["results"] = results
        report["download_bytes"] = remote.received
    out = pathlib.Path("s8000-phy-audit")
    out.mkdir(exist_ok=True)
    (out / "kernel-pcie-inventory.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    if not any(e.get("identifiers") for e in results):
        print("No matching identifiers found; initialization remains unsupported.")

if __name__ == "__main__":
    main()
