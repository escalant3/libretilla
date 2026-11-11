# 0006. Tables: drawn row attachments with a cell editor sheet (TextKit 2 can't lay out tables)

- **Status:** Accepted (owner chose option 1, 2026-11-04); typing into cells added by [0008](0008-typing-in-table-cells.md)
- **Date:** 2026-11-04
- **Deciders:** owner, Claude

## Context

Tables are the last Milestone 3 feature. Today each `w:tbl` is kept byte for byte and shows as one placeholder
line ("Table, 3 × 4: …"); it prints as that line too. For real documents this is the most visible gap left.

TextKit 2 doesn't lay out `NSTextTable` / `NSTextTableBlock` (gap G1, `testGapTablesAreNotLaidOut`): cells stack
as plain paragraphs, with no columns or borders, and no fallback. ADR 0001 chose TextKit 2 and forbids anything
that forces TextKit 1 (G3).

What Word tables need, from the corpus (`04-tables.docx`) and real files: a column grid (`w:tblGrid`), horizontal
spans (`w:gridSpan`), vertical merges (`w:vMerge`), borders from the table style or `w:tblBorders`, cell shading,
header rows, formatted text in cells, and sometimes images or nested tables in cells. Long tables must break
across pages between rows.

## Options

1. **Drawn row attachments + cell editor sheet (recommended).** Each table row shows as one attachment the width
   of the text column, drawn by Libretilla from the model: grid, spans, merges, borders, shading, and the cell
   paragraphs through the bridge (so fonts, bold, colours and alignment show). Rows are separate lines, so print and
   PDF paginate between rows as Word does. Double-clicking a table (or Format ▸ Table…) opens a sheet with the
   cells in a grid of text fields, plus add/remove row and column. Saving rewrites only the cells that changed; a
   cell with content the sheet can't edit (images, nested tables, fields) is shown and kept as it is.
   - Cost: moderate (a table renderer, the sheet, cell-level writing). Low risk: only public, stable APIs.
   - Downside: you don't type straight into a cell on the page; editing happens in the sheet. Find, spell check
     and VoiceOver don't see text inside tables until it's opened in the sheet.

2. **Custom TextKit 2 layout for rows.** Cell text stays in the text storage; a custom `NSTextLayoutFragment`
   lays a row's cells side by side and draws borders. Typing happens in place, as in Word, and find and spell
   check work in cells.
   - Cost: high and uncertain. Caret movement, selection, hit-testing and arrow keys across cells all need custom
     handling that TextKit 2 doesn't document. Weeks, with a real risk of dead ends.

3. **TextKit 1 for documents that contain tables.** `NSTextTable` works in TextKit 1, with in-place editing and
   printing.
   - Cost: two text engines. Everything built for TextKit 2 (lists, G4, the ruler, page geometry) would need
     testing on both; it reverses ADR 0001 for exactly the documents most likely to come from Word.

## Decision

Option 1 now, for Milestone 3: tables display and print correctly, and their text is editable through the sheet,
losslessly. Revisit option 2 for v1.1 if typing straight into cells turns out to matter in real use.

## Consequences

- Tables look right on screen, in print and in PDFs; long tables split between rows.
- Table editing is less direct than in Word. If that's the first thing people miss, option 2 becomes the v1.1 plan.
- The renderer is a second place that draws text (inside cells); it must use the bridge's attributes so cells match
  the body.
- Gap G1 stays open; this ADR is the workaround it points to.
