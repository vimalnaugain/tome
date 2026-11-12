#!/usr/bin/env python3
"""Build a small multi-chapter EPUB3 (with NCX fallback) for tests.

The story is original filler written for Tome's tests; each chapter has
distinct events so a recap can be checked for spoilers (chapters after the
reading position must never leak into a recap).
"""
import io
import sys
import zipfile

TITLE = "The Lighthouse at Gull's Reach"
AUTHOR = "Tome Test Fixtures"

CHAPTERS = [
    ("Chapter 1: The Letter", [
        "Mara Quill had not been back to Gull's Reach in eleven years when the letter came. It was written in her grandmother's cramped hand, though her grandmother had been dead since spring.",
        "<em>Come home,</em> it said. <em>The light has gone out, and only you know why.</em>",
        "She read it three times at the kitchen table of her flat in the city, then packed a single bag and caught the night train north.",
        "On the platform she noticed a man in a grey coat who seemed to be watching her. When she looked back, he was gone.",
    ]),
    ("Chapter 2: The Keeper's Cottage", [
        "The cottage at the foot of the lighthouse smelled of salt and old paper. Her cousin Tobias met her at the door, nervous and thinner than she remembered.",
        "“The lamp hasn’t turned in six weeks,” he told her. “The harbour board wants to sell the whole headland to a developer named Asher Vane.”",
        "In her grandmother's desk Mara found a brass key with a tag that read <strong>No. 7</strong>, and a logbook with the last three pages torn out.",
        "That night she saw a lantern moving among the rocks below the cliff, though the tide was high and no one should have been there.",
    ]),
    ("Chapter 3: The Man in the Grey Coat", [
        "In the village pub, Mara recognised the man from the train. He introduced himself as Elias Thorn, an insurance investigator looking into a ship that ran aground the night the light failed.",
        "The ship, the <em>Saint Brendan</em>, had carried no cargo on its manifest, yet three crates had washed ashore and vanished before the coastguard arrived.",
        "Elias suspected someone had put the light out on purpose. Mara did not tell him about the key.",
        "Walking home, she found the cottage door open and the logbook gone.",
    ]),
    ("Chapter 4: Locker No. 7", [
        "The key fitted locker number seven in the old lifeboat station. Inside was a waterproof tin holding her grandmother's diary.",
        "The diary revealed that her grandmother had been paid for years to keep the light dark on certain nights, letting smugglers land in the cove. She had stopped when a boy drowned.",
        "The final entry named the man who had paid her: Tobias.",
        "Mara closed the tin with shaking hands. Behind her, the station door creaked open.",
    ]),
    ("Chapter 5: The Storm", [
        "It was Tobias, soaked from the rain, and he begged her to understand. Asher Vane had threatened him; the debts were not his alone.",
        "As the storm rose, Elias arrived with the coastguard. Tobias fled up the lighthouse stairs, and Mara followed him to the lamp room.",
        "Together they relit the great lamp, and its beam swept across a fishing boat caught on the rocks. The crew were saved.",
        "Tobias surrendered at dawn. Asher Vane was arrested at the harbour with the missing crates.",
    ]),
    ("Chapter 6: The Light Returns", [
        "Weeks later Mara signed the papers that made the lighthouse a trust, so no developer could ever buy the headland.",
        "Elias stayed in the village longer than his investigation required.",
        "On the first clear night of autumn, Mara climbed to the lamp room and watched the beam turn over the water, steady as a heartbeat.",
    ]),
]


def xhtml(title, paras):
    body = "\n".join(f"<p>{p}</p>" for p in paras)
    return f"""<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>{title}</title><style>p {{ text-indent: 1em; }}</style></head>
<body>
<section epub:type="chapter" id="top">
<h1>{title}</h1>
{body}
<aside epub:type="footnote" id="fn1"><p>This footnote must not appear in reading text.</p></aside>
</section>
</body>
</html>
"""


