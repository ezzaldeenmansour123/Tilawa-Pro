#!/usr/bin/env python3
"""Builds the Tilawa Pro launcher icon from the mushaf source image.

Source: tools/icon-mushaf.png — an open mushaf (Quran) with gold ornament
on deep green (chosen by the user 2026-11-25: "صورة مصحف").
The script resizes it (Lanczos) into the Android mipmap densities.
Usage: python3 tools/make_icon.py android/app/src/main/res
"""
import sys
from pathlib import Path

from PIL import Image

SIZES = {
    'mipmap-mdpi': 48,
    'mipmap-hdpi': 72,
    'mipmap-xhdpi': 96,
    'mipmap-xxhdpi': 144,
    'mipmap-xxxhdpi': 192,
}

SOURCE = Path(__file__).resolve().parent / 'icon-mushaf.png'


def main():
    if len(sys.argv) < 2:
        print('usage: make_icon.py <res-dir>', file=sys.stderr)
        sys.exit(2)
    if not SOURCE.is_file():
        print(f'ERROR: launcher icon source is missing: {SOURCE}', file=sys.stderr)
        sys.exit(1)
    src = Image.open(SOURCE).convert('RGBA')
    w, h = src.size
    if w != h:
        side = min(w, h)
        src = src.crop(((w - side) // 2, (h - side) // 2,
                        (w + side) // 2, (h + side) // 2))
    res = Path(sys.argv[1])
    for name, size in SIZES.items():
        out = res / name
        out.mkdir(parents=True, exist_ok=True)
        src.resize((size, size), Image.LANCZOS).save(out / 'ic_launcher.png')
        print(f'{name}/ic_launcher.png {size}x{size}')


if __name__ == '__main__':
    main()
