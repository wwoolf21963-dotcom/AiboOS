#!/usr/bin/env python3
"""Inventory S8000 PCIe routine identifiers in public restore firmware.
No execution of firmware, device access, register writes, or binary redistribution.
"""
import hashlib
import importlib.util
import json
import pathlib
import plistlib
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

def pcie_prelink_inventory(raw, segs):
    # Use actual prelink metadata to constrain later function discovery.
    info = next((s for s in segs if s[0] == "__PRELINK_INFO"), None)
    if not info:
        return {"status":"no prelink info segment"}
    _, _, off, size, _ = info
    if size > 8 * 1024 * 1024:
        raise ValueError("prelink metadata exceeds cap")
    data = raw[off:off+size]
    # Kernel prelink metadata may be a bare IOKit XML dictionary rather
    # than a complete plist document with XML declaration.
    payload = data.strip(b"\0 \r\n\t")
    begin = payload.find(b"<?xml")
    if begin < 0:
        begin = payload.find(b"<plist")
    if begin >= 0:
        end = payload.rfind(b"</plist>")
        if end < begin:
            return {"status":"incomplete plist envelope"}
        payload = payload[begin:end+len(b"</plist>")]
    elif payload.startswith(b"<dict") or payload.startswith(b"<array"):
        close = b"</dict>" if payload.startswith(b"<dict") else b"</array>"
        end = payload.rfind(close)
        if end < 0:
            return {"status":"incomplete bare prelink XML"}
        payload = b'<plist version="1.0">' + payload[:end+len(close)] + b"</plist>"
    elif not payload.startswith(b"bplist00"):
        return {"status":"prelink format not recognized", "prefix_hex":payload[:32].hex(), "size":len(payload)}
    try:
        root = plistlib.loads(payload)
    except (ValueError, TypeError, OverflowError, plistlib.InvalidFileException) as exc:
        return {"status":f"prelink parse failed: {type(exc).__name__}"}
    if not isinstance(root, dict):
        return {"status":"unexpected prelink root"}
    rows = root.get("_PrelinkInfoDictionary", [])
    if not isinstance(rows, list) or len(rows)>4096:
        return {"status":"unexpected prelink entries"}
    wanted = {"com.apple.driver.AppleS8000PCIe", "com.apple.driver.AppleS8003PCIe", "com.apple.driver.AppleS800xPCIe"}
    results = []
    for row in rows:
        if not isinstance(row, dict) or row.get("CFBundleIdentifier") not in wanted:
            continue
        result = {"bundle":row["CFBundleIdentifier"]}
        for k in ("_PrelinkExecutableLoadAddr", "_PrelinkExecutableSourceAddr", "_PrelinkExecutableSize", "_PrelinkKmodInfo"):
            v = row.get(k)
            if isinstance(v, int):
                result[k] = hex(v)
            elif isinstance(v, str) and re.fullmatch(r"(?:0x[0-9a-fA-F]+|[0-9]+)", v):
                result[k] = v
        results.append(result)
    return {"status":"parsed", "bundles":results,
            "limitations":"Module metadata only; no function boundaries or register semantics inferred."}

def inspect_reference_windows(raw, segs, hits):
    """Summarize nearby ARM64 control flow and memory accesses.
    These are bounded windows, not verified functions or MMIO operations.
    """
    from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
    from capstone.arm64 import ARM64_OP_IMM, ARM64_OP_MEM
    md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
    md.detail = True
    md.skipdata = False
    reports = []
    for hit in hits[:16]:
        pc = int(hit["adrp_pc"], 16)
        seg = next((s for s in segs if s[4] & 4 and s[1] <= pc < s[1]+s[3]), None)
        if seg is None:
            continue
        name, vm, off, size, _ = seg
        lo = max(vm, pc-512)
        hi = min(vm+size, pc+128)
        operations = []
        for ins in md.disasm(raw[off+lo-vm:off+hi-vm], lo):
            m = ins.mnemonic
            if m in ("bl", "b", "blr", "ret") or m.startswith(("b.", "cb", "tb")):
                operations.append({"pc":hex(ins.address),"kind":"control","mnemonic":m,"operands":ins.op_str})
            elif m.startswith(("ldr","ldp","str","stp","ldur","stur")):
                for operand in ins.operands:
                    if operand.type == ARM64_OP_MEM:
                        operations.append({"pc":hex(ins.address),"kind":"memory","mnemonic":m,"operands":ins.op_str})
                        break
        reports.append({"reference":hit,"window_start":hex(lo),"window_end":hex(hi),
                        "operations":operations,
                        "limitations":"Nearby instructions only. Register bases, function boundaries, execution paths and MMIO meaning not established."})
    return reports

