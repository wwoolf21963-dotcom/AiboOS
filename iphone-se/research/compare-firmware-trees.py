"""Offline hardware description research, no device access or firmware writes."""
import hashlib
import io
import json
import pathlib
import re
import struct
import sys
import urllib.request
import zipfile

URL = "https://updates.cdn-apple.com/2025FallFCS/fullrestores/122-77321/C113B49D-5014-4DEA-9C43-9AA3D772355B/iPhone_4.0_64bit_15.8.8_19H422_Restore.ipsw"
SIZE = 5229896987
BOARDS = {
    "n69": ("n69ap", "6b0720782015ca0539e3434ca051a7552ec5719baaa6b2d6ca1e12c96360a18d"),
    "n69u": ("n69uap", "496977992f1380c1c564125d212e138114442fb5cc18c836c8fb5108a1f9b05f"),
}

class RangeFile(io.RawIOBase):
    def __init__(self):
        self.pos = 0
        self.received = 0
    def seekable(self): return True
    def readable(self): return True
    def tell(self): return self.pos
    def seek(self, n, whence=0):
        pos = n if whence == 0 else self.pos+n if whence == 1 else SIZE+n
        if not 0 <= pos <= SIZE: raise ValueError("bad firmware offset")
        self.pos = pos
        return pos
    def read(self, n=-1):
        n = SIZE-self.pos if n<0 else min(n,SIZE-self.pos)
        if not n: return b""
        if n>8*1024*1024 or self.received+n>32*1024*1024: raise ValueError("range budget exceeded")
        end=self.pos+n-1
        q=urllib.request.Request(URL,headers={"Range":f"bytes={self.pos}-{end}","Accept-Encoding":"identity"})
        with urllib.request.urlopen(q,timeout=60) as r:
            if r.status!=206 or r.headers.get("Content-Range")!=f"bytes {self.pos}-{end}/{SIZE}":
                raise ValueError("server did not honor exact byte range")
            data=r.read(n+1)
        if len(data)!=n: raise ValueError("short range")
        self.pos+=n
        self.received+=n
        return data

def tlv(data,p):
    if p+2>len(data): raise ValueError("truncated DER")
    tag,n=data[p:p+2];p+=2
    if n&128:
        count=n&127
        if not 1<=count<=4 or p+count>len(data): raise ValueError("invalid DER length")
        n=int.from_bytes(data[p:p+count],"big");p+=count
    if p+n>len(data): raise ValueError("DER length outside input")
    return tag,data[p:p+n],p+n

def unwrap(blob):
    tag,seq,end=tlv(blob,0)
    if tag!=0x30 or end!=len(blob): raise ValueError("expected IM4P sequence")
    p=0
    for want in (b"IM4P",b"dtre"):
        tag,v,p=tlv(seq,p)
        if tag!=0x16 or v!=want: raise ValueError("not a device-tree IM4P")
    tag,_,p=tlv(seq,p)
    if tag!=0x16: raise ValueError("missing description")
    tag,raw,p=tlv(seq,p)
    if tag!=4: raise ValueError("missing device-tree data")
    if raw.startswith((b"bvx2",b"bvx1",b"bvx-",b"bvxn")):
        import lzfse
        raw=lzfse.decompress(raw)
    return raw

def parse(raw):
    if not 8<=len(raw)<=16*1024*1024: raise ValueError("tree size")
    pos=0; budget=50000
    results={}
    # Only standard controller descriptions from public restore images.
    wanted=re.compile(r"(^|[-_])(apcie|pcie|pci|nvme|nvmmu|ans|nand|dart|sart|storage|wlan|wifi|wireless|bcm4345|hans)([-_,0-9]|$)",re.I)
    allowed={"compatible","reg","interrupts","interrupt-parent","status","device_type","#address-cells","#size-cells","ranges","vm-offset","vm-size","function-perst","function-clkreq","function-device_wake","error-reflector","fetch-config","diag-config","clock-gates","lane-config","num-lanes","link-speed","apcie-phy-tunables","apcie-common-tunables","apcie-config-tunables","pcie-rc-tunables","apcie-port-tunables","phy-tunables","pcie-phy-tunables"}
    def visit(parent,depth):
        nonlocal pos,budget
        budget-=1
        if budget<0 or depth>64 or pos+8>len(raw): raise ValueError("node bounds")
        np,nc=struct.unpack_from("<II",raw,pos);pos+=8
        if np>4096 or nc>4096: raise ValueError("node counts")
        props={}
        for _ in range(np):
            if pos+36>len(raw): raise ValueError("property header")
            name=raw[pos:pos+32].split(b"\0",1)[0].decode("ascii")
            n=struct.unpack_from("<I",raw,pos+32)[0]&0xffffff;pos+=36
            aligned=(n+3)&~3
            if pos+aligned>len(raw): raise ValueError("property bounds")
            if name in allowed or name=="name": props[name]=raw[pos:pos+n]
            pos+=aligned
        name=props.get("name",b"").split(b"\0",1)[0].decode("ascii",errors="replace")
        if not name or "/" in name: raise ValueError("invalid node name")
        path=parent+"/"+name
        if wanted.search(name.split("@")[0]) or any(wanted.search(x.split("@")[0]) for x in path.split("/") if x and x.startswith(("wlan", "wifi"))):
            results[path]={k:(v.rstrip(b"\0").decode("ascii",errors="replace").replace("\0",";") if k in {"compatible","status","device_type"} else v.hex()) for k,v in props.items() if k in allowed and len(v)<=4096}
        for _ in range(nc): visit(path,depth+1)
    visit("",0)
    if pos>len(raw) or any(raw[pos:]): raise ValueError("unparsed trailing data")
    return results

