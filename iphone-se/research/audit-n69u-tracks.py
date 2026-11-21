#!/usr/bin/env python3
"""Static board/driver compatibility audit, not a hardware functionality test."""
import json
import pathlib
import re
import subprocess
import sys

TRACKS = {
    "storage": (r"pcie|nvme|nand|ans[0-9]|iommu|dart", r"PCIE_APPLE|APPLE_DART|NVME"),
    "charging": (r"charg|battery|fuel.gauge|tristar|tigris|pmic|power.supply|usbdev", r"CHARGER|BATTERY|POWER_SUPPLY|PMIC|TRISTAR|FUEL_GAUGE"),
    "display-touch": (r"display|framebuffer|backlight|touchscreen|hidspi|mipi.dsi|panel|adbe", r"DRM_APPLE|DRM_SIMPLEDRM|FB_SIMPLE|BACKLIGHT|TOUCHSCREEN_APPLE|HID_SPI"),
    "audio-haptics": (r"audio|codec|sound|speaker|microphone|mca|haptic|vibrat|switch.mute", r"SND_SOC_APPLE|SND_SOC_CS|SND_SOC_WM|HAPTIC|VIBRAT|INPUT_FF"),
    "connectivity": (r"wifi|wlan|bluetooth|bcm43|usb|dwc2|modem|baseband", r"BRCMFMAC|BT_HCI|USB_DWC2|USB_CONFIGFS|WWAN|APPLE_T8010_WLAN"),
    "sensors-thermal": (r"camera|isp|thermal|temperature|accelerom|gyro|sensor|rtc|iio", r"THERMAL|APPLE_S8003_THERMAL|IIO|VIDEO_APPLE|RTC_DRV_APPLE"),
    "touch-id": (r"fingerprint|touch.id|biometric|secure.enclave|mesa|apple.sep", r"FINGERPRINT|BIOMETRIC|APPLE_SEP"),
}

def call(*args):
    return subprocess.check_output(["fdtget", *args], text=True).strip()

def audit(dtb, cfg, track):
    if "apple,n69u" not in call("-t", "s", dtb, "/", "compatible").split():
        raise ValueError("Expected the Samsung iPhone SE n69u device tree")
    device_pattern, config_pattern = (re.compile(p, re.I) for p in TRACKS[track])
    nodes = []
    def visit(path, inherited):
        props = call("-p", dtb, path).splitlines()
        status = call("-t", "s", dtb, path, "status") if "status" in props else "okay"
        enabled = inherited and status in ("okay", "ok")
        compatible = call("-t", "s", dtb, path, "compatible") if "compatible" in props else ""
        # Match just this node and its compatible strings, not its ancestors.
        if device_pattern.search(path.rsplit("/", 1)[-1] + " " + compatible):
            nodes.append({"node": path, "compatible": compatible, "status": status, "ancestors_and_node_enabled": enabled})
        for child in call("-l", dtb, path).splitlines():
            if child:
                visit(path.rstrip("/") + "/" + child, enabled)
    visit("/", True)
    options = {}
    for line in pathlib.Path(cfg).read_text().splitlines():
        found = re.fullmatch(r"(CONFIG_[A-Za-z0-9_]+)=(.*)", line)
        unset = re.fullmatch(r"# (CONFIG_[A-Za-z0-9_]+) is not set", line)
        if found and config_pattern.search(found[1]):
            options[found[1]] = found[2]
        elif unset and config_pattern.search(unset[1]):
            options[unset[1]] = "n"
    return {"track": track, "board": "n69u", "nodes": nodes, "configuration": options,
            "limitations": "Static matches only. A matching node or built-in/module configuration does not prove a working driver. Modules require packaging and runtime validation. No match is not proof the hardware is absent. No physical test, firmware change or charger control."}

if __name__ == "__main__":
    dtb, cfg, track, output = sys.argv[1:]
    result = audit(dtb, cfg, track)
    out = pathlib.Path(output)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(result, indent=2) + "\n")
    print(f"{track}: {len(result['nodes'])} candidate nodes, {len(result['configuration'])} relevant configuration options.")
    print(result["limitations"])