def trace_diagnostic_callers(raw, segs, hits):
    # Candidate cold diagnostic stub starts, inferred from the previous
    # pinned-cache instruction report. Check the prologue before use.
    starts = {
        0xfffffff005feed40: "shared PHY read",
        0xfffffff005feed80: "shared PHY write",
        0xfffffff005ff0968: "Samsung port enable",
        0xfffffff005ff09a8: "Samsung configure A",
        0xfffffff005ff09e8: "Samsung configure B",
        0xfffffff0068ccef4: "TSMC port enable comparison",
    }
    from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
    md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
    valid = {}
    for addr, label in starts.items():
        seg = next((s for s in segs if s[4]&4 and s[1]<=addr<s[1]+s[3]-4), None)
        if not seg:
            continue
        _, vm, off, _, _ = seg
        ins = next(md.disasm(raw[off+addr-vm:off+addr-vm+4], addr), None)
        if ins and ins.mnemonic == "sub" and ins.op_str.startswith("sp, sp,"):
            valid[addr] = label
    callers = []
    for name, vm, off, size, prot in segs:
        if not prot&4:
            continue
        data = memoryview(raw)[off:off+(size&~3)]
        for i, (word,) in enumerate(struct.iter_unpack("<I", data)):
            if word&0x7c000000 != 0x14000000:
                continue
            imm = word&0x3ffffff
            if imm&0x2000000:
                imm -= 0x4000000
            pc = vm+i*4
            target = pc+imm*4
            if target not in valid:
                continue
            lo = max(vm, pc-384)
            hi = min(vm+size, pc+64)
            window = [{"pc":hex(x.address),"mnemonic":x.mnemonic,"operands":x.op_str}
                      for x in md.disasm(raw[off+lo-vm:off+hi-vm], lo)]
            callers.append({"callsite":hex(pc),"target":hex(target),"label":valid[target],
                            "window":window})
            if len(callers)>=48:
                raise ValueError("diagnostic caller count exceeds cap")
    return {"checked_stubs":[{"address":hex(a),"label":l,"prologue_match":a in valid} for a,l in starts.items()],
            "candidate_callers":callers,
            "limitations":"Direct B/BL references to candidate diagnostic stubs; not proof of function boundaries or hardware register meanings."}

def resolve_shared_dispatch(raw, segs):
    """Follow observed superclass dispatch slots from the pinned cache.
    Accept only unambiguous mapped pointers; do not guess pointer encodings.
    """
    from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
    md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
    slots = (
        ("Samsung port enable", 0xfffffff006e40dc8, 0x728),
        ("TSMC port enable", 0xfffffff006f73bc8, 0x728),
        ("Samsung configure", 0xfffffff006e40dc0, 0x5e8),
    )
    def locate(addr, count, executable=False):
        matches = [off+addr-vm for _,vm,off,size,prot in segs
                   if vm <= addr and addr+count <= vm+size and (not executable or prot&4)]
        return matches[0] if len(matches)==1 else None
    def pointer(addr):
        off = locate(addr, 8)
        return struct.unpack_from("<Q",raw,off)[0] if off is not None else None
    rows = []
    for label, slot, delta in slots:
        row = {"label":label,"global_slot":hex(slot),"dispatch_offset":hex(delta)}
        base = pointer(slot)
        row["raw_table_pointer"] = hex(base) if base is not None else None
        if base is None or locate(base+delta, 8) is None:
            row["status"] = "unresolved table pointer"
            rows.append(row)
            continue
        dest = pointer(base+delta)
        row["raw_function_pointer"] = hex(dest) if dest is not None else None
        off = locate(dest, 4, True) if dest is not None else None
        if off is None:
            row["status"] = "unresolved function pointer"
        else:
            row["status"] = "mapped executable candidate"
            # Stop at 128 instructions, not an asserted function boundary.
            instructions = []
            for i in range(128):
                address = dest+4*i
                fileoff = locate(address,4,True)
                if fileoff is None:
                    break
                ins = next(md.disasm(raw[fileoff:fileoff+4],address),None)
                if ins is None:
                    break
                instructions.append({"pc":hex(address),"mnemonic":ins.mnemonic,"operands":ins.op_str})
                if ins.mnemonic == "ret":
                    break
            row["candidate_instructions"] = instructions
        rows.append(row)
    return {"dispatch":rows,"limitations":"Static pointer reads; no relocations assumed, no function or hardware semantics inferred."}

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
    return {"pcie_prelink":pcie_prelink_inventory(raw, segs),
            "segments":[{"name":n,"vm":hex(v),"file_offset":hex(o),"size":s,"protection":p} for n,v,o,s,p in segs],
            "mapped_literals":[{"address":hex(a),"labels":sorted(v)} for a,v in sorted(targets.items())],
            "candidate_adjacent_adrp_add_refs":hits,
            "candidate_code_windows":inspect_reference_windows(raw, segs, hits),
            "diagnostic_caller_trace":trace_diagnostic_callers(raw, segs, hits),
            "shared_dispatch":resolve_shared_dispatch(raw, segs),
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
