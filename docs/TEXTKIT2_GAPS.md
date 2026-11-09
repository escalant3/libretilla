# TextKit 2 gap register

Libretilla uses TextKit 2 ([ADR 0001](decisions/0001-textkit.md)). This file lists everything we know TextKit 2
can't do yet, or does differently from TextKit 1 in ways that affect us. **The DOCX layer always preserves
the content.** These gaps are about editing and display only.

When you find a new gap, add a row and, if you can, a `testGap…` test in
`Tests/TextKit2CompatibilityTests.swift` that pins the current behaviour. When a gap test fails, TextKit 2 has
changed: re-check the gap, update its status, and remove any workaround that's no longer needed.

| ID | Gap | Impact on Libretilla | Workaround for now | Tracked by | Status |
|---|---|---|---|---|---|
| G1 | `NSTextTable` / `NSTextTableBlock` aren't laid out. There's no fallback either: cells stack as plain paragraphs, with no borders or columns | Tables (M3) display and print as a sequence of paragraphs | Tables are drawn from the model as one attachment per row, and edited in a cell editor sheet ([ADR 0006](decisions/0006-tables.md)). A custom `NSTextLayoutFragment` for rows (typing in cells) is the v1.1 option | `testGapTablesAreNotLaidOut` (+ TK1 control) | Open (macOS 26.5) |
| G2 | `NSTextLayoutManager` has one `textContainer`. With a page-sized container, layout fills that page and stops: the rest of the text is never placed, and nothing flows it into a next container the way TextKit 1 does | v1.1 paginated page view | M1–v1.0 use a continuous page-width column; printing paginates fine. For v1.1: chain one layout manager/container per page starting where the previous page ended, or lay out one tall container and slice it into pages ourselves | `testGapNoFlowIntoNextPageContainer` | Open; needed for v1.1 |
| G3 | Any access to `NSTextView.layoutManager` permanently switches the view to TextKit 1 | Any of our code or a third-party API that touches it silently changes engine | Never use TK1 APIs; `EditorViewController` logs a fault on fallback | `testTextKit1AccessorForcesFallback` | By design (rule) |
| G4 | List paragraphs (`NSParagraphStyle.textLists`) ignore `headIndent` and `firstLineHeadIndent`. TK2 places the marker and text itself, indenting by nesting depth (`textLists.count`), about 36 pt per level | Word lists with non-standard indents couldn't be shown at their exact position | No `NSTextList` for display: list paragraphs keep their Word indents (first line at the text after the marker, Word's tab rule), carry a `ListMarker` (`.libretillaListMarker`), and `ListMarkerLayout`, the text layout managers' delegate, draws the marker in a custom layout fragment at the hanging indent. Markers aren't recoloured on a dark page, and RTF copies don't carry them | `testGapListParagraphsIgnoreTheirIndents`, `nestedListMarkersFollowWordNumbering` (package), `testListMarkersPrintAtWordsIndents` | Worked around (macOS 26.5) |
| G5 | The ruler's right-indent marker ignores a horizontal `textContainerInset` (AppKit ruler, seen with TK2): it sits, and drags, `inset` points too far left | A ruler indent drag would set the wrong right indent | No horizontal inset: the text view is the page's text column, and `PageCanvasView` draws the page and margins. `lineFragmentPadding` is 0, so text starts at the margin as in Word | `RulerTests` | Worked around |

## Verified

- `NSRulerView` indent and tab markers with a TK2 text view work without a TK1 fallback (M2). AppKit's ruler
  accessory row is removed (it duplicates the format bar, and its list popup isn't Word numbering). See G5.
- Paragraph-style indents, tab stops, line spacing and space before/after are displayed by TK2, and survive a
  round trip through the ruler and the bridge (M2, `FormattingTests`).
- `NSTextList` markers are drawn by TK2 outside the text (`NSTextList.includesTextListMarkers` is false). Literal
  marker formats such as `2.3.` or `◦` show as given (M2). Libretilla no longer uses them for display: see G4.
- `.superscript` is honoured by TK2 (raised, full size, as in TextEdit). The bridge draws super- and subscript
  text at ⅔ size itself (`AttributedStringBridge.scriptScale`).
- Marked text (dead keys, input methods) doesn't leave formatting behind (`testDeadKeysAndInputMethodsDoNotLeaveFormatting`).
- Find and Replace through the find bar (`testFindAndReplaceAll`).
- Rendering attributes (`NSTextLayoutManager.renderingAttributesValidator`) recolour text for display without
  touching the storage: the dark page draws dark Word colours lighter (M4, `testDarkModeDoesNotChangeTheDocument`).
- A custom heading rotor (`NSAccessibilityCustomRotor`) on the TK2 text view reaches each heading by its range (M4).

## To verify (unknown, check when the feature is built)

- Inline images through `NSTextAttachment` / `NSTextAttachmentViewProvider` (M3)
- Page-break rendering in the continuous view, and in print/PDF (M3)
- Find bar, spell check and autocorrect speed on large documents (bridge work per keystroke is under 0.1 ms on
  `09-large.docx`; the text view itself hasn't been profiled)
- VoiceOver navigation with a real VoiceOver session: the heading rotor is unit-tested and the window passes
  XCTest's accessibility audit, but nobody has driven it with VoiceOver yet (M4)
- Tables, chips and pictures on a dark page: they're attachments, so the rendering-attribute recolouring doesn't
  reach the text drawn inside them (M4)
