# 0008. Typing into table cells: an in-place cell editor over the drawn table

- **Status:** Proposed (built 2026-11-11 at the owner's request to fix backlog 15; owner to confirm)
- **Date:** 2026-11-11
- **Deciders:** owner, Claude

## Context

ADR 0006 draws each table row as one picture and edits cells in a sheet. It noted that if typing straight into
cells mattered, option 2 (a custom TextKit 2 layout for rows) would be the plan, at a cost of weeks and a real risk
of dead ends (caret movement, selection and hit-testing across cells). The owner asked for typing into cells.

## Decision

Keep ADR 0006's model (a table is one opaque block, drawn as row pictures, written back by splicing only what
changed) and add an **in-place cell editor**: a click in a cell opens a text view laid exactly over that cell's
text, holding the cell's paragraphs as a small story (parsed and written by the bridge, like a header's).

- Each change is written into the table's XML at once and the table redrawn, so the row grows as you type and any
  save has the text. No undo step is registered while typing; the cell editor has its own undo. Leaving the table
  (a click elsewhere, Escape, Tab past the last cell) puts the table back and replaces it with the final XML as one
  undoable "Typing" step.
- Tab and Shift-Tab move between cells. Formatting commands and the format bar act on the cell while it's open;
  inserting tables, pictures, links or page breaks is disabled there (new parts and relationships aren't resolved
  inside a table's XML).
- The editor shows each paragraph with the spacing the table style gives it, through the text content storage's
  delegate (display only), so it lines up exactly with the drawn row.
- Cells holding a nested table or other blocks, and the continuations of vertical merges, aren't typed into; the
  Edit Table sheet still edits structure (rows, columns).

## Consequences

- Typing into cells works like Word for text and character and paragraph formatting, with spell check in the cell.
- Find still doesn't search tables, and the caret can't move into a table with the arrow keys (a click or the sheet
  opens it). Selections can't span cells.
- Option 2 of ADR 0006 is no longer needed for typing; it would still be the route to find, arrow keys and
  cross-cell selection.
