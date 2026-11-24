#!/usr/bin/env python3
"""Generate an inactive Samsung S8000 PCIe resource map from public ADT.
No register accesses, driver binding, or writes to a phone.
"""
import json
import pathlib
import struct
import sys

def cells(value):
    return "<" + " ".join(f"0x{x:x}" for x in (value >> 32, value & 0xffffffff)) + ">"

def regions(node):
    raw=bytes.fromhex(node["reg"])
    if not raw or len(raw)%16: raise ValueError("unexpected ADT register layout")
    return list(struct.iter_unpack("<QQ",raw))

def words(raw):
    return tuple(x[0] for x in struct.iter_unpack("<I", bytes.fromhex(raw)))

def reg_array(rs):
    return ",\n            ".join("<"+" ".join(f"0x{x:x}" for x in (a>>32,a&0xffffffff,s>>32,s&0xffffffff))+">" for a,s in rs)

def generate(report):
    prefix="/device-tree/arm-io/"
    n=report["boards"]["n69u"]
    t=report["boards"]["n69"]
    assert n[prefix+"apcie"]["compatible"]=="apcie,s8000"
    assert t[prefix+"apcie"]["compatible"]=="apcie,s8003"
    rs=regions(n[prefix+"apcie"])
    ts=regions(t[prefix+"apcie"])
    assert len(rs)==11 and len(ts)==12 and set(ts)-set(rs)=={(0x60a000000,0x40000)}
    assert set(rs)<=set(ts)
    named={
      "config":(0x610000000,0x1000000),
      "rc":(0x600000000,0x8000),
      "phy":(0x600008000,0x4000),
    }
    for i in range(4):named["port"+str(i)]=(0x601000000+i*0x1000000,0x4000)
    nvmmu=regions(n[prefix+"nvme-mmu0"])
    assert nvmmu==[(0x601004000,0x4000),(0x601000000,0x4000)]
    named["nvmmu"]=nvmmu[0]
    assert all(r in rs for r in named.values())
    assert words(n[prefix+"apcie"]["interrupts"])==(244,247,250,253)
    assert words(n[prefix+"nvme-mmu0"]["interrupts"])==(246,)
    assert words(n[prefix+"apcie/pci-bridge0"]["function-perst"])==(30,0x4750494f,160,0)
    assert words(n[prefix+"apcie/pci-bridge0"]["function-clkreq"])==(30,0x4750494f,164,2)
    d=n[prefix+"dart-apcie0"]
    assert d["compatible"]=="dart,s8000;dart,s5l8960x"
    assert regions(d)==[(0x601008000,0x4000)] and words(d["interrupts"])==(245,)
    assert words(d["fetch-config"])==(0xe0303,) and words(d["diag-config"])==(0x100,)
    # ADT has two identical 64-bit error-reflector entries.
    er=tuple(x[0] for x in struct.iter_unpack("<Q",bytes.fromhex(d["error-reflector"])))
    assert er==(0x20fffc000,0x20fffc000)
    assert words(d["vm-size"])==(0x3c000000,)
    # Wi-Fi on port 1: verified public ADT only. GPIO function tuples are
    # not Linux GPIO flags; preserve raw values rather than guessing polarity.
    bridge=n[prefix+"apcie/pci-bridge1"]
    wlan=n[prefix+"apcie/pci-bridge1/wlan"]
    assert wlan["compatible"]=="wlan-pcie,bcm4345;wlan-pcie,bcm"
    assert words(bridge["function-perst"])==(30,0x4750494f,161,0)
    assert words(bridge["function-clkreq"])==(30,0x4750494f,165,2)
    assert words(bridge["function-device_wake"])==(30,0x4750494f,73,257)
    wd=n[prefix+"dart-apcie1"]
    assert wd["compatible"]=="dart,s8000;dart,s5l8960x"
    assert regions(wd)==[(0x602008000,0x4000)] and words(wd["interrupts"])==(248,)
    assert words(wd["fetch-config"])==(0xe0303,) and words(wd["diag-config"])==(0x100,)
    assert tuple(x[0] for x in struct.iter_unpack("<Q",bytes.fromhex(wd["error-reflector"])))==er
    assert words(wd["vm-size"])==(0x3ffff000,)
    names=", ".join('"'+k+'"' for k in named)
    source=f"""// SPDX-License-Identifier: GPL-2.0+ OR MIT
/*
 * Samsung S8000 n69u resource description, NOT a working driver.
 * Generated from verified Apple public device-tree metadata (19H422).
 * No phy-ip region, no S8003 compatible fallback, no speculative power
 * or lane configuration. Keep all nodes disabled pending PHY research.
 */
&{{/soc}} {{
    iommu@601008000 {{
        compatible = "apple,s8000-dart", "apple,s5l8960x-dart";
        reg = {reg_array(regions(d))};
        #iommu-cells = <5>;
        interrupt-parent = <&aic>;
        interrupts = <AIC_IRQ 245 IRQ_TYPE_LEVEL_HIGH>;
        apple,error-reflector = /bits/ 64 <0x{er[0]:x}>;
        apple,fetch-config = <0xe0303>;
        apple,diag-config = <0x100>;
        status = "disabled";
    }};

    /* Port 1 Wi-Fi DMA translation resources only. No endpoint mapping yet. */
    iommu@602008000 {{
        compatible = "apple,s8000-dart", "apple,s5l8960x-dart";
        reg = {reg_array(regions(wd))};
        #iommu-cells = <5>;
        interrupt-parent = <&aic>;
        interrupts = <AIC_IRQ 248 IRQ_TYPE_LEVEL_HIGH>;
        apple,error-reflector = /bits/ 64 <0x{er[0]:x}>;
        apple,fetch-config = <0xe0303>;
        apple,diag-config = <0x100>;
        status = "disabled";
    }};

    /* ADT port 1: PERST GPIO 161, CLKREQ GPIO 165, DEVICE_WAKE GPIO 73.
     * No Linux polarity, pinmux, power or DMA stream mapping inferred.
     */
    pcie@610000000 {{
        compatible = "apple,s8000-pcie";
        device_type = "pci";
        reg = {reg_array(named.values())};
        reg-names = {names};
        #address-cells = <3>;
        #size-cells = <2>;
        #interrupt-cells = <1>;
        status = "disabled";
    }};
}};
"""
    return source

if __name__=="__main__":
    report=json.loads(pathlib.Path(sys.argv[1]).read_text())
    pathlib.Path(sys.argv[2]).write_text(generate(report))
    print("PASS Samsung-specific register map; S8003 PHY-IP region excluded; all nodes inactive.")
