# Backlog

Smaller items collected from [`STATUS.md`](STATUS.md) (2026-11-09). Release work and the Microsoft Word check are
tracked there, not here. Numbers are stable references; don't renumber when items are done, tick them instead.

## Page and layout

- [ ] 1. Margins have no editor. Page Setup only does paper size and orientation.
- [ ] 2. No Paragraph… dialog for exact spacing and indent values.
- [ ] 3. Multi-section documents use the last section's page setup everywhere.
- [ ] 4. The space below the last line equals the top margin (TextKit's inset is symmetric).
- [ ] 5. Superscript and subscript display at full size.
- [ ] 6. Lists with unusual indents look approximate (TextKit 2 gap G4). They save exactly.

## Headers and footers

- [ ] 7. A multi-section document prints the last section's headers and footers on every page.
- [ ] 8. A header taller than the top margin overlaps the body instead of pushing it down.
- [ ] 9. Even-page headers and footers can't be edited in the sheet.
- [ ] 10. The editor doesn't show headers and footers inline; they're edited only in the sheet (deliberate, ADR 0007).

## Pictures

- [ ] 11. Floating pictures (`wp:anchor`) show inline, with no text wrapping.
- [ ] 12. Pictures are formatted from a sheet, with no drag handles.
- [ ] 13. Copying a picture within Libretilla saves the copy as a new image.
- [ ] 14. Word 2010's newer brightness/contrast extension (`a14:imgEffect`) isn't read.

## Tables

- [ ] 15. No typing straight into cells; the sheet edits them.
- [ ] 16. Find, spell check and VoiceOver don't see cell text.
- [ ] 17. Banded rows and first-row shading from table styles (`w:tblStylePr`) aren't drawn.
- [ ] 18. Nested tables show as one line of text per row.
- [ ] 19. A vertically merged cell's text sits in its first row.
- [ ] 20. A table keeps its width after a page setup change until the document is reopened.
- [ ] 21. Cells containing links, images or nested tables can't be edited in the sheet.

## Text, links and paste

- [ ] 22. Text inside fields and content controls can't be reformatted. Links containing fields, bookmarks or
      tracked changes stay opaque.
- [ ] 23. Copy and paste inside Libretilla goes through RTF, so pasted formats are derived from their look, and
      links and objects paste as plain text.
- [ ] 24. Footnotes, comments, text boxes and equations are placeholder chips that can't be edited.

## Print and PDF

- [ ] 25. The text of a paragraph that starts a new page also appears in the previous page's PDF text (search,
      copy, accessibility see it).
- [ ] 26. The page-break-before mark is set when the document opens; changing a paragraph's style doesn't affect
      printing until the document is reopened.
- [ ] 27. Placeholder chips print into PDFs as they look in the editor.

## Dark Mode and accessibility

- [ ] 28. Text inside tables, chips and pictures isn't recoloured on a dark page.
- [ ] 29. No real VoiceOver session yet; only the rotor unit test and the audit.
- [ ] 30. Manual look at the colour well popover, the highlight menu and the font popup with uninstalled fonts.

## Infrastructure

- [ ] 31. CI is disabled, and `testFindAndReplaceAll` fails only on the runner. Re-enable with
      `gh workflow enable CI`.

## Suggested starting points

- 25 and 26: small, self-contained bugs.
- 1 and 2: the dialogs people will miss first.
- 15, 16 and 17: one larger "tables" milestone.
