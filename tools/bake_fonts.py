#!/usr/bin/env python3
"""Pre-rasterize TrueType fonts into Tome's .tfnt glyph packs.

Kindle firmware does not reliably ship a FreeType we can link against from a
static binary, so Tome renders text from anti-aliased bitmaps baked here.

File format (whole file zlib-compressed):
  "TFNT" | u16 px_size | i16 ascent | i16 descent | u16 line_height | u32 nglyphs
  nglyphs x { u32 codepoint | i32 advance_26_6 | i16 left | i16 top | u16 w | u16 h | u32 offset }
  bitmap bytes (8-bit coverage, row-major)
"""
import os
import struct
import sys
import zlib

from PIL import Image, ImageDraw, ImageFont

CROSEXTRA = "/usr/share/fonts/truetype/crosextra"
TYPE1 = "/usr/share/fonts/X11/Type1"
SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "fonts-src")

# face-style -> font file, or (variable font file, {axis name: value})
FACES = {
    # Caladea: the default serif
    "serif-regular": f"{CROSEXTRA}/Caladea-Regular.ttf",
    "serif-italic": f"{CROSEXTRA}/Caladea-Italic.ttf",
    "serif-bold": f"{CROSEXTRA}/Caladea-Bold.ttf",
    "serif-bolditalic": f"{CROSEXTRA}/Caladea-BoldItalic.ttf",
    # Bitstream Charter: classic book face
    "charter-regular": f"{TYPE1}/c0648bt_.pfb",
    "charter-italic": f"{TYPE1}/c0649bt_.pfb",
    "charter-bold": f"{TYPE1}/c0632bt_.pfb",
    "charter-bolditalic": f"{TYPE1}/c0633bt_.pfb",
    # Literata: designed for e-readers (Google Play Books)
    "literata-regular": (f"{SRC}/Literata[opsz,wght].ttf", {"Weight": 400, "Optical size": 20}),
    "literata-italic": (f"{SRC}/Literata-Italic[opsz,wght].ttf", {"Weight": 400, "Optical size": 20}),
    "literata-bold": (f"{SRC}/Literata[opsz,wght].ttf", {"Weight": 700, "Optical size": 20}),
    "literata-bolditalic": (f"{SRC}/Literata-Italic[opsz,wght].ttf", {"Weight": 700, "Optical size": 20}),
    # Merriweather: sturdy, dark serif that suits e-ink
    "merriweather-regular": (f"{SRC}/Merriweather[opsz,wdth,wght].ttf", {"Weight": 400, "Width": 100, "Optical size": 18}),
    "merriweather-italic": (f"{SRC}/Merriweather-Italic[opsz,wdth,wght].ttf", {"Weight": 400, "Width": 100, "Optical size": 18}),
    "merriweather-bold": (f"{SRC}/Merriweather[opsz,wdth,wght].ttf", {"Weight": 750, "Width": 100, "Optical size": 18}),
    "merriweather-bolditalic": (f"{SRC}/Merriweather-Italic[opsz,wdth,wght].ttf", {"Weight": 750, "Width": 100, "Optical size": 18}),
    # Bitter: slab serif made for screens, bold-looking
    "bitter-regular": (f"{SRC}/Bitter[wght].ttf", {"Weight": 450}),
    "bitter-italic": (f"{SRC}/Bitter-Italic[wght].ttf", {"Weight": 450}),
    "bitter-bold": (f"{SRC}/Bitter[wght].ttf", {"Weight": 700}),
    "bitter-bolditalic": (f"{SRC}/Bitter-Italic[wght].ttf", {"Weight": 700}),
    # Atkinson Hyperlegible: very clear sans for low vision
    "atkinson-regular": f"{SRC}/AtkinsonHyperlegible-Regular.ttf",
    "atkinson-italic": f"{SRC}/AtkinsonHyperlegible-Italic.ttf",
    "atkinson-bold": f"{SRC}/AtkinsonHyperlegible-Bold.ttf",
    "atkinson-bolditalic": f"{SRC}/AtkinsonHyperlegible-BoldItalic.ttf",
    # Carlito: sans for reading and the UI
    "sans-regular": f"{CROSEXTRA}/Carlito-Regular.ttf",
    "sans-italic": f"{CROSEXTRA}/Carlito-Italic.ttf",
    "sans-bold": f"{CROSEXTRA}/Carlito-Bold.ttf",
    "sans-bolditalic": f"{CROSEXTRA}/Carlito-BoldItalic.ttf",
}
SERIF_SIZES = [22, 26, 30, 34, 40, 46, 54]
SANS_SIZES = [20, 22, 24, 26, 28, 30, 34, 40, 46, 48, 54]

