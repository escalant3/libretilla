# Backlog

Smaller items collected from [`STATUS.md`](STATUS.md) (2026-11-09). Release work and the Microsoft Word check are
tracked there, not here. Numbers are stable references; don't renumber when items are done, tick them instead.

## Page and layout

- [x] 1. Margins have no editor. Page Setup only does paper size and orientation. *Done: File ▸ Margins….*
- [x] 2. No Paragraph… dialog for exact spacing and indent values. *Done: Format ▸ Paragraph… (⌥⌘M).*
- [x] 3. Multi-section documents use the last section's page setup everywhere. *Done for print and PDF: each
      section has its own paper, orientation and margins. The editor still shows, and Page Setup and Margins still
      edit, the final section's.*
- [x] 4. The space below the last line equals the top margin (TextKit's inset is symmetric). *Done: it's the
      bottom margin.*
- [x] 5. Superscript and subscript display at full size. *Done: drawn at ⅔ size, as in Word.*
- [x] 6. Lists with unusual indents look approximate (TextKit 2 gap G4). They save exactly. *Done: no
      `NSTextList`; list paragraphs keep their Word indents and the marker is drawn in front.*
- [ ] 32. The editor shows the final section's page setup for the whole document, and Page Setup and Margins
      edit only the final section (print and PDF follow each section since 3). *Partly done: sections laid out
      like the final one now follow its changes, so documents whose sections share a setup stay consistent.
      Editing a section with its own setup (e.g. a landscape one) still needs a design decision: show and edit
      the section at the caret, or offer "Apply to: whole document / this section" as Word does.*
- [ ] 33. Manual look at the Margins and Paragraph sheets in the running app (only unit-tested so far).

## Headers and footers

- [x] 7. A multi-section document prints the last section's headers and footers on every page. *Done: each
      section prints its own or inherited ones, with its own `w:titlePg`. The sheet still edits only the final
      section's (see 32).*
- [x] 38. Page numbers in headers and footers ignore `w:pgNumType` (a section restarting its numbering, or
      numbering in roman numerals), and `SECTIONPAGES` shows the document's page count. *Done for `w:pgNumType`:
      sections restart or continue their numbering in their own format, and the page's number picks odd or even
      headers, as in Word. `SECTIONPAGES` still shows the document's page count.*
- [x] 8. A header taller than the top margin overlaps the body instead of pushing it down. *Done: the tallest
      header (footer) of a section moves its top (bottom) margin, unless the margin is negative ("exactly").
      Word does it page by page; Libretilla per section.*
- [x] 9. Even-page headers and footers can't be edited in the sheet. *Done for documents that have them: the
      sheet switches between First, Odd and Even Pages.*
- [x] 40. The Header and Footer sheet can't turn odd and even pages on or off (`w:evenAndOddHeaders` in the
      settings part). *Done: "Different odd and even pages"; the settings part changes only by that element.*
- [ ] 10. The editor doesn't show headers and footers inline; they're edited only in the sheet (deliberate, ADR 0007).

## Pictures

- [ ] 11. Floating pictures (`wp:anchor`) show inline, with no text wrapping.
- [x] 12. Pictures are formatted from a sheet, with no drag handles. *Done: a selected picture shows eight
      handles (corners scale it, edges stretch it; a rotated picture has corners only), previewed while dragging
      and applied as one Format Picture step. Unit-tested; not yet tried with a real mouse.*
- [x] 13. Copying a picture within Libretilla saves the copy as a new image. *Done within one document: the
      copy is another drawing of the same image part, with a new unique drawing id.*
- [ ] 14. Word 2010's newer brightness/contrast extension (`a14:imgEffect`) isn't read. *Needs a file from real
      Word first: the main picture may already have the effect applied (the layer holds the original), in which
      case drawing it again would apply it twice.*

## Tables

- [ ] 15. No typing straight into cells; the sheet edits them.
- [ ] 16. Find, spell check and VoiceOver don't see cell text. *Partly done: each table row's picture is described
      by its cells' text ("Apples, 3, Green"), as chips are by their labels; not yet tried with VoiceOver. Find
      and spell check still don't see it.*
- [x] 17. Banded rows and first-row shading from table styles (`w:tblStylePr`) aren't drawn. *Done: the
      conditional formats `w:tblLook` turns on (header and last rows, first and last columns, row and column bands,
      corner cells) give cells their shading, borders and bold, italic and colour, under the cell's own.*
