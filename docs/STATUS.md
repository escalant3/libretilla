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
DOCX layer gradually; unnamed documents are system drafts until named (ADR 0003).

## Waiting on the human

- [ ] Header/footer in 1.0 or 1.1. Recommendation in ADR 0002: preserve plus print/PDF and a simple editing sheet in
      1.0; inline editing in 1.1.
- [ ] ADR 0004: the one-time backup of Word-authored originals before the first autosave.
- [ ] Sparkle yes/no; domain and website host.
- [ ] Real fixture files for `Fixtures/real/{word,libreoffice,googledocs}` (see `Fixtures/README.md`).
- [ ] Placeholder bundle id `app.cartilla.Cartilla`; confirm, or choose one tied to the domain.
- [ ] Copyright line in `LICENSE` ("Diego Escalante (escalant3)"); confirm the name.

## Next: Milestone 1 (skeleton)

`OPCPackage` copy-through reader/writer; `document.xml` byte-range-preserving
parser for paragraphs and runs; `AttributedStringBridge`; autosave in place with async writes; Saved/Saving
status; round-trip suite over the corpus.
