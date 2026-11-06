#!/usr/bin/env python3
"""Generate Libretilla's synthetic .docx fixture corpus (stdlib only).

The files imitate the markup Microsoft Word 2016+ writes (namespaces, part
layout, style ids, rsids omitted) so we can exercise a DOCX codec without
owning Word. They are *not* a substitute for real Word/LibreOffice/Google Docs
output -- see Fixtures/README.md for the slots the human fills in.

Output is deterministic (fixed zip timestamps, sorted content) so re-running
the script leaves `git status` clean.

Usage: python3 scripts/fixtures/make_corpus.py [--out Fixtures/generated]
"""

from __future__ import annotations

import argparse
import struct
import zipfile
import zlib
from pathlib import Path
from xml.sax.saxutils import escape

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent

# --------------------------------------------------------------------------
# Namespaces (Word 2016 document root declares many; we keep the common set)
# --------------------------------------------------------------------------
NS = {
    "wpc": "http://schemas.microsoft.com/office/word/2010/wordprocessingCanvas",
    "mc": "http://schemas.openxmlformats.org/markup-compatibility/2006",
    "o": "urn:schemas-microsoft-com:office:office",
    "r": "http://schemas.openxmlformats.org/officeDocument/2006/relationships",
    "m": "http://schemas.openxmlformats.org/officeDocument/2006/math",
    "v": "urn:schemas-microsoft-com:vml",
    "wp14": "http://schemas.microsoft.com/office/word/2010/wordprocessingDrawing",
    "wp": "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing",
    "w10": "urn:schemas-microsoft-com:office:word",
    "w": "http://schemas.openxmlformats.org/wordprocessingml/2006/main",
    "w14": "http://schemas.microsoft.com/office/word/2010/wordml",
    "wpg": "http://schemas.microsoft.com/office/word/2010/wordprocessingGroup",
    "wps": "http://schemas.microsoft.com/office/word/2010/wordprocessingShape",
    "a": "http://schemas.openxmlformats.org/drawingml/2006/main",
    "pic": "http://schemas.openxmlformats.org/drawingml/2006/picture",
}
ROOT_NS = " ".join(f'xmlns:{k}="{v}"' for k, v in NS.items()) + ' mc:Ignorable="w14 wp14"'
W_NS = f'xmlns:w="{NS["w"]}" xmlns:r="{NS["r"]}"'
XML_DECL = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
REL = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
PKG_REL = "http://schemas.openxmlformats.org/package/2006/relationships"

# --------------------------------------------------------------------------
# Run / paragraph builders (element order follows ECMA-376 CT_RPr / CT_PPr)
# --------------------------------------------------------------------------
RPR_ORDER = ["rStyle", "rFonts", "b", "i", "strike", "color", "sz", "highlight", "u", "vertAlign", "lang"]


def rpr(props: dict | None) -> str:
    if not props:
        return ""
    out = []
    for key in RPR_ORDER:
        if key not in props:
            continue
        val = props[key]
        if key == "rStyle":
            out.append(f'<w:rStyle w:val="{val}"/>')
        elif key == "rFonts":
            out.append(f'<w:rFonts w:ascii="{val}" w:hAnsi="{val}" w:cs="{val}"/>')
        elif key in ("b", "i", "strike"):
            out.append(f"<w:{key}/>")
        elif key == "sz":
            out.append(f'<w:sz w:val="{val}"/><w:szCs w:val="{val}"/>')
        elif key == "lang":
            out.append(f'<w:lang w:val="{val}"/>')
        else:
            out.append(f'<w:{key} w:val="{val}"/>')
    return f"<w:rPr>{''.join(out)}</w:rPr>"


def t(text: str) -> str:
    space = ' xml:space="preserve"' if text != text.strip() or "  " in text else ""
    return f"<w:t{space}>{escape(text)}</w:t>"


def r(text: str, **props) -> str:
    return f"<w:r>{rpr(props)}{t(text)}</w:r>"


def p(*content: str, style: str | None = None, jc: str | None = None, num: tuple[int, int] | None = None,
      spacing: str | None = None, ind: str | None = None, sect: str | None = None) -> str:
    """content items are raw run XML or plain strings (wrapped in a plain run)."""
    ppr = []
    if style:
        ppr.append(f'<w:pStyle w:val="{style}"/>')
    if num:
        ppr.append(f'<w:numPr><w:ilvl w:val="{num[1]}"/><w:numId w:val="{num[0]}"/></w:numPr>')
    if spacing:
        ppr.append(spacing)
    if ind:
        ppr.append(ind)
    if jc:
        ppr.append(f'<w:jc w:val="{jc}"/>')
    if sect:
        ppr.append(sect)
    body = "".join(c if c.startswith("<") else r(c) for c in content)
    pp = f"<w:pPr>{''.join(ppr)}</w:pPr>" if ppr else ""
    return f"<w:p>{pp}{body}</w:p>"


def page_break() -> str:
    return '<w:p><w:r><w:br w:type="page"/></w:r></w:p>'


def sect_pr(*, header: str | None = None, footer: str | None = None, cols: int = 1,
            w: int = 12240, h: int = 15840, orient: str | None = None, type_: str | None = None,
            title_pg: bool = False, margins: tuple[int, int, int, int] = (1440, 1440, 1440, 1440)) -> str:
    refs = ""
    if header:
        refs += f'<w:headerReference w:type="default" r:id="{header}"/>'
    if footer:
        refs += f'<w:footerReference w:type="default" r:id="{footer}"/>'
    typ = f'<w:type w:val="{type_}"/>' if type_ else ""
    o = f' w:orient="{orient}"' if orient else ""
    col = f'<w:cols w:num="{cols}" w:space="720"/>' if cols > 1 else '<w:cols w:space="720"/>'
    tp = "<w:titlePg/>" if title_pg else ""
    return (f"<w:sectPr>{refs}{typ}<w:pgSz w:w=\"{w}\" w:h=\"{h}\"{o}/>"
            f'<w:pgMar w:top="{margins[0]}" w:right="{margins[1]}" w:bottom="{margins[2]}" w:left="{margins[3]}"'
            ' w:header="720" w:footer="720" w:gutter="0"/>'
            f'{col}{tp}<w:docGrid w:linePitch="360"/></w:sectPr>')


def document(body: str, sect: str | None = None) -> str:
    return f"{XML_DECL}<w:document {ROOT_NS}><w:body>{body}{sect or sect_pr()}</w:body></w:document>"


