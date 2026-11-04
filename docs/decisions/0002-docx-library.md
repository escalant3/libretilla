# 0002. DOCX layer: our own lossless OOXML codec, not SwiftDocX

- **Status:** Accepted (2026-11-04). ZIPFoundation 0.9.20 approved and added the same day
- **Date:** 2026-11-04
- **Evidence:** [`0002-swiftdocx-evaluation.md`](0002-swiftdocx-evaluation.md) (archived spike results),
  [`Fixtures/`](../../Fixtures/README.md). The spike code (`Spikes/SwiftDocXEval`) was removed after this decision
  and can be recovered from git history at commit `09ad587`

## Context

Bootstrap §5.2 offers three options for the DOCX library: (a) adopt Techopolis/SwiftDocX and contribute upstream,
(b) fork or vendor it, or (c) write our own thin OOXML layer on ZIPFoundation + Foundation XML.

What drives the choice is **R2 and the round-trip policy**: Cartilla autosaves over the user's real file.
So an open → edit → save cycle must keep every part we don't own byte-identical, and must keep content we don't
understand (fields, `w:sdt`, comments, footnotes, text boxes, …) intact. A library that *models* a document and
*regenerates* it can't meet that requirement, however many features it supports.

The spike ran SwiftDocX **1.0.2** (4 commits, ~3 200 lines, MIT) over 12 fixtures. Ten are generated in Word-style
markup by `scripts/fixtures/make_corpus.py`, one is written by pandoc and one is exported from Pages 14.5.
`DocxProbe` is an independent ZIPFoundation + `XMLParser` scanner that provides the ground-truth counts.
Every output was also opened in Pages as a smoke test.

## Findings

1. **Naive open → save produces an empty document.** `Document(contentsOf:)` fills `paragraphs` but leaves
   `elements` empty, and `write(to:)` serializes `elements`. All 12 fixtures came back with **0 words**
   (`naiveOpenSaveWritesAnEmptyBody`). The workaround, copying `paragraphs` into `elements`, is what the rest of
   these findings measure.
2. **The reader reads only top-level `w:p` in `word/document.xml`.** It reads no other part. Specifically:
   - **0** headings or styles recovered (`w:pStyle` is ignored: 0/161 headings on the large file);
   - **0** list items (`w:numPr` ignored);
   - **0** tables (`w:tbl` is skipped, so table text is lost: 7/32 words on `04-tables`);
   - **0** hyperlinks (runs inside `w:hyperlink` are skipped, so link text is lost);
   - **0** images, **0** page breaks, **0** headers/footers;
   - no section or page setup, no `w:lang`.

   Direct run formatting (bold/italic/underline/strike/colour/highlight/size/font/super/sub) and paragraph
   alignment/spacing/indent **are** read correctly.
   This holds even for SwiftDocX's own output: headings, lists, tables, hyperlinks, images and header/footer it
   writes are not recovered when it reads the file back.
3. **The writer regenerates the whole package from templates.** Across the corpus, **0** parts were byte-identical
   after a save. It writes its own `styles.xml` (Normal, Heading 1–6, Table Grid only) and `settings.xml`, and
   **drops** `theme1.xml`, `fontTable.xml`, `webSettings.xml`, `docProps/*` (title and author metadata),
   `numbering.xml`, `footnotes.xml`, `endnotes.xml`, `comments.xml`, headers/footers, media and custom XML parts.
   On `10-word-features` it loses every footnote and comment reference, the tracked changes, both kinds of field,
   both content controls, the text box, the equation and the 2-column section.
4. **What it writes is valid.** Every output, and a document authored through its API, opened in Pages, and passed
   our OPC checks (content types, relationships, well-formed XML). As a *generator* it works for its feature set:
   headings, nested lists, tables with shading, hyperlinks, images, header, and a footer with PAGE/NUMPAGES.

## Options

- **(a) Adopt and contribute upstream.** The missing pieces aren't features to add at the edges. They are the
  reader (it has to parse every block type and every part) and the writer's core assumption that it owns the
  whole package. Upstreaming would mean rewriting both inside a young project with its own priorities.
  We'd block on review for our most critical code path.
- **(b) Fork or vendor.** Same rewrite, and we would own it anyway. Only `ZIPReader`/`ZIPWriter` (~160 lines
  around ZIPFoundation) and the `XMLTree` helper would survive. That isn't worth a fork's maintenance and
  attribution overhead.
