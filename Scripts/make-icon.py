#!/usr/bin/env python3
"""Draws Zetesis' application icon: a black-figure Ζ on Attic clay, over a meander band, and the
splash screen's key art in the same manner: the word ΖΗΤΗΣΙΣ between two meander friezes.

Writes every size of Zetesis/Resources/Assets.xcassets/AppIcon.appiconset, the accent colour and
Zetesis/Resources/SplashArt.jpg.
Run from the repository root:  python3 Scripts/make-icon.py
"""
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "Zetesis" / "Resources" / "Assets.xcassets"
ICONSET = ASSETS / "AppIcon.appiconset"
SIZE = 1024
MARGIN = 100  # macOS icon grid: the tile is 824 px inside a 1024 canvas
RADIUS = 185
CLAY_TOP = (214, 120, 62)
CLAY_BOTTOM = (166, 72, 32)
GLAZE = (28, 20, 16)
FONT = "/System/Library/Fonts/Supplemental/Times New Roman Bold.ttf"  # has Greek glyphs; Didot has none
SPLASH = ROOT / "Zetesis" / "Resources" / "SplashArt.jpg"
SPLASH_SIZE = (1280, 440)  # the splash screen's 640 × 220 point banner, at 2×
SIZES = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]


def clay(size: int, width: int | None = None) -> Image.Image:
    column = Image.new("RGB", (1, size))
    for y in range(size):
        t = y / (size - 1)
        column.putpixel((0, y), tuple(round(a + (b - a) * t) for a, b in zip(CLAY_TOP, CLAY_BOTTOM)))
    return column.resize((width or size, size))


def meander(draw: ImageDraw.ImageDraw, left: int, top: int, width: int, unit: int) -> None:
    """A running Greek key, one square spiral per 4 units, drawn as thick strokes."""
    stroke = max(2, unit // 2)
    x = left
    while x + 4 * unit <= left + width:
        pts = [(x, top + 4 * unit), (x, top), (x + 3 * unit, top), (x + 3 * unit, top + 3 * unit),
               (x + unit, top + 3 * unit), (x + unit, top + unit), (x + 2 * unit, top + unit),
               (x + 2 * unit, top + 2 * unit)]
        draw.line(pts, fill=GLAZE, width=stroke, joint="curve")
        draw.line([(x, top + 4 * unit), (x + 4 * unit, top + 4 * unit)], fill=GLAZE, width=stroke)
        x += 4 * unit


def icon() -> Image.Image:
    tile = SIZE - 2 * MARGIN
    art = clay(tile).convert("RGBA")
    draw = ImageDraw.Draw(art)
    # Two thin glaze rules frame the band, like the lines on a vase's shoulder.
    band_top = round(tile * 0.70)
    unit = tile // 26
    draw.rectangle((0, band_top - unit, tile, band_top - unit + unit // 3), fill=GLAZE)
    meander(draw, (tile - 24 * unit) // 2, band_top + unit // 2, 24 * unit, unit)
    draw.rectangle((0, band_top + 5 * unit, tile, band_top + 5 * unit + unit // 3), fill=GLAZE)
    font = ImageFont.truetype(FONT, round(tile * 0.62))
    box = draw.textbbox((0, 0), "Ζ", font=font)
    x = (tile - (box[2] - box[0])) / 2 - box[0]
    y = (band_top - unit - (box[3] - box[1])) / 2 - box[1] + tile * 0.01
    draw.text((x, y), "Ζ", font=font, fill=GLAZE)

    mask = Image.new("L", (tile, tile), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, tile - 1, tile - 1), RADIUS, fill=255)
    canvas = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    shadow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 90), (MARGIN, MARGIN + 12), mask)
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(14)))
    canvas.paste(art, (MARGIN, MARGIN), mask)
    return canvas


def frieze(draw: ImageDraw.ImageDraw, top: int, width: int, unit: int) -> None:
    """A meander between two thin rules, across the whole width."""
    rule = max(2, unit // 3)
    draw.rectangle((0, top, width, top + rule), fill=GLAZE)
    spirals = width // (4 * unit) + 1
    meander(draw, (width - spirals * 4 * unit) // 2, top + unit + rule, spirals * 4 * unit, unit)
    draw.rectangle((0, top + 6 * unit + rule, width, top + 6 * unit + 2 * rule), fill=GLAZE)


def splash() -> Image.Image:
    """The banner behind the splash screen's title: the app's name painted like a vase inscription.
    The bottom third is left plain, since the title, tagline and version are set over it."""
    width, height = SPLASH_SIZE
    art = clay(height, width)
    draw = ImageDraw.Draw(art)
    unit = 14
    frieze(draw, 22, width, unit)
    font = ImageFont.truetype(FONT, 150)
    word = "ΖΗΤΗΣΙΣ"
    box = draw.textbbox((0, 0), word, font=font)
    draw.text((width - (box[2] - box[0]) - 70 - box[0], 150 - box[1]), word, font=font, fill=GLAZE)
    return art


def main() -> None:
    splash().save(SPLASH, quality=90)
    ICONSET.mkdir(parents=True, exist_ok=True)
    master = icon()
    images = []
    for points, scale in SIZES:
        name = f"icon_{points}x{points}{'@2x' if scale == 2 else ''}.png"
        master.resize((points * scale, points * scale), Image.LANCZOS).save(ICONSET / name)
        images.append({"idiom": "mac", "size": f"{points}x{points}", "scale": f"{scale}x", "filename": name})
    info = {"author": "xcode", "version": 1}
    (ICONSET / "Contents.json").write_text(json.dumps({"images": images, "info": info}, indent=2))
    (ASSETS / "Contents.json").write_text(json.dumps({"info": info}, indent=2))
    accent = ASSETS / "AccentColor.colorset"
    accent.mkdir(exist_ok=True)
    rgb = {k: f"{v / 255:.3f}" for k, v in zip(("red", "green", "blue"), CLAY_BOTTOM)}
    (accent / "Contents.json").write_text(json.dumps(
        {"colors": [{"idiom": "universal", "color": {"color-space": "srgb", "components": {**rgb, "alpha": "1.000"}}}],
         "info": info}, indent=2))
    master.save(ROOT / "documents" / "icon.png")


if __name__ == "__main__":
    main()