# --------------------------------------------------------------------------
# Shared parts
# --------------------------------------------------------------------------
def style_p(sid, name, *, based="Normal", next_="Normal", ppr="", rpr_="", ui=None, q=True, outline=None):
    ol = f'<w:outlineLvl w:val="{outline}"/>' if outline is not None else ""
    pp = f"<w:pPr>{ppr}{ol}</w:pPr>" if (ppr or ol) else ""
    rp = f"<w:rPr>{rpr_}</w:rPr>" if rpr_ else ""
    uip = f'<w:uiPriority w:val="{ui}"/>' if ui is not None else ""
    qf = "<w:qFormat/>" if q else ""
    return (f'<w:style w:type="paragraph" w:styleId="{sid}"><w:name w:val="{name}"/>'
            f'<w:basedOn w:val="{based}"/><w:next w:val="{next_}"/>{uip}{qf}{pp}{rp}</w:style>')


HEADING_SIZES = {1: 32, 2: 26, 3: 24, 4: 22, 5: 22, 6: 22}


def styles_xml(*, body_size: int = 22, line: int = 259, text_width: int = 9360) -> str:
    headings = "".join(
        style_p(f"Heading{n}", f"heading {n}", ui=9,
                ppr='<w:keepNext/><w:keepLines/><w:spacing w:before="240" w:after="0"/>',
                rpr_=f'<w:rFonts w:asciiTheme="majorHAnsi" w:hAnsiTheme="majorHAnsi"/>'
                     f'{"<w:b/>" if n <= 3 else ""}{"<w:i/>" if n in (4, 6) else ""}'
                     f'<w:color w:val="2F5496"/><w:sz w:val="{HEADING_SIZES[n]}"/><w:szCs w:val="{HEADING_SIZES[n]}"/>',
                outline=n - 1)
        for n in range(1, 7))
    return (XML_DECL + f"<w:styles {W_NS}>"
            "<w:docDefaults><w:rPrDefault><w:rPr>"
            '<w:rFonts w:asciiTheme="minorHAnsi" w:eastAsiaTheme="minorHAnsi" w:hAnsiTheme="minorHAnsi" w:cstheme="minorBidi"/>'
            f'<w:sz w:val="{body_size}"/><w:szCs w:val="{body_size}"/><w:lang w:val="en-US" w:eastAsia="en-US" w:bidi="ar-SA"/>'
            "</w:rPr></w:rPrDefault><w:pPrDefault><w:pPr>"
            f'<w:spacing w:after="160" w:line="{line}" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>'
            '<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>'
            + style_p("Title", "Title", ui=10, ppr='<w:spacing w:after="0" w:line="240" w:lineRule="auto"/><w:contextualSpacing/>',
                      rpr_='<w:rFonts w:asciiTheme="majorHAnsi" w:hAnsiTheme="majorHAnsi"/><w:kern w:val="28"/><w:sz w:val="56"/><w:szCs w:val="56"/>')
            + style_p("Subtitle", "Subtitle", ui=11,
                      rpr_='<w:color w:val="5A5A5A"/><w:spacing w:val="15"/><w:sz w:val="28"/>')
            + headings
            + style_p("Quote", "Quote", ui=29, ppr='<w:spacing w:before="200"/><w:ind w:left="864" w:right="864"/><w:jc w:val="center"/>',
                      rpr_='<w:i/><w:iCs/><w:color w:val="404040"/>')
            + style_p("SourceCode", "Source Code", ppr='<w:spacing w:after="0" w:line="240" w:lineRule="auto"/>',
                      rpr_='<w:rFonts w:ascii="Menlo" w:hAnsi="Menlo" w:cs="Menlo"/><w:sz w:val="20"/>')
            + style_p("ListParagraph", "List Paragraph", ui=34, ppr='<w:ind w:left="720"/><w:contextualSpacing/>')
            + style_p("Header", "header", q=False, ppr=f'<w:tabs><w:tab w:val="center" w:pos="{text_width // 2}"/><w:tab w:val="right" w:pos="{text_width}"/></w:tabs><w:spacing w:after="0" w:line="240" w:lineRule="auto"/>')
            + style_p("Footer", "footer", q=False, ppr=f'<w:tabs><w:tab w:val="center" w:pos="{text_width // 2}"/><w:tab w:val="right" w:pos="{text_width}"/></w:tabs><w:spacing w:after="0" w:line="240" w:lineRule="auto"/>')
            + style_p("FootnoteText", "footnote text", q=False, ppr='<w:spacing w:after="0" w:line="240" w:lineRule="auto"/>', rpr_='<w:sz w:val="20"/>')
            + style_p("CommentText", "annotation text", q=False, rpr_='<w:sz w:val="20"/>')
            + '<w:style w:type="character" w:default="1" w:styleId="DefaultParagraphFont"><w:name w:val="Default Paragraph Font"/><w:uiPriority w:val="1"/><w:semiHidden/><w:unhideWhenUsed/></w:style>'
            + '<w:style w:type="character" w:styleId="Hyperlink"><w:name w:val="Hyperlink"/><w:basedOn w:val="DefaultParagraphFont"/><w:uiPriority w:val="99"/><w:unhideWhenUsed/><w:rPr><w:color w:val="0563C1" w:themeColor="hyperlink"/><w:u w:val="single"/></w:rPr></w:style>'
            + '<w:style w:type="character" w:styleId="FootnoteReference"><w:name w:val="footnote reference"/><w:basedOn w:val="DefaultParagraphFont"/><w:rPr><w:vertAlign w:val="superscript"/></w:rPr></w:style>'
            + '<w:style w:type="character" w:styleId="CommentReference"><w:name w:val="annotation reference"/><w:basedOn w:val="DefaultParagraphFont"/><w:rPr><w:sz w:val="16"/></w:rPr></w:style>'
            + '<w:style w:type="table" w:default="1" w:styleId="TableNormal"><w:name w:val="Normal Table"/><w:uiPriority w:val="99"/><w:semiHidden/><w:unhideWhenUsed/><w:tblPr><w:tblInd w:w="0" w:type="dxa"/><w:tblCellMar><w:top w:w="0" w:type="dxa"/><w:left w:w="108" w:type="dxa"/><w:bottom w:w="0" w:type="dxa"/><w:right w:w="108" w:type="dxa"/></w:tblCellMar></w:tblPr></w:style>'
            + '<w:style w:type="table" w:styleId="TableGrid"><w:name w:val="Table Grid"/><w:basedOn w:val="TableNormal"/><w:uiPriority w:val="39"/><w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/></w:pPr><w:tblPr><w:tblBorders>'
              '<w:top w:val="single" w:sz="4" w:space="0" w:color="auto"/><w:left w:val="single" w:sz="4" w:space="0" w:color="auto"/>'
              '<w:bottom w:val="single" w:sz="4" w:space="0" w:color="auto"/><w:right w:val="single" w:sz="4" w:space="0" w:color="auto"/>'
              '<w:insideH w:val="single" w:sz="4" w:space="0" w:color="auto"/><w:insideV w:val="single" w:sz="4" w:space="0" w:color="auto"/>'
              '</w:tblBorders></w:tblPr></w:style>'
            + '<w:style w:type="numbering" w:default="1" w:styleId="NoList"><w:name w:val="No List"/><w:uiPriority w:val="99"/><w:semiHidden/><w:unhideWhenUsed/></w:style>'
            + "</w:styles>")


