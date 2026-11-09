# Fixture corpus

Test inputs for the DOCX codec and the round-trip suite (bootstrap §7).
**Add a fixture for every fidelity bug fixed.**

## `generated/`: committed, reproducible

| File | Producer | Exercises |
|---|---|---|
| `01-plain.docx` | `make_corpus.py` | Normal text; bold/italic/underline/strike/colour/highlight/super/subscript; explicit font + size; alignment ×4; line spacing, space before/after; left, first-line and hanging indents; tabs and double spaces (`xml:space="preserve"`) |
| `02-headings.docx` | `make_corpus.py` | Title, Subtitle, Heading 1–6 (`w:pStyle`, `outlineLvl`), Quote, a "Source Code" monospace style, and a full `styles.xml` with docDefaults |
| `03-nested-lists.docx` | `make_corpus.py` | `numbering.xml`: 3-level bullets and decimal/letter/roman, list restart through `lvlOverride` |
| `04-tables.docx` | `make_corpus.py` | Table Grid style, repeating header row, cell shading, right-aligned cells, `gridSpan`, `vMerge`, nested table |
| `05-images.docx` | `make_corpus.py` | Inline PNG and JPEG (`wp:inline`, `a:blip r:embed`), alt text |
| `06-hyperlinks.docx` | `make_corpus.py` | External links (with query string, mailto), internal anchor link plus bookmark, page break |
| `07-header-footer.docx` | `make_corpus.py` | Default header and footer, PAGE field, A4 page size, multiple pages |
| `08-spanish.docx` | `make_corpus.py` | Accents, ñ, ¿¡, «», “”, ordinals, €, French/German/Portuguese, emoji, `w:lang` |
| `09-large.docx` | `make_corpus.py` | ~67 500 words and 161 pages in Pages: 40 chapters, 120 sections |
| `10-word-features.docx` | `make_corpus.py` | Content Libretilla doesn't author but must preserve: footnotes/endnotes, comments, tracked insert/delete, complex and simple fields, inline and block `w:sdt` bound to a custom XML part, floating text box (`mc:AlternateContent` with a VML fallback), OMML equation, continuous section break into 2 columns |
| `11-pandoc.docx` | `make_pandoc.sh` (pandoc 3.12) | Markdown → DOCX in pandoc's own markup style: lists, table, image, code, footnote, link |
| `12-pages.docx` | Pages 14.5 export of `11-pandoc.docx` (`pages_roundtrip.applescript`) | Apple Pages' DOCX writer output. **Not** reproducible byte-for-byte, so regenerate it only on purpose |
| `13-page-break-before.docx` | `make_corpus.py` | `w:pageBreakBefore` set directly and through a `basedOn` style chain, and turned off (`w:val="0"`, `"false"`, a derived style); prints on 4 pages |
| `14-headers-footers.docx` | `make_corpus.py` | First-page (`w:titlePg`), even (`w:evenAndOddHeaders`) and default headers and footers; "Page X of Y" from a complex `PAGE` and a simple `NUMPAGES` field; a page number inside a block `w:sdt` (Word's Page Number gallery); prints on 5 pages |
| `15-sections.docx` | `make_corpus.py` | Four sections with their own `w:pgSz`/`w:pgMar`: Letter portrait, Letter landscape, a `continuous` section on the same page, and an A4 `evenPage` section (a blank page before it); a PAGE footer; prints on 4 pages |

Regenerate: `python3 scripts/fixtures/make_corpus.py && scripts/fixtures/make_pandoc.sh`.
The output is deterministic, so a rerun must leave `git status` clean.

`make_corpus.py` imitates Word 2016+ markup: same namespaces, part layout, style ids and element order.
It is still synthetic. It doesn't replace real files written by the applications below.

## `real/`: TODO, supplied by a human

The bootstrap requires files written by real applications. None of them are installed on the dev machine.
Drop files in these folders. Use short kebab-case names and add a row here.

- [ ] `real/word/`: Word for Mac/Windows. One general document, plus one each with: columns, a text box or floating image, footnotes, comments, track changes, fields (TOC/PAGE/DATE), header/footer.
- [ ] `real/libreoffice/`: LibreOffice Writer, saved as "Word 2007–365 (.docx)".
- [ ] `real/googledocs/`: Google Docs, File ▸ Download ▸ Microsoft Word.
- [x] Pages: `generated/12-pages.docx`.

Only use documents you have the right to publish in an MIT repo. Avoid personal data.
