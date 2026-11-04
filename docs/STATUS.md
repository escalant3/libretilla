# Status

## Milestone 0: Spike ✅ (2026-11-04)

**Done**

- Repo skeleton: XcodeGen `project.yml` plus the committed `Cartilla.xcodeproj`. arm64-only, macOS 26, Swift 6,
  sandboxed (user-selected read-write + app-scoped bookmarks), hardened runtime (Release), EN/ES string catalog.
- App shell: programmatic standard menus, stub autosave-in-place `NSDocument` that declares the `.docx` type,
  page-width text view on a gray canvas. Unit tests and a UI launch smoke test pass.
- `Packages/CartillaDocx`: the `DocxCodec` protocol and a placeholder `DocxDocument` model.
- Fixture corpus: 10 generated Word-style files, plus one from pandoc and one exported from Pages.
  Reproducible, and checked by CI.
- SwiftDocX evaluation (`Spikes/SwiftDocXEval`, [RESULTS.md](../Spikes/SwiftDocXEval/RESULTS.md)) and
  TextKit spike (`Tests/TextKitSpikeTests.swift`).
- ADRs: [0001 TextKit 1](decisions/0001-textkit.md), [0002 own lossless OOXML codec](decisions/0002-docx-library.md),
  both **Proposed**.
- CI workflow (`.github/workflows/ci.yml`). Not run on GitHub yet, because there's no remote. Every step passed locally.

**Decided with the human:** minimum macOS 26; sandboxed; generated corpus with real-app slots left as TODOs;
local git only for now.

## Waiting on the human

- [ ] Accept or amend ADR 0001 (TextKit 1) and ADR 0002 (own codec). ADR 0002 adds **ZIPFoundation 0.9.20 (MIT)**
      as the app's first runtime dependency, which needs your approval.
- [ ] Header/footer in 1.0 or 1.1. Recommendation in ADR 0002: preserve plus print/PDF and a simple editing sheet in
      1.0; inline editing in 1.1.
- [ ] ADR 0003: where new/unnamed documents live, and the one-time backup of Word-authored originals.
- [ ] Sparkle yes/no; domain and website host.
- [ ] Real fixture files for `Fixtures/real/{word,libreoffice,googledocs}` (see `Fixtures/README.md`).
- [ ] Placeholder bundle id `app.cartilla.Cartilla`; confirm, or choose one tied to the domain.
- [ ] Copyright line in `LICENSE` ("Diego Escalante (escalant3)"); confirm the name.
- [ ] Create the GitHub remote when ready. CI targets the `macos-26` runner image.

## Next: Milestone 1 (skeleton)

Explicit TextKit 1 text view; `OPCPackage` copy-through reader/writer; `document.xml` byte-range-preserving
parser for paragraphs and runs; `AttributedStringBridge`; autosave in place with async writes; Saved/Saving
status; round-trip suite over the corpus.
