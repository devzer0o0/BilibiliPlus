#!/usr/bin/env python3
"""Classify a PiliPlus player frame as black / green / ok without PIL.

The simulator cannot exercise VideoToolbox, but it shares the 8-bit BGRA
destination with the hardware path, so a 10-bit frame reaching the texture
unconverted shows up as green (or black) here too.
"""
import struct
import subprocess
import sys
import zlib

def average_rgb(png_path, tmp_prefix="/tmp/_framechk"):
    crop = f"{tmp_prefix}_crop.png"
    tiny = f"{tmp_prefix}_tiny.png"
    subprocess.run(
        ["sips", "-c", "560", "1260", "--cropOffset", "210", "0", png_path, "--out", crop],
        capture_output=True,
    )
    subprocess.run(
        ["sips", "-z", "1", "1", "-s", "format", "png", crop, "--out", tiny],
        capture_output=True,
    )
    with open(tiny, "rb") as fh:
        data = fh.read()
    pos, idat, ctype = 8, b"", 6
    while pos < len(data):
        length = struct.unpack(">I", data[pos:pos + 4])[0]
        kind = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            ctype = body[9]
        elif kind == b"IDAT":
            idat += body
        pos += 12 + length
    raw = zlib.decompress(idat)
    return tuple(raw[1:4])

def classify(rgb):
    if sum(rgb) < 60:
        return "black"
    if rgb[1] > rgb[0] + 20 and rgb[1] > rgb[2] + 20:
        return "green"
    return "ok"

if __name__ == "__main__":
    for path in sys.argv[1:]:
        rgb = average_rgb(path)
        print(f"{path}: RGB={rgb} -> {classify(rgb)}")
