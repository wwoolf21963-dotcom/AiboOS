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
import struct
import zlib
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

def unpack_lzss(raw):
    # Apple complzss: 0x180-byte header, big-endian checksum and sizes.
    if len(raw) < 0x180 or raw[:8] != b"complzss":
        raise ValueError("invalid LZSS header")
    checksum, size, packed = struct.unpack_from(">III", raw, 8)
    if not 0 < size <= 256 * 1024 * 1024 or not 0 < packed <= len(raw) - 0x180:
        raise ValueError("invalid LZSS sizes")
    data = memoryview(raw)[0x180:0x180 + packed]
    ring = bytearray(b" " * 4096)
    cursor = 4096 - 18
    pos = 0
    out = bytearray()
    while pos < len(data) and len(out) < size:
        flags = data[pos]
        pos += 1
        for bit in range(8):
            if len(out) == size:
                break
            if pos >= len(data):
                raise ValueError("truncated LZSS stream")
            if flags & (1 << bit):
                value = data[pos]
                pos += 1
                out.append(value)
                ring[cursor] = value
                cursor = (cursor + 1) & 4095
            else:
                if pos + 2 > len(data):
                    raise ValueError("truncated LZSS pair")
                index = data[pos] | ((data[pos + 1] & 0xf0) << 4)
                count = (data[pos + 1] & 15) + 3
                pos += 2
                if len(out) + count > size:
                    raise ValueError("LZSS output exceeds declared size")
                for k in range(count):
                    value = ring[(index + k) & 4095]
                    out.append(value)
                    ring[cursor] = value
                    cursor = (cursor + 1) & 4095
    if len(out) != size or pos != len(data) or zlib.adler32(out) != checksum:
        raise ValueError("LZSS length/checksum mismatch")
    return bytes(out)

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
    if raw.startswith(b"complzss"):
        raw = unpack_lzss(raw)
    elif raw.startswith((b"bvx2", b"bvx1", b"bvx-", b"bvxn")):
        import lzfse
        raw = lzfse.decompress(raw)
    if not raw.startswith(b"\xcf\xfa\xed\xfe") or len(raw) > 256 * 1024 * 1024:
        raise ValueError(f"unsupported kernel payload: prefix={raw[:8].hex()} size={len(raw)}")
    return raw

# Only collect identifiers relevant to the PCIe driver, not arbitrary firmware strings.
PATTERN = re.compile(rb"[A-Za-z0-9_.$:]{0,40}AppleS800[03xX]PCIe[A-Za-z0-9_.$:]{0,100}")
def inventory(raw):
    return sorted({m.group().decode("ascii") for m in PATTERN.finditer(raw)})

# Resolve literal addresses from bounded Mach-O segment mappings. Candidate
# ADRP/ADD references are leads, not verified function entry points.
TARGETS = (
    b"AppleS8000PCIe::configure",
    b"AppleS8000PCIePort::enablePortHardware",
    b"AppleS800xPCIe::_readPhyIPReg",
    b"AppleS800xPCIe::_writePhyIPReg",
    b"AppleS8003PCIePort::enablePortHardware",
)
def macho_segments(raw):
    if len(raw) < 32:
        raise ValueError("short Mach-O")
    magic, cpu, _, _, ncmds, total, _, _ = struct.unpack_from("<8I", raw)
    if magic != 0xfeedfacf or cpu != 0x0100000c or ncmds > 4096 or total > len(raw)-32:
        raise ValueError("unsupported Mach-O header")
    pos = 32
    segments = []
    for _ in range(ncmds):
        if pos+8 > 32+total:
            raise ValueError("truncated load command")
        cmd, size = struct.unpack_from("<II", raw, pos)
        if size < 8 or pos+size > 32+total:
            raise ValueError("bad load command bounds")
        if cmd == 0x19:
            if size < 72:
                raise ValueError("short segment command")
            _, _, name, vm, vs, off, fs, maxprot, prot, _, _ = struct.unpack_from("<II16sQQQQiiII", raw, pos)
            if off+fs > len(raw) or fs > vs:
                raise ValueError("invalid segment bounds")
            if fs:
                segments.append((name.rstrip(b"\0").decode("ascii"), vm, off, fs, prot))
        pos += size
    return segments

def literal_refs(raw):
    segs = macho_segments(raw)
    targets = {}
    for label in TARGETS:
        start = 0
        while (off := raw.find(label, start)) >= 0:
            # Diagnostic format strings often contain the routine label rather
            # than terminating immediately after it. Include the printable
            # string start and label offset as distinct reference candidates.
            first = off
            while first > max(0, off-256) and 32 <= raw[first-1] < 127:
                first -= 1
            for name, vm, base, size, prot in segs:
                for candidate in {first, off}:
                    if base <= candidate < base+size:
                        address = vm+candidate-base
                        targets.setdefault(address, set()).add(label.decode())
            start = off+len(label)
    pages = {addr & ~4095 for addr in targets}
    hits = []
    for name, vm, off, size, prot in segs:
        if not (prot & 4 or name == "__PRELINK_TEXT"):
            continue
        data = memoryview(raw)[off:off+(size&~3)]
        for i, (word,) in enumerate(struct.iter_unpack("<I", data)):
            if word & 0x9f000000 != 0x90000000:
                continue
            pc = vm+i*4
            imm = ((word >> 29)&3) | (((word >> 5)&0x7ffff)<<2)
            if imm & (1<<20):
                imm -= 1<<21
            page = (pc & ~4095)+(imm<<12)
            if page not in pages:
                continue
            rd = word&31
            # Restrict to immediately adjacent ADD to avoid untracked clobbers.
            if (i+1)*4+4 > len(data):
                continue
            add, = struct.unpack_from("<I", data, (i+1)*4)
            if add & 0xffc00000 != 0x91000000 or (add>>5)&31 != rd:
                continue
            addr = page+((add>>10)&0xfff)
            if addr in targets:
                hits.append({"segment":name,"adrp_pc":hex(pc),"string_address":hex(addr),"labels":sorted(targets[addr])})
                if len(hits)>=256:
                    raise ValueError("reference inventory exceeds cap")
    return {"segments":[{"name":n,"vm":hex(v),"file_offset":hex(o),"size":s,"protection":p} for n,v,o,s,p in segs],
            "mapped_literals":[{"address":hex(a),"labels":sorted(v)} for a,v in sorted(targets.items())],
            "candidate_adjacent_adrp_add_refs":hits,
            "limitations":"Heuristic literal references only; no function boundaries or register writes inferred."}

def main():
    assert inventory(b"\0AppleS8000PCIe\0unrelated\0AppleS8003PCIePort\0") == ["AppleS8000PCIe", "AppleS8003PCIePort"]
    sample = b"ABCABC"
    stream = b"\x07ABC\xee\xf0"
    header = b"complzss" + struct.pack(">III", zlib.adler32(sample), len(sample), len(stream))
    assert unpack_lzss(header.ljust(0x180, b"\0") + stream) == sample
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
            if entry["sha256"] != "a4feb2d8f1d751d338508942d49543f3cd67560ad2b4400b3c752e61c2860e07":
                raise ValueError("kernelcache hash mismatch")
            try:
                raw = unpack_kernel(blob)
                entry["identifiers"] = inventory(raw)
                entry["status"] = "inspected"
                try:
                    entry["literal_reference_inventory"] = literal_refs(raw)
                except ValueError as exc:
                    entry["reference_error"] = str(exc)
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
