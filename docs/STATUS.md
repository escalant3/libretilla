# Status

## Milestone 0: Spike ✅ (2026-11-04)

**Done**

- Repo skeleton: XcodeGen `project.yml` plus the committed `Cartilla.xcodeproj`. arm64-only, macOS 26, Swift 6,
  sandboxed (user-selected read-write + app-scoped bookmarks), hardened runtime (Release), EN/ES string catalog.
- App shell: programmatic standard menus, stub autosave-in-place `NSDocument` that declares the `.docx` type,
  page-width text view on a gray canvas. Unit tests and a UI launch smoke test pass.
- `Packages/CartillaDocx`: the `DocxCodec` protocol, a placeholder `DocxDocument` model, and ZIPFoundation 0.9.20
  (MIT, approved) with a smoke test that reads a fixture.
- Fixture corpus: 10 generated Word-style files, plus one from pandoc and one exported from Pages.
  Reproducible, and checked by CI.
- SwiftDocX evaluation ([archived results](decisions/0002-swiftdocx-evaluation.md); spike code removed, see
  commit `09ad587`) and TextKit comparison.
- ADRs **accepted**: [0001 TextKit 2 + gap register](decisions/0001-textkit.md) ([gaps](TEXTKIT2_GAPS.md)),
  [0002 own lossless OOXML codec, built incrementally](decisions/0002-docx-library.md).
- Editor uses an explicit TextKit 2 `NSTextView` and logs a fault if anything forces a TextKit 1 fallback.
  `Tests/TextKit2CompatibilityTests.swift` pins the known gaps.
- Repo on GitHub: [escalant3/cartilla](https://github.com/escalant3/cartilla) (private). CI is green on the `macos-26`
  runner (Xcode 26.6, arm64); a full run takes about 1.5 minutes.

**Decided with the human:** minimum macOS 26; sandboxed; generated corpus with real-app slots left as TODOs;
private GitHub repo; TextKit 2 with tracked gaps (fix them late in the project); no SwiftDocX, build our own
DOCX layer gradually; unnamed documents are system drafts until named (ADR 0003); private backup copy of originals plus Versions (ADR 0004).

## Waiting on the human

- [ ] Header/footer in 1.0 or 1.1. Recommendation in ADR 0002: preserve plus print/PDF and a simple editing sheet in
      1.0; inline editing in 1.1.
- [ ] Sparkle yes/no; domain and website host.
- [ ] Real fixture files for `Fixtures/real/{word,libreoffice,googledocs}` (see `Fixtures/README.md`).
- [ ] Placeholder bundle id `app.cartilla.Cartilla`; confirm, or choose one tied to the domain.
- [ ] Copyright line in `LICENSE` ("Diego Escalante (escalant3)"); confirm the name.

## Milestone 1: Skeleton ✅ (2026-11-04)

**Done**

- `CartillaDocx` codec (ADR 0002):
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

**Not yet verified:** opening Cartilla-written files in **Microsoft Word**. It isn't installed on the dev
machine. Please open a few edited files in Word and report any repair prompt.

**Known M1 limitations (planned)**

- No formatting UI yet (M2). Typed text takes the formatting of the run it's typed into.
- Links, fields, content controls and objects can be deleted whole but not edited inside (M3).
- Tables show as a placeholder line. TextKit 2 can't lay them out (gap G1), and table editing is M3.
- New documents are US Letter.

## Next: Milestone 2 (formatting)

Format bar and menus, styles and headings (`w:pStyle` mapping, style popup), lists (`numbering.xml`),
alignment, spacing, ruler, find/replace, undo.