SETTINGS = (XML_DECL + f'<w:settings {W_NS} xmlns:m="{NS["m"]}">'
            '<w:zoom w:percent="100"/><w:proofState w:spelling="clean" w:grammar="clean"/>'
            '<w:defaultTabStop w:val="720"/><w:characterSpacingControl w:val="doNotCompress"/>'
            "<w:compat>"
            '<w:compatSetting w:name="compatibilityMode" w:uri="http://schemas.microsoft.com/office/word" w:val="15"/>'
            '<w:compatSetting w:name="overrideTableStyleFontSizeAndJustification" w:uri="http://schemas.microsoft.com/office/word" w:val="1"/>'
            '<w:compatSetting w:name="enableOpenTypeFeatures" w:uri="http://schemas.microsoft.com/office/word" w:val="1"/>'
            '<w:compatSetting w:name="doNotFlipMirrorIndents" w:uri="http://schemas.microsoft.com/office/word" w:val="1"/>'
            "</w:compat>"
            '<m:mathPr><m:mathFont m:val="Cambria Math"/></m:mathPr>'
            '<w:themeFontLang w:val="en-US"/><w:decimalSymbol w:val="."/><w:listSeparator w:val=","/>'
            "</w:settings>")

FONT_TABLE = (XML_DECL + f"<w:fonts {W_NS}>"
              '<w:font w:name="Calibri"><w:panose1 w:val="020F0502020204030204"/><w:charset w:val="00"/><w:family w:val="swiss"/><w:pitch w:val="variable"/></w:font>'
              '<w:font w:name="Times New Roman"><w:panose1 w:val="02020603050405020304"/><w:charset w:val="00"/><w:family w:val="roman"/><w:pitch w:val="variable"/></w:font>'
              '<w:font w:name="Calibri Light"><w:panose1 w:val="020F0302020204030204"/><w:charset w:val="00"/><w:family w:val="swiss"/><w:pitch w:val="variable"/></w:font>'
              '<w:font w:name="Menlo"><w:charset w:val="00"/><w:family w:val="modern"/><w:pitch w:val="fixed"/></w:font>'
              "</w:fonts>")

WEB_SETTINGS = XML_DECL + f'<w:webSettings {W_NS}><w:optimizeForBrowser/><w:allowPNG/></w:webSettings>'


def _fill(color_xml: str) -> str:
    return f"<a:solidFill>{color_xml}</a:solidFill>"


def theme_xml(major: str = "Calibri Light", minor: str = "Calibri") -> str:
    return THEME.replace('<a:latin typeface="Calibri Light"/>', f'<a:latin typeface="{major}"/>', 1).replace(
        '<a:latin typeface="Calibri"/>', f'<a:latin typeface="{minor}"/>', 1)


THEME = (XML_DECL + f'<a:theme xmlns:a="{NS["a"]}" name="Office Theme"><a:themeElements>'
         '<a:clrScheme name="Office">'
         '<a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1><a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1>'
         '<a:dk2><a:srgbClr val="44546A"/></a:dk2><a:lt2><a:srgbClr val="E7E6E6"/></a:lt2>'
         '<a:accent1><a:srgbClr val="4472C4"/></a:accent1><a:accent2><a:srgbClr val="ED7D31"/></a:accent2>'
         '<a:accent3><a:srgbClr val="A5A5A5"/></a:accent3><a:accent4><a:srgbClr val="FFC000"/></a:accent4>'
         '<a:accent5><a:srgbClr val="5B9BD5"/></a:accent5><a:accent6><a:srgbClr val="70AD47"/></a:accent6>'
         '<a:hlink><a:srgbClr val="0563C1"/></a:hlink><a:folHlink><a:srgbClr val="954F72"/></a:folHlink>'
         "</a:clrScheme>"
         '<a:fontScheme name="Office">'
         '<a:majorFont><a:latin typeface="Calibri Light"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont>'
         '<a:minorFont><a:latin typeface="Calibri"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont>'
         "</a:fontScheme>"
         '<a:fmtScheme name="Office"><a:fillStyleLst>'
         + _fill('<a:schemeClr val="phClr"/>') * 3 +
         "</a:fillStyleLst><a:lnStyleLst>"
         + ('<a:ln w="6350" cap="flat" cmpd="sng" algn="ctr">' + _fill('<a:schemeClr val="phClr"/>') + '<a:prstDash val="solid"/><a:miter lim="800000"/></a:ln>') * 3 +
         "</a:lnStyleLst><a:effectStyleLst>"
         + "<a:effectStyle><a:effectLst/></a:effectStyle>" * 3 +
         "</a:effectStyleLst><a:bgFillStyleLst>"
         + _fill('<a:schemeClr val="phClr"/>') * 3 +
         "</a:bgFillStyleLst></a:fmtScheme></a:themeElements><a:objectDefaults/><a:extraClrSchemeLst/></a:theme>")