def selftest():
    def prop(name,v): return name.encode().ljust(32,b"\0")+struct.pack("<I",len(v))+v+b"\0"*((-len(v))%4)
    child=struct.pack("<II",3,0)+prop("name",b"pcie0\0")+prop("reg",b"\x01\x02\x03\x04")+prop("unique-chip-id",b"SECRET")
    raw=struct.pack("<II",1,1)+prop("name",b"device-tree\0")+child
    result=parse(raw)
    assert result=={"/device-tree/pcie0":{"reg":"01020304"}}
    wifi=struct.pack("<II",4,0)+prop("name",b"wlan-pcie,bcm4345\0")+prop("compatible",b"wlan-pcie,bcm4345\0")+prop("function-device_wake",b"\x01\x00\x00\x00")+prop("mac-address",b"SECRET")
    bridge=struct.pack("<II",1,1)+prop("name",b"pci-bridge1\0")+wifi
    raw_wifi=struct.pack("<II",1,1)+prop("name",b"device-tree\0")+bridge
    assert parse(raw_wifi)["/device-tree/pci-bridge1/wlan-pcie,bcm4345"]=={"compatible":"wlan-pcie,bcm4345","function-device_wake":"01000000"}
    # Preserve opaque tunable bytes; do not infer record format or apply writes.
    phy=struct.pack("<II",3,0)+prop("name",b"apcie\0")+prop("apcie-phy-tunables",bytes(range(12)))+prop("serial-number",b"SECRET")
    phy_tree=struct.pack("<II",1,1)+prop("name",b"device-tree\0")+phy
    assert parse(phy_tree)=={"/device-tree/apcie":{"apcie-phy-tunables":bytes(range(12)).hex()}}
    for broken in [raw[:-1],b""]:
        try:parse(broken)
        except ValueError:pass
        else:raise AssertionError("truncated tree accepted")
    print("PASS parser bounds and property allowlist")

def main():
    selftest()
    if "--selftest" in sys.argv:return
    out=pathlib.Path("a9-firmware-hardware-report");out.mkdir(exist_ok=True)
    reports={}
    with RangeFile() as remote,zipfile.ZipFile(remote) as archive:
        for board,(name,digest) in BOARDS.items():
            path=f"Firmware/all_flash/DeviceTree.{name}.im4p"
            item=archive.getinfo(path)
            if item.file_size>4*1024*1024:raise ValueError("device tree size")
            blob=archive.read(item)
            if hashlib.sha256(blob).hexdigest()!=digest:raise ValueError("firmware hash mismatch")
            reports[board]=parse(unwrap(blob))
            if not reports[board]:raise ValueError("no controller descriptions")
            print(board,len(reports[board]),"matching controller nodes")
        print("Downloaded",remote.received,"bytes from public restore archive.")
    a,b=reports["n69"],reports["n69u"]
    report={"source":"Apple iPhone8,4 iOS 15.8.8 (19H422), public restore hardware descriptions","firmware_hashes":{k:v[1] for k,v in BOARDS.items()},"boards":reports,"only_n69":sorted(a.keys()-b.keys()),"only_n69u":sorted(b.keys()-a.keys()),"different_common_nodes":sorted(k for k in a.keys()&b.keys() if a[k]!=b[k]),"limitations":"Static firmware metadata. Not a working driver, not live device data, no controller writes or boot modifications. Register values are raw bytes, not translated Linux device-tree cells."}
    (out/"controller-comparison.json").write_text(json.dumps(report,indent=2)+"\n")
    print("PASS pinned public hardware metadata comparison")
    for board, nodes in reports.items():
        for path, props in nodes.items():
            if any(term in path.lower() for term in ("apcie", "nvme-mmu", "wlan", "wifi", "bcm4345", "hans")):
                print(board, path, json.dumps(props, sort_keys=True))
if __name__=="__main__":main()