- [x] 18. Nested tables show as one line of text per row. *Done: drawn as tables in their cells (the cell
      editor still shows a line per row, and such cells can't be edited, see 21).*
- [x] 19. A vertically merged cell's text sits in its first row. *Done: it flows down its rows, which grow at
      the bottom if needed, as in Word; each row draws only its own lines. Cell vertical alignment (`w:vAlign`)
      isn't read.*
- [x] 20. A table keeps its width after a page setup change until the document is reopened. *Done: tables
      are redrawn for the new text width (display only). Undoing an edit made before the change can bring back
      a table drawn at the old width until the next page setup change.*
- [ ] 21. Cells containing links, images or nested tables can't be edited in the sheet.

## Text, links and paste

- [ ] 22. Text inside fields and content controls can't be reformatted. Links containing fields, bookmarks or
      tracked changes stay opaque. *Partly done: fields, content controls, such links and tracked insertions
      can be reformatted, whole (bold, font, colour, … on every run inside; nothing else in their XML changes).
      Their text still can't be edited, and part of one can't be formatted on its own.*
- [x] 23. Copy and paste inside Libretilla goes through RTF, so pasted formats are derived from their look, and
      links and objects paste as plain text. *Done within one document, for text and pictures: the paste keeps
      the Word paragraph and run formats, styles, links and list numbering (new paragraphs and links; bookmarks
      and comment ranges stay put). Copies with fields, tables or chips, and pastes into another document, still
      go through RTF.*
- [x] 34. Copied list items lose their markers until the list is renumbered (the marker attribute doesn't survive
      RTF). *Done within one document (see 23).*
- [ ] 24. Footnotes, comments, text boxes and equations are placeholder chips that can't be edited. *Partly
      done for print: footnotes print at the foot of their reference's page (pages end early to fit them), and
      endnotes after the last paragraph, as in Word. A note too long for one page isn't continued on the next.
      In the editor they're still chips.*

## Print and PDF

- [x] 25. The text of a paragraph that starts a new page also appears in the previous page's PDF text (search,
      copy, accessibility see it). *Done: it was any paragraph split across pages too (a page's PDF text held
      the whole paragraph). Printing now draws each page's own lines.*
- [x] 26. The page-break-before mark is set when the document opens; changing a paragraph's style doesn't affect
      printing until the document is reopened. *Done: restyling a paragraph updates the mark.*
- [x] 27. Placeholder chips print into PDFs as they look in the editor. *Done where Libretilla knows what Word
      prints: footnote and endnote references print their numbers (1, 2, … and i, ii, …), text boxes their text on a
      line of its own, comments nothing, and block content controls their paragraphs. Equations, objects and symbols
      still print as chips. Footnote text is printed too (see 24).*
- [x] 39. Print and PDF swapped the top and bottom margins: AppKit placed each page `bottomMargin` below the
      paper's top edge (any text view, macOS 26). Invisible with equal margins. *Done:
      `PrintTextView.locationOfPrintRect`.*

## Dark Mode and accessibility

- [x] 28. Text inside tables, chips and pictures isn't recoloured on a dark page. *Done for tables (text and
      automatic borders made readable; text on a light cell fill stays dark) and chips (no longer cached in one
      appearance). Pictures show as they are, as in Word.*
- [ ] 29. No real VoiceOver session yet; only the rotor unit test and the audit.
- [ ] 30. Manual look at the colour well popover, the highlight menu and the font popup with uninstalled fonts.
- [x] 35. List markers aren't recoloured on a dark page (they're drawn outside TextKit's rendering attributes).
      *Done: a marker takes the rendering colour of the text it gets its colour from.*

## Infrastructure

- [ ] 31. CI is disabled, and `testFindAndReplaceAll` fails only on the runner. Re-enable with
      `gh workflow enable CI`.
- [x] 36. `PictureCommandTests` crash now and then (EXC_BAD_ACCESS in `NSTextAttachment` drawing). Seen before
      2026-11-09's backlog work too. *Done: tests left documents open, which went with their test while their
      windows stayed; AppKit's window controller doesn't retain its document, so validating the toolbar (or drawing
      the window when a sheet put windows on screen) read freed objects. The window controller now holds its
      document weakly and every test closes what it opens. Four suite runs in a row: no crashes.*
- [x] 37. UI tests weren't run after backlog 1–6 (the app couldn't be activated in the agent's session), and the
      last attempt's accessibility audit reported "Contrast failed". Run them locally and check. *Done
      (2026-11-11): all 18 UI tests pass, the accessibility audit included.*

## Suggested starting points

- 25 and 26: small, self-contained bugs.
- 37 and 36: confirm the test suites are green after backlog 1–6.
- 15, 16 and 17: one larger "tables" milestone.