def numbering_xml() -> str:
    bullets = ["•", "o", "▪"]
    bfonts = ["Symbol", "Courier New", "Wingdings"]

    def lvl(i, fmt, text, font=None):
        rp = f'<w:rPr><w:rFonts w:ascii="{font}" w:hAnsi="{font}" w:hint="default"/></w:rPr>' if font else ""
        return (f'<w:lvl w:ilvl="{i}"><w:start w:val="1"/><w:numFmt w:val="{fmt}"/>'
                f'<w:lvlText w:val="{escape(text)}"/><w:lvlJc w:val="left"/>'
                f'<w:pPr><w:ind w:left="{720 * (i + 1)}" w:hanging="360"/></w:pPr>{rp}</w:lvl>')
    # Word uses the real bullet glyph with a symbol font; we keep a Unicode bullet + font name hint.
    bullet = ('<w:abstractNum w:abstractNumId="0"><w:multiLevelType w:val="hybridMultilevel"/>'
              + "".join(lvl(i, "bullet", bullets[i % 3], bfonts[i % 3]) for i in range(9)) + "</w:abstractNum>")
    decfmt = ["decimal", "lowerLetter", "lowerRoman"]
    decimal = ('<w:abstractNum w:abstractNumId="1"><w:multiLevelType w:val="hybridMultilevel"/>'
               + "".join(lvl(i, decfmt[i % 3], f"%{i + 1}.") for i in range(9)) + "</w:abstractNum>")
    return (XML_DECL + f"<w:numbering {W_NS}>{bullet}{decimal}"
            '<w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>'
            '<w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num>'
            '<w:num w:numId="3"><w:abstractNumId w:val="1"/><w:lvlOverride w:ilvl="0"><w:startOverride w:val="1"/></w:lvlOverride></w:num>'
            "</w:numbering>")


def core_xml(title: str, creator: str = "Libretilla fixture generator") -> str:
    return (XML_DECL + '<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" '
            'xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" '
            'xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">'
            f"<dc:title>{escape(title)}</dc:title><dc:creator>{escape(creator)}</dc:creator>"
            f"<cp:lastModifiedBy>{escape(creator)}</cp:lastModifiedBy><cp:revision>1</cp:revision>"
            '<dcterms:created xsi:type="dcterms:W3CDTF">2026-01-01T00:00:00Z</dcterms:created>'
            '<dcterms:modified xsi:type="dcterms:W3CDTF">2026-01-01T00:00:00Z</dcterms:modified>'
            "</cp:coreProperties>")


APP_XML = (XML_DECL + '<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" '
           'xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">'
           "<Template>Normal.dotm</Template><TotalTime>0</TotalTime><Application>APPLICATION</Application>"
           "<DocSecurity>0</DocSecurity><ScaleCrop>false</ScaleCrop><Company></Company><LinksUpToDate>false</LinksUpToDate>"
           "<SharedDoc>false</SharedDoc><HyperlinksChanged>false</HyperlinksChanged><AppVersion>16.0000</AppVersion></Properties>")


# --------------------------------------------------------------------------
# Package assembly
# --------------------------------------------------------------------------
class Package:
    CT_MAIN = "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"

    def __init__(self, title: str, application: str = "Microsoft Office Word", creator: str = "Libretilla fixture generator"):
        self.title = title
        self.application = application
        self.creator = creator
        self.parts: dict[str, bytes] = {}
        self.overrides: dict[str, str] = {}
        self.defaults = {"rels": "application/vnd.openxmlformats-package.relationships+xml", "xml": "application/xml"}
        self.doc_rels: list[tuple[str, str, str, str | None]] = []  # id, type, target, mode
        self._next = 1
        # Parts the blank template sets differently from the fixtures.
        self.styles = styles_xml()
        self.theme = THEME
        self.font_table = FONT_TABLE

    def rel(self, type_: str, target: str, external: bool = False) -> str:
        rid = f"rId{self._next}"
        self._next += 1
        self.doc_rels.append((rid, f"{REL}/{type_}", target, "External" if external else None))
        return rid

    def add(self, name: str, data: str | bytes, ctype: str | None = None):
        self.parts[name] = data.encode("utf-8") if isinstance(data, str) else data
        if ctype:
            self.overrides["/" + name] = ctype

    def media(self, name: str, data: bytes) -> str:
        ext = name.rsplit(".", 1)[1]
        self.defaults[ext] = {"png": "image/png", "jpeg": "image/jpeg", "jpg": "image/jpeg"}[ext]
        self.add(f"word/media/{name}", data)
        return self.rel("image", f"media/{name}")

    def write(self, path: Path, document_xml: str, *, numbering: bool = False, extra_pkg_rels: str = ""):
        wml = "application/vnd.openxmlformats-officedocument.wordprocessingml"
        # Standard Word parts, in Word's relationship order.
        self.rel("styles", "styles.xml")
        self.add("word/styles.xml", self.styles, f"{wml}.styles+xml")
        if numbering:
            self.rel("numbering", "numbering.xml")
            self.add("word/numbering.xml", numbering_xml(), f"{wml}.numbering+xml")
        self.rel("settings", "settings.xml")
        self.add("word/settings.xml", SETTINGS, f"{wml}.settings+xml")
        self.rel("webSettings", "webSettings.xml")
        self.add("word/webSettings.xml", WEB_SETTINGS, f"{wml}.webSettings+xml")
        self.rel("fontTable", "fontTable.xml")
        self.add("word/fontTable.xml", self.font_table, f"{wml}.fontTable+xml")
        self.rel("theme", "theme/theme1.xml")
        self.add("word/theme/theme1.xml", self.theme, "application/vnd.openxmlformats-officedocument.theme+xml")
        self.add("word/document.xml", document_xml, self.CT_MAIN)
        self.add("docProps/core.xml", core_xml(self.title, self.creator),
                 "application/vnd.openxmlformats-package.core-properties+xml")
        self.add("docProps/app.xml", APP_XML.replace("APPLICATION", escape(self.application)), "application/vnd.openxmlformats-officedocument.extended-properties+xml")

        rels = "".join(
            f'<Relationship Id="{i}" Type="{ty}" Target="{escape(tg, {chr(34): "&quot;"})}"'
            + (f' TargetMode="{m}"' if m else "") + "/>"
            for i, ty, tg, m in self.doc_rels)
        self.add("word/_rels/document.xml.rels", f'{XML_DECL}<Relationships xmlns="{PKG_REL}">{rels}</Relationships>')
        self.add("_rels/.rels", (
            f'{XML_DECL}<Relationships xmlns="{PKG_REL}">'
            f'<Relationship Id="rId3" Type="{REL}/extended-properties" Target="docProps/app.xml"/>'
            '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>'
            f'<Relationship Id="rId1" Type="{REL}/officeDocument" Target="word/document.xml"/>'
            f"{extra_pkg_rels}</Relationships>"))

        defaults = "".join(f'<Default Extension="{e}" ContentType="{c}"/>' for e, c in sorted(self.defaults.items()))
        overrides = "".join(f'<Override PartName="{n}" ContentType="{c}"/>' for n, c in sorted(self.overrides.items()))
        ct = f'{XML_DECL}<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">{defaults}{overrides}</Types>'

        path.parent.mkdir(parents=True, exist_ok=True)
        order = ["_rels/.rels", "word/document.xml"]
        names = order + sorted(n for n in self.parts if n not in order)
        with zipfile.ZipFile(path, "w") as z:
            for name, data in [("[Content_Types].xml", ct.encode())] + [(n, self.parts[n]) for n in names]:
                info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = 0o644 << 16
                z.writestr(info, data)


