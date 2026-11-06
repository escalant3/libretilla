# Libretilla — Bootstrap Brief for Claude Code

> Drop this file in the root of an empty repo as `BOOTSTRAP.md`. After the first working milestone, condense the "Conventions" and "Architecture" sections into `CLAUDE.md` and keep this file as history.

## 1. What we are building

**Libretilla** (Spanish for "notebook") is a minimalist, native macOS word processor whose **native file format is `.docx`**. It lets you write documents without distractions and export them to PDF. It is a small, independent app: no ribbon, no AI, no cloud, no database integration.

Design touchstones: Office 97 / WordPad for structure (a menu bar, one compact toolbar, a formatting bar, an optional ruler) and **Google Docs for polish and behaviour** (editable title at the top, a "Saved" status, a clean page on a quiet canvas, an outline panel, no save ritual). Everything is built from **native macOS controls**. Dark mode and standard Apple conventions come for free and must never be fought. Beauty is in minimalism.

Sibling reference (not a dependency, not a suite): [SimpleSpread](https://github.com/baudehlo/SimpleSpread) — a Swift/MIT native spreadsheet app on XLSX. Look at its toolbar button style and repo layout for inspiration.

## 2. Hard requirements

| # | Requirement |
|---|---|
| R1 | macOS app, **Apple Silicon (arm64) only**, AppKit and/or SwiftUI, Swift 5.9+ (Swift 6 mode if painless). |
| R2 | `.docx` is the native format: open, edit, save (changes are autosaved to the `.docx`; `⌘S` just forces a save). **Goal: full compatibility with Microsoft Word users.** A `.docx` exchanged between Libretilla and Word, in either direction, must open without repair prompts and keep its content, styles and layout; nothing in a file may be lost or altered by a Libretilla open/save cycle (see §5.2 and §7). |
| R3 | Export to **PDF** (File ▸ Export as PDF…, plus the standard Print ▸ Save as PDF). |
| R4 | No ribbon. Menu bar + one compact toolbar + one formatting bar (+ optional ruler). |
| R5 | Native controls, dark mode, full-screen, Versions/autosave/Open Recent, Spotlight/Quick Look-friendly, VoiceOver-accessible. |
| R6 | **MIT license**, provided dependency licenses are compatible (see §8). |
| R7 | Distributed as a **signed, notarized DMG** from the project website. |
| R8 | Localized in **English and Spanish** from day one (String Catalogs). |
| R9 | **Cloud-editor persistence model:** no manual saving. Every edit is kept automatically, in the real `.docx` file, and survives closing, quitting, crashes and power loss. There is no "Do you want to save changes?" dialog, ever. The one accepted exception is the standard system sheet shown when closing a never-named, non-empty document (ADR 0003). See §5.4. |

## 3. Non-goals (say no to these)

AI features, cloud sync, collaboration, comments/track changes (v1), mail merge, macros, charts/SmartArt, database connections, plugins, Windows/Linux/iOS, Intel Macs, Mac App Store (for now).

**Authoring vs. compatibility:** advanced Word features (columns, floating objects with text wrapping, text boxes, comments, track changes, footnotes, fields) are not *authoring* goals for v1 — Libretilla has no UI to create them — but they are *compatibility* goals: files containing them must open, display as faithfully as feasible, and be written back intact. Adding authoring/rendering support for them later is welcome, in order of how often real Word documents use them.

## 4. v1 feature scope ("all the basics")

**Text & character:** font family/size, bold, italic, underline, strikethrough, text color, highlight, superscript/subscript.
**Paragraph:** alignment (left/center/right/justify), line spacing, space before/after, indents (left, first-line, hanging), bullet / numbered / nested lists.
**Styles & structure:** Normal, Title, Subtitle, Heading 1–6, Quote, Code-ish (monospace) — mapped to real Word styles (`w:pStyle`) so Word sees real headings. A style popup in the formatting bar; "update style from selection". Outline/navigation sidebar from headings. Table of contents is **v1.1**.
**Insert:** table (basic: rows/cols, header row, borders, cell shading), image (inline, PNG/JPEG), hyperlink, page break, horizontal rule *(optional)*.
**Page:** page size (Letter/A4/custom), orientation, margins, header/footer with page number (v1.0 or 1.1 — decide after the spike), ruler with indent markers.
**Editing:** undo/redo, find & replace (native find bar), spell check / grammar / autocorrect (system), word count, zoom, full screen, focus/typewriter mode *(nice-to-have)*.
**Documents:** NSDocument semantics — autosave in place (§5.4), Versions, Open Recent, tabs, drag-and-drop images, Quick Look preview of `.docx` is *not* our job.
**I/O:** open/save `.docx`; export PDF; import/export plain text and RTF for convenience *(cheap via AppKit)*; `.doc` legacy is out of scope.

## 5. Recommended architecture

### 5.1 Editing engine
Use **TextKit (NSTextView / NSTextStorage / NSLayoutManager)** as the editing and layout engine. Do not write a text layout engine. Hosting:
- **AppKit `NSDocument` + `NSWindowController`** for the document lifecycle (autosave, Versions, printing, tabs work best here), with **SwiftUI** for secondary UI (Settings, dialogs, sidebars) via `NSHostingView`. If a pure SwiftUI `DocumentGroup` proves sufficient during the spike, prefer it — but expect to drop to AppKit for the text view and printing.
- In-memory model = `NSAttributedString` in an `NSTextStorage`, plus a small set of **custom attributes** to carry what AppKit lacks: Word style id (`libretilla.styleId`), list level/num id, hyperlink, table membership (use `NSTextTable`/`NSTextTableBlock`), page-break marker.
- **Page view:** start with a "page-width column on a gray canvas" (single continuous scroll). True paginated display (multiple `NSTextContainer`s, TextEdit-style) is a **v1.1 milestone**; design the document model so it can be added without rewrites. Printing/PDF export must paginate correctly from day one (`NSPrintOperation` with a paginated print view, `NSPrintInfo.jobDisposition = .save`).
- Pick TextKit 1 or 2 deliberately in the spike (TextKit 2 is the default on modern macOS, but `NSTextTable` and some paging features still depend on TextKit 1 behaviour). Document the decision in `docs/decisions/0001-textkit.md`.

### 5.2 DOCX layer (isolated Swift package: `LibretillaDocx`)
Hide the DOCX library behind our own protocol so it can be swapped:

```swift
protocol DocxCodec {
    func read(_ url: URL) throws -> LibretillaDocument      // model, not NSAttributedString
    func write(_ doc: LibretillaDocument, to url: URL) throws
}
```
`LibretillaDocument` = ordered blocks (paragraph, table, image, page break) with runs, a style table, numbering definitions, section properties, and media. A separate `AttributedStringBridge` converts model ⇄ `NSAttributedString`.

**Round-trip policy (important; this is how R2's Word-compatibility goal is met):** a word processor that silently destroys content is worse than none. On open, preserve any OOXML we don't understand (unknown elements, `w:sdt`, fields, comments, footnotes, settings, theme, custom XML parts) as opaque payloads and re-emit them on save where structurally safe; show a non-blocking notice only for the rare case where something cannot be preserved. The target is lossless: unsupported content is kept byte-for-byte, and only elements the user edits are re-serialized. Never discard parts of the zip we don't touch (copy-through).

**Library choice:** [Techopolis/SwiftDocX](https://github.com/Techopolis/SwiftDocX) (MIT, depends on ZIPFoundation). Per its README it supports read/write, character formatting, headings H1–H6, nested bullet/numbered lists, tables, and paragraph alignment/spacing/indent. The README does **not** mention images, headers/footers, page setup, hyperlinks, or general style definitions, and the repo is young (announced Jan 2026, very few commits). Therefore:

1. **Spike first (Milestone 0):** evaluate SwiftDocX against the 10-file corpus (§7). Record exactly what round-trips.
2. **Decision gate:** (a) adopt as-is and contribute missing features upstream; (b) adopt and fork/vendor (MIT permits this) ; or (c) write our own thin OOXML layer on **ZIPFoundation + Foundation `XMLParser`** (or AEXML). Option (c) is likely if images/headers/footers/style definitions are missing — the needed OOXML subset is modest. Record in `docs/decisions/0002-docx-library.md`.
3. Either way, the app depends on `DocxCodec`, never on SwiftDocX types directly.

Reference for OOXML details: ECMA-376 (Transitional); target "Word 2016+" compatibility. Validate output with the Open XML SDK validator if available in CI (optional) and by opening in Word / LibreOffice / Pages.

### 5.3 Suggested layout
```
Libretilla/
  Libretilla.xcodeproj  (or Package.swift + Xcode project)
  App/                 NSApplicationDelegate, menus, Settings
  Document/            NSDocument subclass, window controller
  Editor/              NSTextView subclass, ruler, paging, find bar glue
  UI/                  Toolbar, FormatBar, Inspectors (SwiftUI)
  Packages/
    LibretillaDocx/      codec + model + attributed-string bridge + tests
  Resources/           Assets, Localizable.xcstrings, icons
  Tests/ + UITests/
  Fixtures/            sample .docx corpus
  docs/decisions/      ADRs
  scripts/             build, sign, notarize, dmg
  .github/workflows/   CI
```

### 5.4 Autosave & persistence (Google Docs expectation)

**Principle:** the `.docx` on disk *is* the document, and it is always current. Users never press Save, never name a file before typing, and never lose work. We get this almost entirely from AppKit's document architecture, so **do not invent a custom save system**.

**Mechanism (macOS-native, same as Pages/TextEdit/Preview):**
- `NSDocument` subclass with `class var autosavesInPlace: Bool { true }`. Edits are written back to the real file in the background; the system adds **Versions** (File ▸ Revert To ▸ Browse All Versions…) as the history/undo-the-day safety net, our equivalent of Google Docs "Version history" at zero cost.
- Report every change with the document's undo manager / `updateChangeCount(.changeDone)` so the system knows it is dirty. Set `NSDocumentController.shared.autosavingDelay` to a short value (target 2–5 s of idle time; tune in M1). The system also saves on window close, app quit, app resign-active, sleep, and logout.
- **Write off the main thread:** override `canAsynchronouslyWrite(to:ofType:for:)` → `true` for autosave, and make `write(to:ofType:)` operate on an immutable snapshot of the model (`data(ofType:)`/`fileWrapper` built from a snapshot taken on the main thread). Typing must never hitch on a 100-page document. Only re-serialize the OOXML parts that changed (see round-trip policy; also makes autosave fast).
- **Writes must be atomic** (NSDocument writes to a temp file and swaps it in; keep that, never write in place by hand). A crash mid-save must leave the previous good file.
- **Only save after real edits.** Opening a Word-authored file and closing it must not rewrite it (no mtime change, no re-serialization). Only an actual change marks the document dirty. Selection moves, scrolling and zoom must not touch the file (store view state outside the `.docx`, e.g. in the app's state-restoration data).

**New documents (the part that differs from Word 97):**
- File ▸ New opens a window titled "Untitled" immediately, and typing is persisted right away as a system-managed autosaved draft (stored in the app's sandbox container), restored automatically after a quit or crash.
- Naming happens by **clicking the title in the title bar** (system rename/move popover, free with autosave-in-place) or File ▸ Rename…/Move To…. We never block typing with a save panel.
- **Decided (ADR 0003): unnamed documents stay system drafts until named, the same as Pages and TextEdit.** Closing an unnamed, non-empty document shows the standard system sheet (name and place it, or delete it). That's the only accepted exception to R9's no-dialog rule. Closing an empty unnamed document discards it silently. There is no custom default folder and no file is created in the user's folders before the document is named.
- Quit with unnamed drafts: no dialog; they come back on relaunch (window restoration on; verify `NSQuitAlwaysKeepsWindows` behaviour).

**Status indicator (replaces the Save button):** next to the editable title show a small, quiet state: `Saved` / `Saving…` / `Couldn't save — Retry` (with details in a popover). Updates from document change count and write completion. VoiceOver announces failures only, not routine saves. The toolbar has **no Save button**; `⌘S` stays in the menu (forces an immediate save, harmless).

**Hard cases to handle explicitly (each gets a test):**
1. **External modification** (Word, Dropbox/iCloud sync, another Libretilla window): rely on `NSFilePresenter` support in `NSDocument`; on external change with no local edits, reload silently; with local edits, offer "Keep mine / Use theirs / Keep both" (never silently overwrite). Detect Word's lock file `~$name.docx` and show a non-blocking "open in Word" notice.
2. **Read-only / locked files, read-only volumes, files without write permission:** open as read-only with an obvious banner and offer "Duplicate to edit"; never show a failing "Saving…" loop.
3. **Volumes without Versions** (FAT/exFAT/some network shares): autosave still works but history is unavailable; tell the user once.
4. **Disk full / permission lost mid-session:** keep the in-memory document, show `Couldn't save`, retry on next change and on regaining space, and prompt Save As… on window close if the last save failed.
5. **Safety of overwriting Word-authored originals:** because we autosave over the user's real file, the lossless round-trip policy is a prerequisite for enabling autosave on files we didn't create. Until the corpus tests pass, autosave must be gated by a "first edit of an existing file" step that makes a **one-time sibling backup** (`name (original).docx`, or rely on the Versions snapshot if available) — decided in ADR 0004: before the first save, copy the untouched original into the app's sandbox container (kept 30 days, File ▸ Restore Original…), and rely on Versions where the volume supports it. No sibling file is written.
6. **Crash recovery:** drafts and unsaved changes recovered through the standard NSDocument autosave-information mechanism; test by `kill -9` during typing.
7. **Large documents / slow disks (iCloud, network):** autosave is debounced and coalesced; never queue more than one write in flight.
8. **Undo after reopen:** undo history is not persisted; Versions covers the "go back" need. Say so in docs.

**Not doing:** our own journal/WAL, our own history store, a custom cloud, or a "Save" mode toggle.

## 6. UI spec

- **Window:** standard titlebar with proxy icon; **no edited-dot and no Save button** (autosave, §5.4). Google-Docs-style **editable title** at the top (system rename/move behaviour) with the quiet `Saved` / `Saving…` status beside it. `NSToolbar` with small, unlabeled SF Symbols buttons in the unified style: New, Open, Print, Export PDF | Undo, Redo | Zoom. Version history reachable from the title menu and File ▸ Revert To. Customizable toolbar.
- **Format bar** (a second row under the toolbar, Office 97 style): Style popup · Font popup · Size combo · **B** *I* U S · Text color · Highlight · Align ×4 · Bullets · Numbering · Indent −/+ · Line spacing. Standard `NSPopUpButton`, `NSColorWell`/`NSColorPanel`, `NSSegmentedControl`. Can be hidden (View ▸ Hide Format Bar).
- **Ruler:** optional, `NSRulerView` with indent and tab markers. Inches/cm per locale.
- **Sidebar (optional):** document outline from headings; toggle with `⌃⌘S`.
- **Status bar (optional, hidden by default):** page/word count, zoom.
- **Menus:** complete standard macOS menus (File, Edit, Format, Insert, View, Window, Help) with conventional shortcuts. Format ▸ Font/Style/Text/List/Table submenus.
- **Visuals:** system fonts for chrome, system accent color, SF Symbols, vibrancy only where AppKit gives it by default. No custom theming. Support Light/Dark/Increased Contrast/Reduced Motion. The document canvas can follow appearance (white page on dark gray canvas in Dark mode, optionally "dark page" setting).
- **Accessibility:** every control labeled, full keyboard operability, VoiceOver rotor for headings.

## 7. Quality bar & testing

- **Fixture corpus (`Fixtures/`):** at least 10 `.docx` files: plain text; headings; nested lists; tables; images; hyperlinks; header/footer; Spanish with accents/ñ; a large (100+ page) document; one produced by Word, one by LibreOffice, one by Google Docs, one by Pages.
- **Tests:** unit tests for codec and bridge (read → write → read equivalence on the model); golden-file tests; UI smoke tests (launch, type, save, reopen, export PDF).
- **Acceptance for "Word-safe":** every file Libretilla writes opens in Word for Mac with no repair dialog; text, styles, lists, tables survive two save cycles.
- **Acceptance for "Word-compatible":** open-and-save-without-editing leaves every OOXML part we don't own byte-identical (verified by a zip/XML diff test over the whole corpus); an edited file differs only in the parts the edit touched; documents authored in Word with columns, text boxes, footnotes, comments, track changes and fields come back to Word with those features intact. Add Word-authored fixtures for each of these features to the corpus, and visually compare Libretilla's rendering against Word/LibreOffice PDF output for the supported subset.
- **Performance:** launch < 1 s on M1; typing latency imperceptible on a 100-page document.
- **CI:** GitHub Actions on `macos-latest` (arm64): build, test, SwiftLint/swift-format check.

## 8. Licensing

- Project license: **MIT** (`LICENSE` at root, copyright header optional).
- Known dependency licenses: SwiftDocX — MIT; ZIPFoundation — MIT; Sparkle (if used for updates) — MIT-style, with bundled third-party notices that must be included. SimpleSpread is MIT but we are copying no code from it; if we do, preserve its notice.
- Keep `THIRD_PARTY_LICENSES.md` generated/updated whenever a dependency is added; check each new dependency's license **before** adding it (no GPL/LGPL/AGPL, since we're MIT and ship a closed binary DMG).
- Don't use Microsoft trademarks/branding or Word icons; "Word" and ".docx" may be named descriptively only. The app name "Libretilla" should get a quick trademark/App Store name search before launch (low risk, but check).

## 9. Distribution: notarized DMG

Prerequisite for the human: an **Apple Developer Program** membership (needed for a Developer ID certificate). Claude Code should script everything else.

1. Build Release, arm64, **Hardened Runtime** on, minimal entitlements (add `com.apple.security.files.user-selected.read-write` only if sandboxing; sandbox is optional for Developer ID distribution but recommended — decide in an ADR).
2. Sign with *Developer ID Application* (`codesign --options runtime --timestamp`), deep-sign embedded frameworks (Sparkle) inside-out.
3. Create DMG (`create-dmg` or `hdiutil`) with background and Applications symlink; sign the DMG.
4. Notarize: `xcrun notarytool submit … --wait` (credentials via keychain profile / App Store Connect API key), then `xcrun stapler staple`.
5. Verify: `spctl -a -vvv -t install`, `stapler validate`, test on a clean Mac/VM with quarantine attribute.
6. Auto-update: **Sparkle 2** with EdDSA-signed appcast hosted on the website *(optional, v1.0.x)*.
7. `scripts/release.sh` does 1–5; a tagged GitHub Actions workflow runs it with secrets (cert .p12, notary key) and uploads the DMG to GitHub Releases. Website: simple static page (download button, screenshots, checksum, requirements).

## 10. Milestones

| M | Goal | Done when |
|---|---|---|
| **M0 Spike** | Repo skeleton, MIT license, CI; SwiftDocX evaluation against corpus; TextKit decision; ADRs 0001/0002 | We know the DOCX library path and engine choice |
| **M1 Skeleton** | `NSDocument` app with **autosave in place (§5.4)**: opens a `.docx`, shows text with basic formatting, persists edits without any Save action; Saved/Saving status; menus; toolbar stub | Open → type → close/quit with no prompt → file on disk is current and opens in Word; `kill -9` loses ≤ a few seconds |
| **M2 Formatting** | Format bar, styles/headings, lists, alignment, spacing, ruler, find/replace, undo | All §4 text/paragraph features work and round-trip |
| **M3 Insert & page** | Tables, images, links, page break, page setup, PDF export, print | PDF output paginates correctly; images/tables round-trip |
| **M4 Polish** | Outline sidebar, dark mode pass, accessibility, localization (EN/ES), Settings, icon | Passes accessibility audit; strings fully localized |
| **M5 Release** | Signing, notarization, DMG, website, README, v1.0 tag | Notarized DMG installs on a clean Mac |
| **v1.1** | Paginated page view, headers/footers (if deferred), TOC, footnotes | — |

## 11. Working agreements for Claude Code

- Work milestone by milestone; end each with a runnable build and a short `docs/STATUS.md` update.
- Prefer small, reviewable commits; one concern per commit.
- Prefer AppKit/SwiftUI built-ins over custom drawing. Ask before adding any dependency; record the license.
- When a native control can't do something, write down the trade-off in an ADR instead of silently building a custom control.
- Never silently drop unsupported DOCX content (see round-trip policy); add a fixture for every fidelity bug fixed.
- Keep the app launchable and the main branch green.
- Open questions to resolve with the human early: Sparkle yes/no, header/footer in 1.0 or 1.1, domain/website host.
- Resolved (2026-11-04): unnamed documents are system drafts until named (ADR 0003); Word-authored originals get a private backup copy plus Versions (ADR 0004); minimum macOS version is **macOS 26**; the app is **sandboxed**.

## 12. First prompt to give Claude Code

> Read `BOOTSTRAP.md`. Start Milestone 0: create the repo skeleton (Xcode project for an arm64 macOS app named Libretilla, MIT `LICENSE`, `.gitignore`, `README.md`, GitHub Actions CI), then build the SwiftDocX evaluation spike against a fixture corpus you generate, and write ADR 0001 and 0002 with your recommendation. Ask me before choosing anything listed under "Open questions".
