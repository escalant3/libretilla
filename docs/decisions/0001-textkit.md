# 0001. Text engine: TextKit 2, with a tracked gap register

- **Status:** Accepted (2026-11-04)
- **Evidence:** [`Tests/TextKit2CompatibilityTests.swift`](../../Tests/TextKit2CompatibilityTests.swift), run on macOS 26.5 /
  Xcode 26.6. Gap register: [`docs/TEXTKIT2_GAPS.md`](../TEXTKIT2_GAPS.md)

## Context

Cartilla uses `NSTextView` for editing and layout (bootstrap §5.1). On macOS 26 the view uses **TextKit 2**
(`NSTextLayoutManager`) by default. It falls back to **TextKit 1** (`NSLayoutManager`) if code touches
`.layoutManager`. The engine has to be chosen deliberately, because a view that switches engine at runtime behaves
unpredictably.

The Milestone 0 spike compared the two engines on macOS 26.5:

| Question | TextKit 1 | TextKit 2 |
|---|---|---|
| Default for `NSTextView()` | – | ✅ |
| `NSTextList` bullets | ✅ | ✅ no fallback |
| `NSTextTable` (2×2 table) | ✅ laid out | ⚠️ no fallback, but **cells stacked as plain paragraphs** |
| One text container per page (paginated view) | ✅ text flows through 103 containers, 0.09 s | ⚠️ one container per layout manager; layout stops at the page bottom, with no flow into a next page |
| `NSPrintOperation` → PDF, 65k words | 103 pages | 103 pages, stays on TK2 |
| Insert + relayout mid-document, 65k words (offscreen proxy) | 1.2 ms/key | 0.45 ms/key |
| Touching `.layoutManager` | – | permanent fallback to TK1 |

TextKit 1 covered more of the v1 scope out of the box. TextKit 2 is the engine Apple is investing in: it's faster
on large documents and gets new AppKit text features first.

## Decision

Use **TextKit 2**. Every document text view is created with `NSTextView(usingTextLayoutManager: true)`.

- **No TextKit 1 APIs** in Cartilla code: no `layoutManager`, glyph ranges or `NSLayoutManager` delegates. Use
  `textLayoutManager`, `textContentStorage`, text layout fragments and `NSTextRange`.
- **Fallback detection:** `EditorViewController` logs a fault (`app.cartilla.Cartilla`, category `Editor`) on
  `willSwitchToNSLayoutManagerNotification`. Each fallback found this way becomes a new entry in the gap register.
- **Track incompatibilities, don't hide them.** Every gap goes in [`docs/TEXTKIT2_GAPS.md`](../TEXTKIT2_GAPS.md),
  with its impact, a workaround and a test. A test named `testGap…` pins the current limitation. If it starts
  failing, TextKit 2 improved: update the register.
- We will try to fix the gaps toward the end of the project, either because Apple improves TextKit 2 or with our
  own TextKit 2 code (custom layout fragments or attachment view providers). TextKit 1 isn't a fallback plan.

## Consequences

- ✅ Modern, viewport-based layout. Typing cost on large documents was the best measured.
- ✅ The engine stays fixed, and anything that forces a fallback shows up in the logs.
- ⚠️ **Tables (G1)** don't render as tables in TK2. The DOCX layer must still read, preserve and write tables
  losslessly (ADR 0002). Only the on-screen layout is degraded until G1 is solved.
- ⚠️ **Paginated page view (G2)** in v1.1 needs a TK2-specific design, such as one layout manager per page or
  custom fragment placement.
- ⚠️ Print and PDF output follow on-screen layout, so they inherit G1.
- 🔁 **Revisit** if the gap list grows large enough to put v1 scope at risk.