# --------------------------------------------------------------------------
# Images (no third-party deps)
# --------------------------------------------------------------------------
def make_png(w: int, h: int) -> bytes:
    rows = []
    for y in range(h):
        row = bytearray([0])
        for x in range(w):
            on = ((x // 16) + (y // 16)) % 2 == 0
            row += bytes((0x44, 0x72, 0xC4) if on else (0xF2, 0xF2, 0xF2))
        rows.append(bytes(row))

    def chunk(tag: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(b"".join(rows), 9)) + chunk(b"IEND", b""))


def inline_image(rid: str, pid: int, name: str, w_px: int, h_px: int, descr: str) -> str:
    emu = 9525  # EMU per pixel at 96 dpi
    cx, cy = w_px * emu, h_px * emu
    return (f'<w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0">'
            f'<wp:extent cx="{cx}" cy="{cy}"/><wp:effectExtent l="0" t="0" r="0" b="0"/>'
            f'<wp:docPr id="{pid}" name="{escape(name)}" descr="{escape(descr)}"/>'
            '<wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr>'
            '<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">'
            f'<pic:pic><pic:nvPicPr><pic:cNvPr id="{pid}" name="{escape(name)}"/><pic:cNvPicPr/></pic:nvPicPr>'
            f'<pic:blipFill><a:blip r:embed="{rid}"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>'
            f'<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="{cx}" cy="{cy}"/></a:xfrm>'
            '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic>'
            "</a:graphicData></a:graphic></wp:inline></w:drawing></w:r>")


# --------------------------------------------------------------------------
# Fixtures
# --------------------------------------------------------------------------
LOREM = ("Lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut labore "
         "et dolore magna aliqua Ut enim ad minim veniam quis nostrud exercitation ullamco laboris nisi ut "
         "aliquip ex ea commodo consequat Duis aute irure dolor in reprehenderit in voluptate velit esse "
         "cillum dolore eu fugiat nulla pariatur Excepteur sint occaecat cupidatat non proident sunt in culpa "
         "qui officia deserunt mollit anim id est laborum").split()


def sentence(seed: int, words: int) -> str:
    out = [LOREM[(seed * 7 + i * 13) % len(LOREM)] for i in range(words)]
    out[0] = out[0].capitalize()
    return " ".join(out) + "."


def f01_plain(out: Path):
    body = "".join([
        p("This is a plain paragraph of text written in the Normal style."),
        p("A second paragraph follows. It has ", r("bold", b=True), ", ", r("italic", i=True), ", ",
          r("underlined", u="single"), ", ", r("struck", strike=True), ", ", r("red", color="C00000"), ", ",
          r("highlighted", highlight="yellow"), ", x", r("2", vertAlign="superscript"), " and H", r("2", vertAlign="subscript"),
          "O text, plus ", r("Times New Roman 14 pt", rFonts="Times New Roman", sz=28), "."),
        p("Centered paragraph.", jc="center"),
        p("Right-aligned paragraph.", jc="right"),
        p(sentence(1, 60), jc="both", spacing='<w:spacing w:before="240" w:after="240" w:line="360" w:lineRule="auto"/>'),
        p(sentence(2, 40), ind='<w:ind w:left="720" w:firstLine="720"/>'),
        p(sentence(3, 40), ind='<w:ind w:left="720" w:hanging="360"/>'),
        p("Tabs\tand  double  spaces\tare preserved."),
    ])
    Package("Plain text").write(out / "01-plain.docx", document(body))


def f02_headings(out: Path):
    body = [p("Document Title", style="Title"), p("A subtitle under the title", style="Subtitle")]
    for n in range(1, 7):
        body.append(p(f"Heading {n}", style=f"Heading{n}"))
        body.append(p(sentence(n, 25)))
    body.append(p("To be, or not to be, that is the question.", style="Quote"))
    body.append(p("let answer = 42", style="SourceCode"))
    body.append(p("print(answer)", style="SourceCode"))
    Package("Headings and styles").write(out / "02-headings.docx", document("".join(body)))


def f03_lists(out: Path):
    body = [p("Nested lists", style="Heading1"), p("Bulleted:")]
    for text, lvl in [("Fruit", 0), ("Apples", 1), ("Granny Smith", 2), ("Pink Lady", 2), ("Pears", 1),
                      ("Vegetables", 0), ("Carrots", 1)]:
        body.append(p(text, style="ListParagraph", num=(1, lvl)))
    body.append(p("Numbered:"))
    for text, lvl in [("Prepare", 0), ("Gather tools", 1), ("Read the manual", 1), ("Skim the index", 2),
                      ("Build", 0), ("Test", 0)]:
        body.append(p(text, style="ListParagraph", num=(2, lvl)))
    body.append(p("A paragraph between lists."))
    body.append(p("Restarted numbering, item one", style="ListParagraph", num=(3, 0)))
    body.append(p("Restarted numbering, item two", style="ListParagraph", num=(3, 0)))
    Package("Nested lists").write(out / "03-nested-lists.docx", document("".join(body)), numbering=True)


def tc(content: str, w: int, *, shd: str | None = None, span: int = 1, vmerge: str | None = None) -> str:
    props = f'<w:tcW w:w="{w}" w:type="dxa"/>'
    if span > 1:
        props += f'<w:gridSpan w:val="{span}"/>'
    if vmerge:
        props += '<w:vMerge w:val="restart"/>' if vmerge == "restart" else "<w:vMerge/>"
    if shd:
        props += f'<w:shd w:val="clear" w:color="auto" w:fill="{shd}"/>'
    return f"<w:tc><w:tcPr>{props}</w:tcPr>{content}</w:tc>"


def f04_tables(out: Path):
    col = 3120
    grid_col = f'<w:gridCol w:w="{col}"/>'
    grid = f"<w:tblGrid>{grid_col * 3}</w:tblGrid>"
    tblpr = ('<w:tblPr><w:tblStyle w:val="TableGrid"/><w:tblW w:w="0" w:type="auto"/>'
             '<w:tblLook w:val="04A0" w:firstRow="1" w:lastRow="0" w:firstColumn="1" w:lastColumn="0" w:noHBand="0" w:noVBand="1"/></w:tblPr>')
    header = ('<w:tr><w:trPr><w:tblHeader/></w:trPr>'
              + "".join(tc(p(r(h, b=True)), col, shd="D9E2F3") for h in ["Name", "Quantity", "Notes"]) + "</w:tr>")
    rows = "".join(
        "<w:tr>" + tc(p(a), col) + tc(p(b_, jc="right"), col) + tc(p(c), col) + "</w:tr>"
        for a, b_, c in [("Apples", "3", "Green"), ("Pears", "12", "Ripe"), ("Plums", "7", "")])
    merged = ("<w:tr>" + tc(p("Spans two columns"), col * 2, span=2, shd="FFF2CC") + tc(p("Last"), col) + "</w:tr>"
              + "<w:tr>" + tc(p("Vertical merge"), col, vmerge="restart") + tc(p("a"), col) + tc(p("b"), col) + "</w:tr>"
              + "<w:tr>" + tc(p(), col, vmerge="continue") + tc(p("c"), col) + tc(p("d"), col) + "</w:tr>")
    table = f"<w:tbl>{tblpr}{grid}{header}{rows}{merged}</w:tbl>"
    nested_inner = (f'<w:tbl>{tblpr}<w:tblGrid><w:gridCol w:w="1400"/><w:gridCol w:w="1400"/></w:tblGrid>'
                    "<w:tr>" + tc(p("in-1"), 1400) + tc(p("in-2"), 1400) + "</w:tr></w:tbl>")
    nested = (f'<w:tbl>{tblpr}<w:tblGrid><w:gridCol w:w="4680"/><w:gridCol w:w="4680"/></w:tblGrid>'
              "<w:tr>" + tc(p("Outer cell"), 4680) + tc(nested_inner + p(), 4680) + "</w:tr></w:tbl>")
    body = p("Tables", style="Heading1") + table + p("A nested table:") + nested + p("After the tables.")
    Package("Tables").write(out / "04-tables.docx", document(body))


def f05_images(out: Path):
    pkg = Package("Images")
    png_rid = pkg.media("image1.png", make_png(128, 96))
    jpg_rid = pkg.media("image2.jpeg", (HERE / "assets" / "photo.jpg").read_bytes())
    body = (p("Images", style="Heading1")
            + p("An inline PNG: ", inline_image(png_rid, 1, "Picture 1", 128, 96, "Blue checkerboard"), " in a sentence.")
            + p(inline_image(jpg_rid, 2, "Picture 2", 240, 160, "Colour gradient photo"), jc="center")
            + p("Caption: a JPEG centered on its own line.", jc="center"))
    pkg.write(out / "05-images.docx", document(body))


def hyperlink_ext(rid: str, text: str) -> str:
    return f'<w:hyperlink r:id="{rid}" w:history="1">{r(text, rStyle="Hyperlink")}</w:hyperlink>'


def f06_hyperlinks(out: Path):
    pkg = Package("Hyperlinks")
    a = pkg.rel("hyperlink", "https://example.com/", external=True)
    b = pkg.rel("hyperlink", "https://example.org/search?q=libretilla&lang=es", external=True)
    m = pkg.rel("hyperlink", "mailto:hello@example.com", external=True)
    body = (p("Hyperlinks", style="Heading1")
            + p("Visit ", hyperlink_ext(a, "example.com"), " for details.")
            + p("A URL with a query string: ", hyperlink_ext(b, "search"), ".")
            + p("Email: ", hyperlink_ext(m, "hello@example.com"))
            + p("Jump to the ", '<w:hyperlink w:anchor="target" w:history="1">' + r("bookmark", rStyle="Hyperlink") + "</w:hyperlink>", " below.")
            + page_break()
            + p('<w:bookmarkStart w:id="0" w:name="target"/>', r("Bookmarked paragraph."), '<w:bookmarkEnd w:id="0"/>'))
    pkg.write(out / "06-hyperlinks.docx", document(body))


def page_field() -> str:
    return ('<w:r><w:fldChar w:fldCharType="begin"/></w:r><w:r><w:instrText xml:space="preserve"> PAGE </w:instrText></w:r>'
            '<w:r><w:fldChar w:fldCharType="separate"/></w:r><w:r><w:t>1</w:t></w:r><w:r><w:fldChar w:fldCharType="end"/></w:r>')


def f07_header_footer(out: Path):
    pkg = Package("Header and footer")
    wml = "application/vnd.openxmlformats-officedocument.wordprocessingml"
    hid = pkg.rel("header", "header1.xml")
    fid = pkg.rel("footer", "footer1.xml")
    pkg.add("word/header1.xml", f"{XML_DECL}<w:hdr {ROOT_NS}>{p('Libretilla fixture — running header', style='Header', jc='right')}</w:hdr>",
            f"{wml}.header+xml")
    pkg.add("word/footer1.xml", f"{XML_DECL}<w:ftr {ROOT_NS}>{p('Page ', page_field(), style='Footer', jc='center')}</w:ftr>",
            f"{wml}.footer+xml")
    body = [p("Header and footer", style="Heading1")]
    for i in range(3):
        body += [p(sentence(i, 80)) for _ in range(3)]
        body.append(page_break())
    body.append(p("Last page."))
    pkg.write(out / "07-header-footer.docx", document("".join(body), sect_pr(header=hid, footer=fid, w=11906, h=16838)))


def f08_spanish(out: Path):
    body = (p("Libretilla de español", style="Title")
            + p("Introducción", style="Heading1")
            + p(r("¿Qué tal? ¡Muy bien! El niño comió piñata y jalapeños en Logroño.", lang="es-ES"))
            + p(r("Acentos: á é í ó ú Á É Í Ó Ú ü Ü ñ Ñ — comillas «latinas» y “inglesas”; ordinal 1.º y 2.ª; € 1.234,56.", lang="es-ES"))
            + p(r("Pingüino, cigüeña, vergüenza, año, señor, mañana, corazón, camión, árbol, éxito, búho.", lang="es-ES"))
            + p("Otros idiomas", style="Heading2")
            + p(r("Français : « Ça va ? » — garçon, élève, Noël. Deutsch: Größe, Straße, Übung. Português: ação, não.", lang="fr-FR"))
            + p(r("Emoji y símbolos: ✓ ★ → 😀 — fin.", lang="es-ES")))
    Package("Español con acentos y eñes").write(out / "08-spanish.docx", document(body))


def f09_large(out: Path):
    body = [p("A long document", style="Title")]
    para = 0
    for chapter in range(1, 41):
        body.append(p(f"Chapter {chapter}", style="Heading1"))
        for section in range(1, 4):
            body.append(p(f"Section {chapter}.{section}", style="Heading2"))
            for _ in range(8):
                para += 1
                body.append(p(sentence(para, 70), jc="both"))
        body.append(page_break())
    Package("Large document").write(out / "09-large.docx", document("".join(body)))


def f10_word_features(out: Path):
    """Content Libretilla v1 can't author but must round-trip intact (bootstrap §3, §7)."""
    pkg = Package("Word features")
    wml = "application/vnd.openxmlformats-officedocument.wordprocessingml"
    pkg.rel("footnotes", "footnotes.xml")
    pkg.rel("endnotes", "endnotes.xml")
    pkg.rel("comments", "comments.xml")
    sep = ('<w:footnote w:type="separator" w:id="-1"><w:p><w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/></w:pPr><w:r><w:separator/></w:r></w:p></w:footnote>'
           '<w:footnote w:type="continuationSeparator" w:id="0"><w:p><w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/></w:pPr><w:r><w:continuationSeparator/></w:r></w:p></w:footnote>')
    pkg.add("word/footnotes.xml", f"{XML_DECL}<w:footnotes {ROOT_NS}>{sep}"
            '<w:footnote w:id="1"><w:p><w:pPr><w:pStyle w:val="FootnoteText"/></w:pPr>'
            '<w:r><w:rPr><w:rStyle w:val="FootnoteReference"/></w:rPr><w:footnoteRef/></w:r>'
            '<w:r><w:t xml:space="preserve"> This is a footnote.</w:t></w:r></w:p></w:footnote></w:footnotes>',
            f"{wml}.footnotes+xml")
    esep = sep.replace("footnote", "endnote")
    pkg.add("word/endnotes.xml", f"{XML_DECL}<w:endnotes {ROOT_NS}>{esep}</w:endnotes>", f"{wml}.endnotes+xml")
    pkg.add("word/comments.xml", f"{XML_DECL}<w:comments {ROOT_NS}>"
            '<w:comment w:id="0" w:author="Reviewer" w:date="2026-01-01T00:00:00Z" w:initials="R">'
            '<w:p><w:pPr><w:pStyle w:val="CommentText"/></w:pPr><w:r><w:rPr><w:rStyle w:val="CommentReference"/></w:rPr><w:annotationRef/></w:r>'
            "<w:r><w:t>Please double-check this sentence.</w:t></w:r></w:p></w:comment></w:comments>",
            f"{wml}.comments+xml")
    # Custom XML part (as used by content-control data binding / document properties panes).
    pkg.add("customXml/item1.xml", f'{XML_DECL}<libretilla xmlns="urn:libretilla:fixture"><project>Libretilla</project></libretilla>')
    pkg.add("customXml/itemProps1.xml", f'{XML_DECL}<ds:datastoreItem ds:itemID="{{6C1B0E55-1D0B-4C55-9C1B-6A0C2E8F0001}}" '
            'xmlns:ds="http://schemas.openxmlformats.org/officeDocument/2006/customXml"><ds:schemaRefs/></ds:datastoreItem>',
            "application/vnd.openxmlformats-officedocument.customXmlProperties+xml")
    pkg.add("customXml/_rels/item1.xml.rels", f'{XML_DECL}<Relationships xmlns="{PKG_REL}">'
            f'<Relationship Id="rId1" Type="{REL}/customXmlProps" Target="itemProps1.xml"/></Relationships>')
    pkg.rel("customXml", "../customXml/item1.xml")

    footnote = ('<w:r><w:rPr><w:rStyle w:val="FootnoteReference"/></w:rPr><w:footnoteReference w:id="1"/></w:r>')
    comment = ('<w:commentRangeStart w:id="0"/>' + r("This sentence has a comment.") + '<w:commentRangeEnd w:id="0"/>'
               '<w:r><w:rPr><w:rStyle w:val="CommentReference"/></w:rPr><w:commentReference w:id="0"/></w:r>')
    tracked = ('<w:ins w:id="10" w:author="Reviewer" w:date="2026-01-01T00:00:00Z">' + r("inserted text") + "</w:ins>"
               '<w:del w:id="11" w:author="Reviewer" w:date="2026-01-01T00:00:00Z"><w:r><w:delText>deleted text</w:delText></w:r></w:del>')
    date_field = ('<w:r><w:fldChar w:fldCharType="begin"/></w:r><w:r><w:instrText xml:space="preserve"> DATE \\@ "yyyy-MM-dd" </w:instrText></w:r>'
                  '<w:r><w:fldChar w:fldCharType="separate"/></w:r><w:r><w:t>2026-01-01</w:t></w:r><w:r><w:fldChar w:fldCharType="end"/></w:r>')
    simple_field = '<w:fldSimple w:instr=" AUTHOR "><w:r><w:t>Libretilla fixture generator</w:t></w:r></w:fldSimple>'
    sdt = ('<w:sdt><w:sdtPr><w:alias w:val="Project name"/><w:tag w:val="project"/><w:id w:val="123456"/>'
           '<w:dataBinding w:xpath="/ns0:libretilla[1]/ns0:project[1]" w:prefixMappings="xmlns:ns0=\'urn:libretilla:fixture\'" '
           'w:storeItemID="{6C1B0E55-1D0B-4C55-9C1B-6A0C2E8F0001}"/><w:text/></w:sdtPr>'
           '<w:sdtContent><w:r><w:t>Libretilla</w:t></w:r></w:sdtContent></w:sdt>')
    textbox = ('<w:r><mc:AlternateContent><mc:Choice Requires="wps"><w:drawing>'
               '<wp:anchor distT="45720" distB="45720" distL="114300" distR="114300" simplePos="0" relativeHeight="251659264" '
               'behindDoc="0" locked="0" layoutInCell="1" allowOverlap="1"><wp:simplePos x="0" y="0"/>'
               '<wp:positionH relativeFrom="column"><wp:posOffset>3200400</wp:posOffset></wp:positionH>'
               '<wp:positionV relativeFrom="paragraph"><wp:posOffset>0</wp:posOffset></wp:positionV>'
               '<wp:extent cx="2286000" cy="685800"/><wp:effectExtent l="0" t="0" r="0" b="0"/><wp:wrapSquare wrapText="bothSides"/>'
               '<wp:docPr id="10" name="Text Box 10"/><wp:cNvGraphicFramePr/>'
               '<a:graphic><a:graphicData uri="http://schemas.microsoft.com/office/word/2010/wordprocessingShape">'
               '<wps:wsp><wps:cNvSpPr txBox="1"/><wps:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="2286000" cy="685800"/></a:xfrm>'
               '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:solidFill><a:srgbClr val="FFFFFF"/></a:solidFill>'
               '<a:ln w="9525"><a:solidFill><a:srgbClr val="000000"/></a:solidFill></a:ln></wps:spPr>'
               '<wps:txbx><w:txbxContent><w:p><w:r><w:t>Floating text box with square wrapping.</w:t></w:r></w:p></w:txbxContent></wps:txbx>'
               '<wps:bodyPr rot="0" vert="horz" wrap="square" lIns="91440" tIns="45720" rIns="91440" bIns="45720" anchor="t" anchorCtr="0"><a:spAutoFit/></wps:bodyPr>'
               '</wps:wsp></a:graphicData></a:graphic></wp:anchor></w:drawing></mc:Choice>'
               '<mc:Fallback><w:pict><v:shapetype id="_x0000_t202" coordsize="21600,21600" o:spt="202" path="m,l,21600r21600,l21600,xe">'
               '<v:stroke joinstyle="miter"/><v:path gradientshapeok="t" o:connecttype="rect"/></v:shapetype>'
               '<v:shape id="Text Box 10" o:spid="_x0000_s1026" type="#_x0000_t202" '
               'style="position:absolute;margin-left:252pt;margin-top:0;width:180pt;height:54pt;z-index:251659264;mso-wrap-style:square">'
               '<v:textbox><w:txbxContent><w:p><w:r><w:t>Floating text box with square wrapping.</w:t></w:r></w:p></w:txbxContent></v:textbox>'
               '<w10:wrap type="square"/></v:shape></w:pict></mc:Fallback></mc:AlternateContent></w:r>')
    two_col_break = sect_pr(cols=1, type_=None)  # end of section 1 (single column)
    body = (p("Word-only features", style="Heading1")
            + p("A footnote reference follows", footnote, ".")
            + p(comment)
            + p("Tracked changes: ", tracked, ".")
            + p("Today is ", date_field, " and the author is ", simple_field, ".")
            + p("Content control bound to custom XML: ", sdt, ".")
            + sdt.replace("<w:sdtContent><w:r><w:t>Libretilla</w:t></w:r></w:sdtContent>",
                          "<w:sdtContent>" + p("Block-level content control.") + "</w:sdtContent>")
                 .replace('<w:id w:val="123456"/>', '<w:id w:val="123457"/>')
                 .replace('<w:dataBinding w:xpath="/ns0:libretilla[1]/ns0:project[1]" w:prefixMappings="xmlns:ns0=\'urn:libretilla:fixture\'" w:storeItemID="{6C1B0E55-1D0B-4C55-9C1B-6A0C2E8F0001}"/><w:text/>', "")
            + p(textbox, sentence(5, 60))
            + p(r("x"), '<m:oMath><m:r><m:t>E=m</m:t></m:r><m:sSup><m:e><m:r><m:t>c</m:t></m:r></m:e><m:sup><m:r><m:t>2</m:t></m:r></m:sup></m:sSup></m:oMath>')
            + p("End of single-column section.", sect=two_col_break)
            + p("Two-column section", style="Heading2")
            + "".join(p(sentence(i, 60), jc="both") for i in range(6)))
    pkg.write(out / "10-word-features.docx", document(body, sect_pr(cols=2, type_="continuous")),
              extra_pkg_rels="")


FIXTURES = [f01_plain, f02_headings, f03_lists, f04_tables, f05_images, f06_hyperlinks, f07_header_footer,
            f08_spanish, f09_large, f10_word_features]


# New documents: A4 with Spanish-locale Word's margins (2.5 cm top/bottom, 3 cm sides), and Charter, a
# book serif in the spirit of Century Schoolbook and Kindle's Bookerly that ships with every Mac. The font
# table marks it as a proportional serif so Word on Windows (which lacks it) substitutes a serif.
BLANK_PAGE = dict(w=11906, h=16838, margins=(1417, 1701, 1417, 1701))
BLANK_FONT = "Charter"


def blank(out: Path):
    """The template every new Libretilla document starts from (Resources/Blank.docx)."""
    pkg = Package("", application="Libretilla", creator="")
    text_width = BLANK_PAGE["w"] - BLANK_PAGE["margins"][1] - BLANK_PAGE["margins"][3]
    pkg.styles = styles_xml(body_size=24, line=276, text_width=text_width)
    pkg.theme = theme_xml(major=BLANK_FONT, minor=BLANK_FONT)
    pkg.font_table = FONT_TABLE.replace(
        "</w:fonts>",
        f'<w:font w:name="{BLANK_FONT}"><w:charset w:val="00"/><w:family w:val="roman"/>'
        '<w:pitch w:val="variable"/></w:font></w:fonts>')
    pkg.write(out, document(p(), sect_pr(**BLANK_PAGE)))


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--out", type=Path, default=ROOT / "Fixtures" / "generated")
    args = ap.parse_args()
    for fn in FIXTURES:
        fn(args.out)
    blank(ROOT / "Resources" / "Blank.docx")
    for f in sorted(args.out.glob("*.docx")):
        print(f"{f.relative_to(ROOT) if f.is_relative_to(ROOT) else f}  {f.stat().st_size:>8} bytes")


if __name__ == "__main__":
    main()
