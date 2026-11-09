# Status

## Milestone 0: Spike ✅ (2026-11-04)

**Done**

- Repo skeleton: XcodeGen `project.yml` plus the committed `Libretilla.xcodeproj`. arm64-only, macOS 26, Swift 6,
  sandboxed (user-selected read-write + app-scoped bookmarks), hardened runtime (Release), EN/ES string catalog.
- App shell: programmatic standard menus, stub autosave-in-place `NSDocument` that declares the `.docx` type,
  page-width text view on a gray canvas. Unit tests and a UI launch smoke test pass.
- `Packages/LibretillaDocx`: the `DocxCodec` protocol, a placeholder `DocxDocument` model, and ZIPFoundation 0.9.20
  (MIT, approved) with a smoke test that reads a fixture.
- Fixture corpus: 10 generated Word-style files, plus one from pandoc and one exported from Pages.
  Reproducible, and checked by CI.
- SwiftDocX evaluation ([archived results](decisions/0002-swiftdocx-evaluation.md); spike code removed, see
  commit `09ad587`) and TextKit comparison.
- ADRs **accepted**: [0001 TextKit 2 + gap register](decisions/0001-textkit.md) ([gaps](TEXTKIT2_GAPS.md)),
  [0002 own lossless OOXML codec, built incrementally](decisions/0002-docx-library.md).
- Editor uses an explicit TextKit 2 `NSTextView` and logs a fault if anything forces a TextKit 1 fallback.
  `Tests/TextKit2CompatibilityTests.swift` pins the known gaps.
