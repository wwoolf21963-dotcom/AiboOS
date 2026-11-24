#!/usr/bin/env python3
"""Build-time SVG rendering. Native ARM64 runtime has no web engine."""
import io
import json
import pathlib
import sys
import cairosvg
from PIL import Image

src, dst = map(pathlib.Path, sys.argv[1:])
layout = json.loads((src / "layout.json").read_text())
assert layout["version"] == "1.8"
ids = layout["home"] + layout["dock"]
assert len(ids) == 18 and len(set(ids)) == 18
size = 60
with dst.open("w") as f:
    f.write("/* Generated from original AiboOS 1.8 artwork. */\n")
    f.write("#define AIBO18_COUNT 18\n#define AIBO18_HOME_COUNT 14\n#define AIBO18_ICON_SIZE 60\n")
    names = {a["id"]: a["name"] for a in layout["apps"]}
    f.write("static const char *const aibo18_names[] = {")
    f.write(",".join(json.dumps(names[i]) for i in ids) + "};\n")
    f.write("static const uint32_t aibo18_pixels[18][3600] = {\n")
    for id in ids:
        svg = (src / (id + ".svg")).read_bytes()
        png = cairosvg.svg2png(bytestring=svg, output_width=size, output_height=size)
        im = Image.open(io.BytesIO(png)).convert("RGBA")
        pixels = [((a << 24) | (r << 16) | (g << 8) | b) for r,g,b,a in im.getdata()]
        assert any(p >> 24 for p in pixels)
        f.write("{" + ",".join(hex(p) for p in pixels) + "},\n")
    f.write("};\n")
print("PASS original 1.8 icon rasterization")
