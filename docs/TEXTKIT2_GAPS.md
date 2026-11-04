# TextKit 2 gap register

Cartilla uses TextKit 2 ([ADR 0001](decisions/0001-textkit.md)). This file lists everything we know TextKit 2
can't do yet, or does differently from TextKit 1 in ways that affect us. **The DOCX layer always preserves
the content.** These gaps are about editing and display only.

When you find a new gap, add a row and, if you can, a `testGap…` test in
`Tests/TextKit2CompatibilityTests.swift` that pins the current behaviour. When a gap test fails, TextKit 2 has
changed: re-check the gap, update its status, and remove any workaround that's no longer needed.

| ID | Gap | Impact on Cartilla | Workaround for now | Tracked by | Status |
|---|---|---|---|---|---|
| G1 | `NSTextTable` / `NSTextTableBlock` aren't laid out. There's no fallback either: cells stack as plain paragraphs, with no borders or columns | Tables (M3) display and print as a sequence of paragraphs | Preserve tables losslessly in the model. Options for later: custom `NSTextLayoutFragment` subclass for table rows, or an attachment-based table view | `testGapTablesAreNotLaidOut` (+ TK1 control) | Open (macOS 26.5) |
| G2 | `NSTextLayoutManager` has one `textContainer`. With a page-sized container, layout fills that page and stops: the rest of the text is never placed, and nothing flows it into a next container the way TextKit 1 does | v1.1 paginated page view | M1–v1.0 use a continuous page-width column; printing paginates fine. For v1.1: chain one layout manager/container per page starting where the previous page ended, or lay out one tall container and slice it into pages ourselves | `testGapNoFlowIntoNextPageContainer` | Open; needed for v1.1 |
| G3 | Any access to `NSTextView.layoutManager` permanently switches the view to TextKit 1 | Any of our code or a third-party API that touches it silently changes engine | Never use TK1 APIs; `EditorViewController` logs a fault on fallback | `testTextKit1AccessorForcesFallback` | By design (rule) |

## To verify (unknown, check when the feature is built)

- `NSRulerView` indent and tab markers with a TK2 text view (M2)
- Paragraph-style indents, line spacing and space before/after round-trip (M2)
- Inline images through `NSTextAttachment` / `NSTextAttachmentViewProvider` (M3)
- Page-break rendering in the continuous view, and in print/PDF (M3)
- Find bar, spell check and autocorrect on large documents (M2)
- VoiceOver navigation and the heading rotor (M4)
