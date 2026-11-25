#!/usr/bin/env python3
"""Draws the Tilawa launcher icon (PIL) into an Android res dir.

Same style as the hadith app's icon: flat geometric shapes, no photos.
Motif: an open book (two pages) in teal + a gold crescent above it,
on a warm cream background — matching the in-app LogoMark.
Usage: python3 tools/make_icon.py android/app/src/main/res
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw

SIZES = {
    'mipmap-mdpi': 48,
    'mipmap-hdpi': 72,
    'mipmap-xhdpi': 96,
    'mipmap-xxhdpi': 144,
    'mipmap-xxxhdpi': 192,
}

CREAM = (255, 251, 242, 255)
TEAL = (14, 124, 107, 255)
TEAL_LIGHT = (77, 179, 162, 255)
GOLD = (201, 162, 39, 255)


def draw_icon(size):
    img = Image.new('RGBA', (size, size), CREAM)
    d = ImageDraw.Draw(img)
    s = size / 100.0

    def poly(pts, fill):
        d.polygon([(x * s, y * s) for x, y in pts], fill=fill)

    # open book: left page (teal), right page (light teal)
    poly([(50, 78), (10, 66), (8, 34), (50, 46)], TEAL)
    poly([(50, 78), (90, 66), (92, 34), (50, 46)], TEAL_LIGHT)
    # crescent: gold disc minus an offset disc
    d.ellipse([38 * s, 6 * s, 62 * s, 30 * s], fill=GOLD)
    d.ellipse([44 * s, 4 * s, 68 * s, 28 * s], fill=CREAM)
    # thin gold line under the book
    d.rectangle([20 * s, 84 * s, 80 * s, 87 * s], fill=GOLD)
    return img


def main():
    if len(sys.argv) < 2:
        print('usage: make_icon.py <res-dir>', file=sys.stderr)
        sys.exit(2)
    res = Path(sys.argv[1])
    for name, size in SIZES.items():
        out = res / name
        out.mkdir(parents=True, exist_ok=True)
        draw_icon(size).save(out / 'ic_launcher.png')
        print(f'{name}/ic_launcher.png {size}x{size}')


if __name__ == '__main__':
    main()
