#!/usr/bin/env python3
"""Build a small multi-chapter EPUB3 (with NCX fallback) for tests.

The story is original filler written for Tome's tests; each chapter has
distinct events so a recap can be checked for spoilers (chapters after the
reading position must never leak into a recap).
"""
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


def main(out, repeat=1):
    with zipfile.ZipFile(out, "w") as z:
        z.writestr(zipfile.ZipInfo("mimetype"), "application/epub+zip", compress_type=zipfile.ZIP_STORED)
        z.writestr("META-INF/container.xml", """<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>""", compress_type=zipfile.ZIP_DEFLATED)
        manifest, spine, navli, ncx = [], [], [], []
        for i, (title, paras) in enumerate(CHAPTERS, 1):
            name = f"text/ch{i:02d}.xhtml"
            z.writestr("OEBPS/" + name, xhtml(title, paras * repeat), compress_type=zipfile.ZIP_DEFLATED)
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
<dc:title>{TITLE}</dc:title><dc:creator>{AUTHOR}</dc:creator><dc:language>en</dc:language>
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
    main(sys.argv[1] if len(sys.argv) > 1 else "test.epub", int(sys.argv[2]) if len(sys.argv) > 2 else 1)
