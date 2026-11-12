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

FONT_DIR = "/usr/share/fonts/truetype/crosextra"
FACES = {
    "serif-regular": "Caladea-Regular.ttf",
    "serif-italic": "Caladea-Italic.ttf",
    "serif-bold": "Caladea-Bold.ttf",
    "serif-bolditalic": "Caladea-BoldItalic.ttf",
    "sans-regular": "Carlito-Regular.ttf",
    "sans-bold": "Carlito-Bold.ttf",
}
SERIF_SIZES = [22, 26, 30, 34, 40, 46, 54]
SANS_SIZES = [20, 24, 28, 34, 40, 48]

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


def bake(path, size, out_path):
    primary = ImageFont.truetype(path, size)
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


def main(out_dir):
    os.makedirs(out_dir, exist_ok=True)
    for face, file in FACES.items():
        sizes = SERIF_SIZES if face.startswith("serif") else SANS_SIZES
        for size in sizes:
            out = os.path.join(out_dir, f"{face}-{size}.tfnt")
            n = bake(os.path.join(FONT_DIR, file), size, out)
            print(f"{out}: {n} glyphs, {os.path.getsize(out)} bytes")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "fonts")
