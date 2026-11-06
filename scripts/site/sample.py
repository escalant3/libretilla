#!/usr/bin/env python3
"""Write the document shown in the website's screenshots (stdlib only).

It reuses the fixture generator's builders and the page and font of
Resources/Blank.docx, so it looks like a document started in Libretilla.

Usage: python3 scripts/site/sample.py <out.docx>
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "fixtures"))
import make_corpus as mc  # noqa: E402
from make_corpus import p, r  # noqa: E402


def main() -> None:
    out = Path(sys.argv[1])
    pkg = mc.Package("A small notebook", application="Libretilla", creator="")
    text_width = mc.BLANK_PAGE["w"] - mc.BLANK_PAGE["margins"][1] - mc.BLANK_PAGE["margins"][3]
    pkg.styles = mc.styles_xml(body_size=24, line=276, text_width=text_width)
    pkg.theme = mc.theme_xml(major=mc.BLANK_FONT, minor=mc.BLANK_FONT)
    pkg.font_table = mc.FONT_TABLE.replace(
        "</w:fonts>",
        f'<w:font w:name="{mc.BLANK_FONT}"><w:charset w:val="00"/><w:family w:val="roman"/>'
        '<w:pitch w:val="variable"/></w:font></w:fonts>')
    body = "".join([
        p("A small notebook", style="Title"),
        p("Notes on writing without distractions", style="Subtitle"),
        p("Why a smaller tool", style="Heading1"),
        p("Most of what we write is a letter, a report or a few pages of notes. It needs headings, ",
          r("bold", b=True), " and ", r("italics", i=True),
          ", a list or two and the odd table, and it has to arrive as a Word file that opens anywhere. "
          "Everything else gets in the way."),
        p("A quiet page lets the words come first. The document saves itself as you type, so there is "
          "nothing to remember and nothing to lose."),
        p("What it should do", style="Heading2"),
        p("Open the file it was given, and save back to that same file.", style="ListParagraph", num=(1, 0)),
        p("Keep every part of the document it doesn't edit, byte for byte.", style="ListParagraph", num=(1, 0)),
        p("Look and behave like every other Mac app.", style="ListParagraph", num=(1, 0)),
        p("Una libreta pequeña: escribir, guardar y nada más.", style="Quote"),
    ])
    pkg.write(out, mc.document(body, mc.sect_pr(**mc.BLANK_PAGE)), numbering=True)
    print(out)


if __name__ == "__main__":
    main()
