"""Generates Shadow Word: Death Indicator's glow textures (white, shape in alpha) as 64x64 uncompressed 32-bit TGAs.

Glow.tga  - 9-slice soft glow: corners are 24x24 texels, the middle 16 texels stretch. The bars' edge sits 16
            texels in from the outside: 16 texels of glow outside it, a faint 8-texel rim inside.
Halo.tga  - round soft halo: the portrait's edge is at radius 24 of 32.

Usage: python tools/make_textures.py Textures
"""
import math
import struct
import sys
from pathlib import Path

SIZE = 64


def write_tga(path, alpha_at):
    pixels = bytearray()
    for y in range(SIZE):
        for x in range(SIZE):
            a = max(0.0, min(1.0, alpha_at(x + 0.5, y + 0.5)))
            pixels += bytes((255, 255, 255, round(a * 255)))  # BGRA
    # id len, no colormap, type 2 (truecolor), colormap spec, origin, size, 32 bpp, 8 alpha bits + top-left origin
    header = struct.pack("<BBB5sHHHHBB", 0, 0, 2, b"\0" * 5, 0, 0, SIZE, SIZE, 32, 0x28)
    path.write_bytes(header + bytes(pixels))


def glow_alpha(d, outer_sigma, inner_sigma, inner_peak):
    """d = signed distance from the edge (positive outside)."""
    if d >= 0:
        return math.exp(-(d * d) / (2 * outer_sigma ** 2))
    return inner_peak * math.exp(-(d * d) / (2 * inner_sigma ** 2))


def rounded_rect_distance(x, y, lo, hi, radius):
    # Signed distance to the rounded rectangle [lo, hi]^2 with the given corner radius.
    cx = cy = (lo + hi) / 2
    half = (hi - lo) / 2 - radius
    qx, qy = abs(x - cx) - half, abs(y - cy) - half
    outside = math.hypot(max(qx, 0), max(qy, 0))
    inside = min(max(qx, qy), 0)
    return outside + inside - radius


def main(out_dir):
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    write_tga(out / "Glow.tga", lambda x, y: glow_alpha(rounded_rect_distance(x, y, 16, 48, 3), 5.0, 2.5, 0.6))
    write_tga(out / "Halo.tga", lambda x, y: glow_alpha(math.hypot(x - 32, y - 32) - 24, 2.8, 1.8, 0.6))


if __name__ == "__main__":
    main(sys.argv[1])
