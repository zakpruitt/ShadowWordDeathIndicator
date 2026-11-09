"""Converts tools/icon-source.jpg into Textures/Icon.tga, the icon in the AddOns list (needs Pillow).

The source has a grey frame baked into its edges; CROP trims it so only the art is left.

Usage: python tools/make_icon.py
"""
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SIZE = 128
CROP = 0.055  # fraction trimmed from each side


def main():
    image = Image.open(ROOT / "tools" / "icon-source.jpg").convert("RGBA")
    w, h = image.size
    dx, dy = round(w * CROP), round(h * CROP)
    image = image.crop((dx, dy, w - dx, h - dy)).resize((SIZE, SIZE), Image.LANCZOS)
    image.save(ROOT / "Textures" / "Icon.tga")


if __name__ == "__main__":
    main()
