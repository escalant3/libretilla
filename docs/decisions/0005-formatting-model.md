# 0005. Formatting: Word properties are the truth, the display follows

- **Status:** Accepted (2026-11-04)
- **Deciders:** Claude Code (M2); review welcome

## Context

M2 adds formatting tools: the format bar, the Format menu, styles, lists and the ruler. Two things can change
how text looks:

1. **Cartilla's own commands** (Bold, Heading 1, Bulleted List, …).
2. **AppKit's own tools**, which edit the text view's display attributes directly: the Font panel, the ruler's
   indent and tab markers, pasting rich text, the Bigger/Smaller font commands.

Both have to end up as correct OOXML. They also have to stay lossless (ADR 0002): a `w:rPr` or `w:pPr` holds
things Cartilla doesn't model, such as `w14:*` effects, `w:lang`, `w:kern`, theme colours and `w:sectPr`.

Two other options were considered and rejected:

- **Derive the Word properties from the display at save time.** This loses information. A font that isn't
  installed (Calibri on many Macs) displays as the system font and would be saved as such. Bold in a family with
  no bold face would be lost. A change of paragraph style would also wipe direct formatting made with the Font
  panel.
- **Block AppKit's tools and allow only Cartilla's commands.** This means fighting native behaviour (bootstrap
  §1: "never fought"), and it loses the Font panel, the ruler and rich paste.

## Decision

- **The custom attributes are the truth.** Each run carries a `RunFormat` and each paragraph a `ParagraphFormat`.
  Both hold the parsed properties and the exact `w:rPr`/`w:pPr` bytes. They are immutable: a change replaces
  the object, and that is how a save knows a paragraph changed.
- **Commands change the truth, then redraw.** `AttributedStringBridge.apply(_:to:range:)` patches only the XML
  children for the changed field (`ElementPatch`, in schema order). It then recomputes the display from the
  style chain. A value equal to the inherited one removes the direct element instead of writing a redundant one.
  For example, un-bolding plain text removes `<w:b/>`, while un-bolding a heading writes `<w:b w:val="0"/>`.
- **Display changes from AppKit are reconciled.** An `NSTextStorageDelegate` runs `reconcile` on every edited
  range. It compares the display with what the formats predict and turns each difference into the same field
  change a command would make. It ignores fonts that AppKit swaps in for characters the run's font lacks (emoji,
  CJK). It is idempotent, and on an unedited document it's a no-op. This is tested on every corpus file, so
  opening a file never rewrites it.
- **Styles and lists are document data.** Applying a standard style the document lacks copies its definition
  from Cartilla's `Blank.docx`. Styles are found by Word's canonical names, so localized Word ids also work. New
  lists are appended to `numbering.xml`, which is created with its relationship and content type if missing.
  "Update Style to Match Selection" splices one `w:style` element. All other bytes of these parts are kept.
- **List markers are display only.** They're computed with Word's counting rules and drawn by TextKit 2 from
  `NSTextList`. They are never part of the text. Renumbering after an edit is not an undoable change and
  doesn't mark the document edited.

## Consequences

- Every formatting path (command, Font panel, ruler, paste, undo) converges on the same OOXML, and unchanged
  paragraphs keep their exact bytes.
- Applying a paragraph style keeps direct character formatting, as Word does. Format ▸ Clear Formatting (`⌘\`)
  removes it.
- Text inside links, fields and other opaque inlines can't be reformatted yet; commands skip it (M3 makes links
  editable).
- Copying and pasting inside Cartilla goes through RTF, so pasted text gets formats derived from its display:
  correct, though not byte-identical to the source run. A private pasteboard type would keep the exact
  `w:rPr` (later).
- TextKit 2 lays out list items by nesting depth, not by their indents (gap G4). Lists with non-standard indents
  display approximately but are saved exactly.
