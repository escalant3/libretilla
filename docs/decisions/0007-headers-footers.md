# 0007. Headers and footers: kept, printed, and edited in a sheet

- **Status:** Accepted (owner chose "header/footer basics" as a 1.0 gate and approved the Milestone 5 plan,
  2026-11-06)
- **Date:** 2026-11-06
- **Deciders:** owner, Claude

## Context

Until Milestone 5, headers and footers were parts Libretilla copied through untouched (ADR 0002). They were
kept, but they didn't print, and there was no way to add one. ADR 0002 recommended for 1.0: keep them, print
them, and edit them in a simple sheet, with inline editing in 1.1. The owner made "header/footer basics" a 1.0
gate.

What Word documents use (fixtures `07-header-footer.docx` and `14-headers-footers.docx`, real files):
- Three slots per section: default, first page (`w:titlePg`) and even pages (`w:evenAndOddHeaders` in
  `settings.xml`).
- References in each `w:sectPr`. A section without one inherits it from the section before.
- Page numbers as complex fields (`w:fldChar` begin … end around `PAGE`) or simple ones (`w:fldSimple`), often
  "Page X of Y" with `NUMPAGES`. Word's Page Number gallery wraps them in a block content control (`w:sdt`).
- The usual formatting: the Header and Footer styles' centre and right tab stops, alignment, sometimes a logo.

TextKit 2 has no header or footer area, and the editor shows one long column of text (ADR 0001).

## Options

1. **Sheet (recommended in ADR 0002).** Each header and footer is parsed like the body (`DocumentBody` reads
   `w:hdr` / `w:ftr`). Format ▸ Header and Footer… shows the header and footer in two text views, laid out by
   the same bridge, with a "Different first page" switch and buttons that insert page number and page count
   fields. Print and PDF draw them in the page margins.
   - Cost: moderate. It reuses the bridge's lossless write path, so a save rewrites only edited paragraphs.
   - Downside: you don't edit them on the page, and the editor doesn't show them.
2. **Inline editing in page margins.** Show each page's header and footer in the editor and type into them,
   as in Word and Pages.
   - Cost: high. The editor has no page model to hang them on; it means a second text view per page edge, kept in
     step with pagination.

## Decision

Option 1 for 1.0:

- **Model.** `HeadersFooters` holds the stories the last section uses, its own or inherited, by kind (header,
  footer) and slot (default, first, even). Unedited stories are written back byte for byte. A new story gets its
  part (`word/header1.xml`…), relationship, content-type override and `w:sectPr` reference on save. "Different
  first page" reads and writes the final section's `w:titlePg`.
- **Fields.** In header and footer stories, each `PAGE` / `NUMPAGES` / `SECTIONPAGES` field, simple or complex,
  becomes one opaque inline holding its markup. The sheet shows it as a chip ("Page number", "Page count"),
  printing shows the real number, and saving writes the same markup. New ones are `w:fldSimple`.
- **Print and PDF.** `PrintTextView.drawPageBorder` draws each page's header with its top at `w:pgMar`'s
  `w:header` distance below the page's top edge. The footer's bottom sits `w:footer` above the bottom edge.
  Both run across the text column. The first page uses the first-page story when `w:titlePg` is on, and even
  pages the even story when `w:evenAndOddHeaders` is on. A block content control's content prints as text.
  Anything else the bridge can't show prints as its chip.
- **Sheet.** The default pair, and with "Different first page" on, the first page's pair. Even-page stories are
  kept and printed but not edited; the sheet says so. Pasting is plain text. Done is one undo step. Cancel
  changes nothing.

## Consequences

- Headers and footers round-trip, print, and can be added or changed without Word.
- Libretilla uses the last section's headers and footers for the whole document, as it does for page setup. A
  document whose sections have different headers prints the last section's on every page; each section's own
  references are kept on save.
- Header text that is taller than the top margin overlaps the body in print. Word pushes the body down instead.
- The editor still doesn't show headers and footers. If that's what people miss first, option 2 is the 1.1 plan.