- **(c) Our own thin layer.** About the same size as SwiftDocX for the v1 subset, but designed around
  preservation from the first line.

## Decision

**Option (c).** `Packages/CartillaDocx` implements `DocxCodec` on **ZIPFoundation** plus our own small XML layer.
SwiftDocX is not used anywhere in the project. We build the codec **gradually**, adding only what the current
milestone needs (M1: package copy-through, paragraphs and runs; M2: styles, lists, paragraph formatting;
M3: tables, images, hyperlinks, sections). Each step comes with its fixtures and round-trip tests.

Design principles for M1:

1. **The package is the source of truth.** `OPCPackage` keeps every zip entry's original bytes and zip order,
   plus `[Content_Types].xml` and every `.rels`. On save, any part we didn't modify is copied through byte for
   byte. An unedited open → close never writes (bootstrap §5.4).
2. **Lossless XML for the parts we edit** (`document.xml`, later `styles.xml`, `numbering.xml`, headers/footers):
   - Parse with a small tokenizer that records each node's **source byte range**, keeps namespace declarations,
     `mc:Ignorable`/`mc:AlternateContent`, attribute order and whitespace.
   - `XMLParser` reports only line/column, which isn't enough for this. libxml2 or a ~300-line tokenizer are
     both viable. The tokenizer is the recommendation, decided in M1.
   - Every block (`w:p`, `w:tbl`, `w:sdt`, `w:sectPr`, …) and every run keeps its original bytes. **Unedited
     blocks are re-emitted verbatim.** Only blocks the user changed are re-serialized.
   - Unknown children inside a known element stay in place as opaque nodes.
3. **Model.** `DocxDocument` gets blocks, runs, styles, numbering, sections and media (today's placeholder), and
   each block carries an origin token pointing back at its source bytes. The `AttributedStringBridge` maps
   model ⇄ `NSAttributedString` (TextKit 2, ADR 0001) and keeps the origin token on the text as a custom
   attribute. An edit invalidates the token for that block only.
4. **When something can't be preserved,** for example the user deletes half of a comment range: degrade
   structurally safe (drop the dangling marker), and record a notice for the non-blocking UI banner. Never
   write a dangling reference. Our OPC checker (from `DocxProbe`) runs on every save in debug builds.
5. **Tests are the contract.** The corpus round-trip suite asserts:
   - open → save without edits is byte-identical for every part;
   - an edit changes only `document.xml` (plus rels/content types when media is added);
   - read → write → read is equivalent on the model.

   The spike's `DocxProbe` scanner and OPC checker (commit `09ad587`) are good starting points for
   `CartillaDocx`'s test support.

## Consequences

- ✅ The Word-compatibility goal (R2, §7 "Word-compatible") is achievable by construction rather than by chasing
  features. The autosave-over-originals safety gate (§5.4 item 5) can be lifted once the suite is green.
- ✅ No dependency on a young upstream for our riskiest code. One runtime dependency: **ZIPFoundation 0.9.20 (MIT)**.
- ⚠️ We write and maintain the OOXML mapping ourselves. The v1 subset is about 2–3k lines plus tests, about the
  size of SwiftDocX, so the effort is comparable to rewriting SwiftDocX's reader and writer anyway.
- ⚠️ Rendering features we only preserve (text boxes, columns, footnotes) stays "display as faithfully as
  feasible". Preserving them is guaranteed; showing them is incremental work.
- ⚠️ The corpus is synthetic plus pandoc and Pages output. **Real Word, LibreOffice and Google Docs files are
  still needed** (`Fixtures/real/`). They use more markup (rsids, `w14` extensions, `mc:AlternateContent`
  everywhere), which strengthens the case for byte-range preservation.
- Courtesy follow-up (optional; ask first): report the empty-body read→write bug to Techopolis/SwiftDocX upstream.

## Input to an open question: header/footer in 1.0 or 1.1?

Under this design, **preserving** headers and footers is free in 1.0: they are parts we copy through. The spike
also shows the markup is small: a default header/footer plus a `PAGE` field.

Recommendation, for the human to decide:

- **1.0:** preserve all headers and footers, and render the default header/footer (text + PAGE/NUMPAGES) in
  print and PDF export. Edit them through a simple Format ▸ Header & Footer… sheet: plain text, alignment,
  page-number token.
- **1.1:** inline editing on the page, together with the paginated page view. Also first-page and even/odd
  variants.