- Repo on GitHub: [escalant3/libretilla](https://github.com/escalant3/libretilla). CI is green on the `macos-26`
  runner (Xcode 26.6, arm64); a full run takes about 1.5 minutes.

**Decided with the human:** minimum macOS 26; sandboxed; generated corpus with real-app slots left as TODOs;
private GitHub repo; TextKit 2 with tracked gaps (fix them late in the project); no SwiftDocX, build our own
DOCX layer gradually; unnamed documents are system drafts until named (ADR 0003); private backup copy of originals plus Versions (ADR 0004).

## Waiting on the human

- [x] Header/footer in 1.0 or 1.1: basics in 1.0 (kept, printed, edited in a sheet), inline editing later
      (ADR 0007, 2026-11-06).
- [ ] Sparkle yes/no; domain and website host.
- [ ] Real fixture files for `Fixtures/real/{word,libreoffice,googledocs}` (see `Fixtures/README.md`).
- [ ] Placeholder bundle id `app.libretilla.Libretilla`; confirm, or choose one tied to the domain.
- [x] Copyright line in `LICENSE` ("Diego Escalante (escalant3)"): confirmed by the owner, 2026-11-06.
- [ ] **Later (deferred by the owner, 2026-11-04):** open Libretilla-written files in Microsoft Word and report any
      repair prompt. Word isn't installed on the dev machine for now. Priority files: one with a new list
      (`numbering.xml` created from scratch), one with a style Libretilla copied in, and a few edited corpus files.

## Milestone 1: Skeleton ✅ (2026-11-04)

**Done**

- `LibretillaDocx` codec (ADR 0002):
  - `OPCPackage` copies every part through untouched.
  - `RawXML` is a byte-range-preserving XML reader.
  - Paragraphs and runs are modelled; everything else is kept verbatim as opaque blocks or inlines.
  - An unedited document writes back its exact original bytes.
- `AttributedStringBridge` (TextKit 2) shows styles, theme fonts, run formatting, alignment, indents and
  spacing.
  - Links and fields show as text.
  - Images, footnotes, text boxes and equations show as placeholder chips; tables as a placeholder line.
  - Only edited paragraphs are re-serialized.
- Persistence (§5.4, ADRs 0003/0004):
  - Autosave in place 3 s after typing, written asynchronously from a main-thread snapshot.
  - No edited dot; a Saved/Edited/Saving…/Couldn't save/Read-only status sits beside the title.
  - Unnamed documents are system drafts.
  - A private copy of each opened original is kept for 30 days (File ▸ Restore Original…).
- Toolbar stub (New, Open, Print, Undo, Redo); printing through a TextKit 2 view.
- Tests:
  - 24 codec/bridge tests over the 12-file corpus: byte-identical round trip, full re-serialization,
    edits touch only the edited paragraph, Word-only features survive.
  - 17 app unit tests.
  - 6 UI tests: autosave to the real file; an untouched file is unchanged (bytes and mtime); quit with no
    prompt; `kill -9` loses only the last seconds; the unnamed-draft sheet.
- Manual check: every fixture, edited by the codec, opens in Pages 14.5 and pandoc.

**Not yet verified:** opening Libretilla-written files in **Microsoft Word**. Deferred; see "Waiting on the human".

**Known M1 limitations (planned)**

- No formatting UI yet (M2). Typed text takes the formatting of the run it's typed into.
- Links, fields, content controls and objects can be deleted whole but not edited inside (M3).
- Tables show as a placeholder line. TextKit 2 can't lay them out (gap G1), and table editing is M3.

## Milestone 2: Formatting ✅ (2026-11-04)

**Done** (design: [ADR 0005](decisions/0005-formatting-model.md))

- **Format bar** under the toolbar, built from standard controls: style popup, font popup, size combo,
  B I U S, text colour well, highlight, alignment, bulleted/numbered lists, indent −/+, and line and
  paragraph spacing. It follows the selection. View ▸ Hide Format Bar (⌥⌘B) toggles it, and the choice is
  remembered.
- **Format menu.**
  - Font: Show Fonts ⌘T, Bold ⌘B, Italic ⌘I, Underline ⌘U, Strikethrough ⌘⇧X, Bigger/Smaller, Superscript/Subscript,
    colours, highlight.
  - Text: alignment ⌘{ ⌘| ⌘}, spacing, indent ⌘] ⌘[.
  - Style: Normal ⌥⌘0, Heading 1–6 ⌥⌘1…6, Title, Subtitle, Quote, Code, and Update Style to Match Selection.
  - List: ⌘⇧8 bullets, ⌘⇧7 numbers.
  - Clear Formatting `⌘\`.
- **Styles** map to real Word styles (`w:pStyle`), found by Word's canonical names, so localized Word files work.
  A standard style the document lacks is copied from `Blank.docx` on first use. Return after a heading continues
  in its `w:next` style.
- **Lists** come from `numbering.xml`, with Word's counting: shared counters per definition, restarts, and
  a./i. levels. TextKit 2 draws the markers. New lists are appended (and the part created if needed), and
  continue the list just above. Return on an empty item ends the list; Tab / Shift-Tab at an item's start
  change its level.
- **Ruler** (View ▸ Show Ruler ⌘R) with indent and tab markers, measured from the page margin. Dragging
  markers is saved as `w:ind` / `w:tabs`.
- **AppKit's own tools are saved correctly.** The Font panel, ruler drags and rich paste change the display,
  and `reconcile` turns that into Word properties.
- **Find and Replace** (⌥⌘F), Use Selection for Find (⌘E), Jump to Selection (⌘J).
- **Undo** covers every formatting command (one step each), including Update Style.
- **Lossless:** only the `w:rPr`/`w:pPr` children for changed fields are rewritten, in schema order. A value
  equal to the inherited one removes the element. Unchanged paragraphs keep their bytes. On every corpus file,
  opening and redrawing changes nothing.
- **Page geometry:** the text view is now the text column (no horizontal inset; `lineFragmentPadding` 0), so text
  starts at the margin and wraps at Word's text width. The canvas draws the page. See [gap G5](TEXTKIT2_GAPS.md).
- Spanish strings for everything new. Style names follow Word's Spanish (Título 1, Cita…).
- **Tests:**
  - 47 package tests: `FormattingTests` and `ElementPatchTests`, including "reconcile + renumber is a no-op on
    every fresh corpus file".
  - 31 app unit tests: `FormattingCommandTests` (commands through the real editor and save path, dead keys)
    and `RulerTests`.
  - 11 UI tests: `FormattingUITests` (⌘B → autosave → ⌘Z/⌘⇧Z, heading and list shortcuts, format bar click
    and hide, ruler, Find and Replace All).
- Bridge cost on the 100-page fixture: about 0.1 ms per keystroke (reconcile), 2 ms to renumber every list, and
  8 ms for the format state of a Select All.

**Not yet verified:**

- **Microsoft Word.** Deferred until Word is installed; see "Waiting on the human". New lists and copied
  styles are the parts most worth checking.
- **Manual pass in the running app:** the colour well popover, the highlight menu, and the font popup with
  fonts that aren't installed. The automated checks cover the logic, not the look.

**Known M2 limitations**

- TextKit 2 positions list items by nesting depth, so lists with unusual indents look approximate. They're
  saved exactly (gap G4).
- Text inside links, fields and content controls can't be reformatted yet; formatting commands skip it (M3).
- Copy and paste inside Libretilla goes through RTF, so pasted runs get formats derived from their look. Links
  and other objects paste as plain text.
- Superscript and subscript display at full size (TextKit 2 default), not reduced as in Word.
- Text colours are written as chosen. (Since M4, a dark page draws dark colours lighter, for display only.)
- ~~No Paragraph… dialog yet~~ Format ▸ Paragraph… (⌥⌘M) sets alignment, indents (first line, hanging), spacing
  and line spacing (multiple, at least, exactly) exactly (backlog 2, 2026-11-09).

## Milestone 3: Insert & page (in progress)

**CI is off (2026-11-04).** The owner disabled the GitHub Actions workflow to focus on whether Libretilla is
useful; verify locally (`swift test` in the package, `xcodebuild test`). Re-enable with `gh workflow enable CI`.
Left open: on CI only, `testFindAndReplaceAll` never sees an autosave after Replace All (it passes locally every
time). Draft PR #1 has tracing to find out why, but it never got a macOS runner.

**Done**

- **Page setup** from the final `w:sectPr` (`PageSetup` in LibretillaDocx): paper size, orientation and margins.
  The editor's page and text column follow it, so A4 documents show and wrap at A4 width.
- **File ▸ Page Setup…** shows the document's paper and orientation. A change is one undoable step, saved by
  rewriting only the changed `w:pgSz` / `w:pgMar` attributes. AppKit's whole-point sizes snap to Word's exact
  twips (A4 stays 11906 × 16838), and OK without a change rewrites nothing.
- **Print and File ▸ Export as PDF…** paginate with the document's own paper size and margins.
- **New documents are A4 in Charter** (owner's request, 2026-11-04): 12 pt body, 1.15 line spacing, Spanish
  Word's A4 margins (2.5 cm top/bottom, 3 cm sides). Charter is a book serif close to Century Schoolbook and
  Kindle's Bookerly, and ships with every Mac; the font table marks it as a serif so Word on Windows, which
  lacks it, substitutes one. Files that don't state a page size are also taken as A4.
- **Page breaks.** Word's `<w:br w:type="page"/>` is now a character in a run (`U+000C`) shown as a "Page
  break" chip; runs mixing text and a break are modelled (they used to show only the chip). Insert ▸ Page Break
  (⌘↩) ends the text before the caret with a break and starts a new paragraph, as Word does, in one undo step.
  Print and PDF start a new page after each break and print nothing for it.
- **Links.** A `w:hyperlink` of plain runs is now modelled (`Hyperlink`): its text is editable and stays a link,
  and an unchanged link keeps its bytes. Insert ▸ Link… (⌘K) links the selection, inserts new link text at a
  bare caret, or edits/removes the link the caret is in. New links get Word's "Hyperlink" character style and an
  external relationship (reused for the same URL, so autosaves don't add more); `xmlns:r` is declared if missing.
  Typing inside a link extends it, typing at its end doesn't. ⌘-click opens a link; a plain click places the caret.
  Links containing fields, bookmarks or tracked changes stay opaque, as before.
- **Images.** Pictures (a DrawingML `wp:inline`/`wp:anchor` with one embedded `a:blip`) show as the real image
  at their Word size; their XML is kept byte for byte. Insert ▸ Image…, paste and drag-and-drop add pictures,
  scaled down to the text width. On save each new picture becomes a media part (`word/media/imageN.ext`), an
  image relationship, a content-type default if needed, and Word's standard inline drawing with a unique
  `wp:docPr` id; identical images share a part. PNG, JPEG and GIF are stored as they are (detected from their
  bytes); anything else (HEIC, TIFF, PDF…) as PNG.
- **Format ▸ Picture…** (also double-click a picture, or its contextual menu): width and height (keeping the
  aspect ratio or not, in the ruler's units), rotation (any angle, plus quarter turns), brightness, contrast and
  opacity, shown live and applied as one undo step. Saved as Word writes them: `wp:extent` and `a:xfrm/a:ext`,
  `a:xfrm@rot` with the rotated picture's room in `wp:effectExtent`, `a:blip/a:lum` and `a:blip/a:alphaModFix`;
  the rest of the drawing keeps its bytes, and the image itself is never re-encoded. Documents that already
  carry these show them. Word 2010's newer brightness/contrast extension (`a14:imgEffect`) isn't read.
- **Tables** ([ADR 0006](decisions/0006-tables.md)). Each table is drawn from its XML, one attachment line per row:
  column grid (scaled to the text width if wider), horizontal spans, vertical merges, shading, borders from the
  table, its style (`basedOn` chain) or the cell, cell margins, the table style's paragraph spacing, and cell
  text through the bridge. Print and PDF break between rows. Double-click a table (or Format ▸ Edit Table…) for
  the cell editor sheet: edit text (⌥↩ for a new line), add/remove rows, and add/remove columns in simple grids.
  Only changed cells are rewritten (formatted like the cell's first paragraph and run); cells with links,
  images or nested tables are shown but not editable there. Insert ▸ Table… adds a "Table Grid" table across
  the text width. Tables stay one block: they're deleted or replaced whole, never partly.
- **The paper fills the window** (owner's request, 2026-11-04): no gray canvas by default. The text column
  stays at the document's text width, centred, so line breaks match print and PDF. View ▸ Show Page Edges
  brings back the page on a gray canvas; the choice is remembered.
- **Tests:** 11 new package tests (`PageSetupTests`), 6 app tests (`PageSetupDocumentTests`: editor geometry,
  undo and save, the Page Setup sheet, PDF paper size, a 50+ page PDF that keeps its last line, landscape).

**Known limitations so far**

- ~~Margins have no editor yet~~ File ▸ Margins… edits them, in the ruler's units (backlog 1, 2026-11-09).
- ~~Multi-section documents use the last section's page setup throughout~~ Print and PDF lay out each section on
  its own paper and margins, with next-page, continuous, odd- and even-page starts; page numbers run across them
  (backlog 3, 2026-11-09). The editor shows, and Page Setup and Margins edit, the final section's.
- The space below the last line equals the top margin (TextKit's inset is symmetric).
- Placeholder chips (footnote, comment, text box, equation) print into PDFs as they look in the editor.
- Floating pictures (`wp:anchor`) show inline where they're anchored, without text wrapping.
- Pictures are formatted from a sheet, not by dragging handles. Copying a picture within Libretilla saves the copy
  as a new image.
- Tables: no typing straight into cells (the sheet edits them); find, spell check and VoiceOver don't see cell
  text; table-style conditional formatting (banded rows, first-row shading from `w:tblStylePr`) isn't drawn;
  nested tables show as one line of text per row; a vertically merged cell's text sits in its first row; tables
  drawn at open keep their width if the page setup changes until the document is reopened.

**Milestone 3 features are all in.** (`w:pageBreakBefore`, still open here at the time, landed in Milestone 5.)

## Milestone 4: Polish (2026-11-05)

**Done**

- **Outline sidebar** (View ▸ Show Outline ⌃⌘S, or the toolbar's sidebar button). It lists the Title and
  Heading 1–9 paragraphs, found by Word's canonical style names (so localized Word files work) and by `basedOn`
  (`StyleSheet.outlineLevel`). It updates 0.3 s after typing stops, and clicking a heading (or Return) moves the
  caret there and scrolls it to the top. The row for the heading the caret is under is selected. Whether it
  shows is remembered; it's hidden by default.
- **Dark Mode pass.**
  - The page follows the appearance: automatic text is white on a dark page. Dark colours Word chose for a
    white page (black, navy headings, link blue) are drawn lighter until they reach 4.5:1, keeping their hue.
    Text on a highlight is drawn dark.
  - This is display only (TextKit 2 rendering attributes): the document's colours, undo and autosave are untouched.
  - **Printing and PDF export are always on white paper.** Before M4, automatic text exported in Dark Mode came
    out white on white.
  - Settings ▸ Page in Dark Mode ▸ "Light, as printed" keeps a white page with its real colours; the canvas and
    chrome stay dark.
- **Accessibility.**
  - VoiceOver's rotor lists headings (`NSAccessibilityCustomRotor`).
  - The format bar's segmented groups (Character style, Alignment, Lists, Indent), the outline and Settings are
    labelled.
  - The outline keeps full-contrast text, including its selected row.
  - `PolishUITests.testAccessibilityAudit` runs XCTest's audit on a document window (outline shown) and on
    Settings. It fails on any issue except, documented in the test: the document's own text colours, AppKit's
    window title, window tab and window buttons, and NSTextView's off-screen Touch Bar.
- **Settings** (Libretilla ▸ Settings… ⌘,): page in Dark Mode, page edges, format bar, and ruler units
  (centimetres, inches or points; the default follows the locale). Changes apply to open windows at once.
  Settings opens on the screen of the window you're working in.
- **Localization.** Every string the code localizes has Spanish; `LocalizationTests` fails if one doesn't.
  Placeholder chips (Footnote, Text box, Page break, "Table, 3 × 4"…) are now translated too, through
  `AttributedStringBridge.localizeLabel`, which the app sets.
- Fixed in passing: the save status accessory's conflicting constraints at window creation.
- **The Saved / Saving… status shows on macOS 26** (fixed 2026-11-05). A trailing title-bar accessory takes
  its width from its view's frame, not its constraints, and the zero frame left it 2 points wide outside the
  window. The frame is now sized to the text. It's drawn in the primary label colour, because secondary
  grey at 11 pt fails the audit's contrast check on the glass title bar.
  `PersistenceUITests.testSaveStatusIsVisibleInTheTitleBar` checks that the label is inside the title bar,
  not just present.
- **Tests:**
  - 1 package test (`outlineLevelsFollowWordsHeadingNames`).
  - 18 app tests (`PolishTests`, `LocalizationTests`).
  - 4 UI tests (`PolishUITests`: outline with real keys and clicks, Settings changing an open window, Dark
    Mode screenshots, the accessibility audit).
- UI tests only: `-LibretillaUITestFreshDefaults YES` clears Libretilla's settings at launch, and
  `-LibretillaUITestAppearance Dark|Light` forces an appearance.

**Not yet verified**

- A real VoiceOver session (the rotor is unit-tested, the audit passes).
- Tables, chips and pictures on a dark page: the text drawn inside them isn't recoloured.

**Decided with the owner (2026-11-05)**

- AppKit's "Edited" subtitle under the title stays. It is NSDocument's Versions state (changed since the last
  explicit save), which TextEdit shows too, so it's the Mac's own convention. Libretilla's status beside it says
  whether the file on disk is current.

## Milestone 5: Release (in progress)

**Done**

- **`w:pageBreakBefore` starts a new page in print and PDF export.** The bridge marks every character of a
  paragraph whose resolved properties (direct `w:pPr`, or the `w:pStyle` / `basedOn` chain; `w:val="0"`,
  `"false"` and `"off"` turn it off) say so with `.libretillaPageBreakBefore`. `PrintTextView` ends the page
  at the top of that paragraph's layout fragment, unless nothing is above it on the page already (it follows a
  page break, or it's the document's first paragraph). The editor shows nothing new and a save writes nothing
  new. Fixture `13-page-break-before.docx` (direct, through a style chain, turned off three ways; prints on 4
  pages). Tests: 5 package tests (`PageBreakTests`), 3 app tests (`PageSetupDocumentTests`).
- **Headers and footers (ADR 0007).**
  - The codec reads the headers and footers the last section uses (its own references, or inherited from earlier
    sections), with `w:titlePg` and `w:evenAndOddHeaders`. Each part parses like the body, so unedited ones are
    written back byte for byte and an edit rewrites only its paragraphs. A new header or footer gets its part,
    relationship, content type and `w:sectPr` reference on save.
  - `PAGE` and `NUMPAGES` fields, simple or complex, become one opaque inline each, with the same markup on save.
  - Print and PDF draw each page's header and footer at `w:pgMar`'s header and footer distances, across the text
    column, with the real page number and page count. Page 1 uses the first-page pair when "Different first
    page" is on, and even pages the even pair when the document has them. Word's Page Number content control
    prints its content.
  - Format ▸ Header and Footer… edits them in a sheet: header and footer text views laid out by the bridge,
    "Different first page" with First Page / Other Pages, Insert Page Number and Insert Page Count (shown as
    chips). One undo step; Cancel changes nothing. Even-page ones are kept and printed but not edited there.
  - Fixture `14-headers-footers.docx`. Tests: 10 package tests (`HeaderFooterTests`), 6 app tests
    (`HeaderFooterDocumentTests`, including a 3-page PDF that reads "Page 2 of 3").

**Known issues**

- When a page ends early at a paragraph that starts a new page, TextKit still draws that paragraph on the page
  before, clipped out of sight: the paper is right, but the paragraph's text is also in that page's PDF text
  (search, copy, accessibility). The tests read each page's first line, which is right.
- Headers and footers: a multi-section document prints the last section's on every page (as for page setup).
  Header text taller than the top margin overlaps the body instead of pushing it down. The editor doesn't show
  them (edit them in the sheet). Even-page headers and footers can't be edited in the sheet yet. New ones use the
  document's Header and Footer styles if it has them, plain paragraphs if not.
- The page-break-before mark is set when the document opens: giving a paragraph another style in the editor
  doesn't change whether it starts a page in print until the document is reopened (the saved file is right).