RANGES = [(0x20, 0x7E), (0xA0, 0xFF), (0x100, 0x17F), (0x2010, 0x2027), (0x2030, 0x203A),
          (0x20AC, 0x20AC), (0x2122, 0x2122), (0x2190, 0x2193), (0x25B2, 0x25C0), (0x2713, 0x2713),
          (0xFFFD, 0xFFFD)]


FALLBACK = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"


def has_glyph(font, ch):
    """True if the font has a real glyph (not .notdef) for ch."""
    try:
        mask = font.getmask(ch)
    except Exception:
        return False
    notdef = font.getmask("\ue000")
    if mask.size == notdef.size and bytes(mask) == bytes(notdef):
        return ch.isspace()
    return mask.getbbox() is not None or ch.isspace() or ch in "\u00a0\u00ad"


def load_face(spec, size):
    if isinstance(spec, tuple):
        path, axes = spec
        font = ImageFont.truetype(path, size)
        values = []
        for axis in font.get_variation_axes():
            name = axis["name"].decode() if isinstance(axis["name"], bytes) else axis["name"]
            values.append(axes.get(name, axis["default"]))
        font.set_variation_by_axes(values)
        return font
    return ImageFont.truetype(spec, size)


def bake(spec, size, out_path):
    primary = load_face(spec, size)
    fallback = ImageFont.truetype(FALLBACK, size)
    ascent, descent = primary.getmetrics()
    glyphs = []
    blob = bytearray()
    for lo, hi in RANGES:
        for cp in range(lo, hi + 1):
            ch = chr(cp)
            # Code points the face lacks would render as .notdef boxes:
            # take them from DejaVu Sans, or skip them.
            if has_glyph(primary, ch):
                font = primary
            elif has_glyph(fallback, ch):
                font = fallback
            else:
                continue
            adv = font.getlength(ch)
            bbox = font.getbbox(ch, anchor="ls")
            l, t, r, b = bbox
            w, h = max(0, r - l), max(0, b - t)
            off = len(blob)
            if w > 0 and h > 0:
                img = Image.new("L", (w, h), 0)
                ImageDraw.Draw(img).text((-l, -t), ch, font=font, fill=255, anchor="ls")
                blob += img.tobytes()
            glyphs.append((cp, int(round(adv * 64)), l, -t, w, h, off))
    header = b"TFNT" + struct.pack("<HhhHI", size, ascent, descent, ascent + descent, len(glyphs))
    table = b"".join(struct.pack("<IihhHHI", *g) for g in glyphs)
    with open(out_path, "wb") as f:
        f.write(zlib.compress(header + table + bytes(blob), 9))
    return len(glyphs)


def main(out_dir, only=None):
    os.makedirs(out_dir, exist_ok=True)
    for face, file in FACES.items():
        if only and not face.startswith(only):
            continue
        # sans doubles as the UI face, so it gets the union of both size sets
        sizes = SANS_SIZES if face.startswith("sans") else SERIF_SIZES
        for size in sizes:
            out = os.path.join(out_dir, f"{face}-{size}.tfnt")
            n = bake(file, size, out)
            print(f"{out}: {n} glyphs, {os.path.getsize(out)} bytes")


if __name__ == "__main__":
    # optional second argument: bake only faces starting with this name
    main(sys.argv[1] if len(sys.argv) > 1 else "fonts", sys.argv[2] if len(sys.argv) > 2 else None)