def make_cover_jpeg(progressive=False):
    """A simple illustrated cover: sky, sea, lighthouse with a beam, title."""
    from PIL import Image, ImageDraw, ImageFont
    w, h = 1000, 1500
    im = Image.new("RGB", (w, h), (24, 38, 74))
    d = ImageDraw.Draw(im)
    for y in range(900):  # night sky gradient
        c = int(24 + y / 900 * 60)
        d.line([(0, y), (w, y)], fill=(c, c + 14, c + 50))
    d.rectangle([0, 900, w, h], fill=(16, 52, 80))
    for i in range(0, w, 40):  # waves
        d.arc([i, 930, i + 80, 990], 200, 340, fill=(120, 170, 200), width=4)
    d.polygon([(430, 900), (570, 900), (540, 430), (460, 430)], fill=(236, 230, 214))
    for y in (520, 640, 760):
        d.rectangle([452, y, 548, y + 40], fill=(170, 40, 40))
    d.rectangle([450, 380, 550, 430], fill=(250, 220, 120))
    d.polygon([(500, 405), (0, 250), (0, 560)], fill=(250, 236, 170))
    d.polygon([(380, 900), (620, 900), (700, 1000), (300, 1000)], fill=(60, 60, 60))
    def load(path, size):
        try:
            return ImageFont.truetype(path, size)
        except OSError:  # font not installed (e.g. CI): Pillow's built-in font
            return ImageFont.load_default(size)
    font = load("/usr/share/fonts/truetype/crosextra/Caladea-Bold.ttf", 96)
    small = load("/usr/share/fonts/truetype/crosextra/Caladea-Italic.ttf", 54)
    for i, line in enumerate(["The Lighthouse", "at Gull's Reach"]):
        tw = d.textlength(line, font=font)
        d.text(((w - tw) / 2, 1080 + i * 110), line, font=font, fill=(250, 246, 230))
    a = "Tome Test Fixtures"
    d.text(((w - d.textlength(a, font=small)) / 2, 1360), a, font=small, fill=(210, 220, 230))
    buf = io.BytesIO()
    im.save(buf, "JPEG", quality=85, progressive=progressive)
    return buf.getvalue()


def main(out, repeat=1, cover="epub3"):
    """cover: "epub3" (properties=cover-image), "meta" (EPUB2 <meta name=cover>),
    "html" (only an <img> in the first chapter), "progressive", or "none"."""
    with zipfile.ZipFile(out, "w") as z:
        z.writestr(zipfile.ZipInfo("mimetype"), "application/epub+zip", compress_type=zipfile.ZIP_STORED)
        z.writestr("META-INF/container.xml", """<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>""", compress_type=zipfile.ZIP_DEFLATED)
        manifest, spine, navli, ncx = [], [], [], []
        meta_cover = ""
        if cover != "none":
            z.writestr("OEBPS/images/cover.jpg", make_cover_jpeg(cover == "progressive"))
            if cover in ("epub3", "progressive"):
                manifest.append('<item id="cimg" href="images/cover.jpg" media-type="image/jpeg" properties="cover-image"/>')
            elif cover == "meta":
                manifest.append('<item id="img01" href="images/cover.jpg" media-type="image/jpeg"/>')
                meta_cover = '<meta name="cover" content="img01"/>'
            else:  # html: an unnamed image used on the first page
                manifest.append('<item id="i1" href="images/cover.jpg" media-type="image/jpeg"/>')
        for i, (title, paras) in enumerate(CHAPTERS, 1):
            name = f"text/ch{i:02d}.xhtml"
            body = xhtml(title, paras * repeat)
            if i == 1 and cover == "html":
                body = body.replace("<body>", '<body><div><img src="../images/cover.jpg" alt=""/></div>')
            z.writestr("OEBPS/" + name, body, compress_type=zipfile.ZIP_DEFLATED)
            manifest.append(f'<item id="ch{i}" href="{name}" media-type="application/xhtml+xml"/>')
            spine.append(f'<itemref idref="ch{i}"/>')
            navli.append(f'<li><a href="{name}#top">{title}</a></li>')
            ncx.append(f'<navPoint id="n{i}" playOrder="{i}"><navLabel><text>{title}</text></navLabel><content src="{name}"/></navPoint>')
        z.writestr("OEBPS/nav.xhtml", f"""<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head>
<body><nav epub:type="toc"><ol>{''.join(navli)}</ol></nav></body></html>""", compress_type=zipfile.ZIP_DEFLATED)
        z.writestr("OEBPS/toc.ncx", f"""<?xml version="1.0"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><navMap>{''.join(ncx)}</navMap></ncx>""",
                   compress_type=zipfile.ZIP_DEFLATED)
        z.writestr("OEBPS/content.opf", f"""<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
<dc:identifier id="uid">tome-test-0001</dc:identifier>
{meta_cover}<dc:title>{TITLE}</dc:title><dc:creator>{AUTHOR}</dc:creator><dc:language>en</dc:language>
</metadata>
<manifest>
<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
{''.join(manifest)}
</manifest>
<spine toc="ncx">{''.join(spine)}</spine>
</package>""", compress_type=zipfile.ZIP_DEFLATED)


if __name__ == "__main__":
    # optional second argument: repeat each chapter's text N times (longer chapters)
    # optional third argument: cover style (see main)
    main(sys.argv[1] if len(sys.argv) > 1 else "test.epub", int(sys.argv[2]) if len(sys.argv) > 2 else 1,
         sys.argv[3] if len(sys.argv) > 3 else "epub3")
