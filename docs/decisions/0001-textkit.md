# 0001. Text engine: TextKit 1

- **Status:** Proposed (Milestone 0 recommendation)
- **Date:** 2026-11-04
- **Evidence:** [`Tests/TextKitSpikeTests.swift`](../../Tests/TextKitSpikeTests.swift), run on macOS 26.5 / Xcode 26.6 / M-series

## Context

Cartilla uses `NSTextView` for editing and layout (bootstrap §5.1). On macOS 26 a plain `NSTextView()` uses
**TextKit 2** (`NSTextLayoutManager`). The view switches itself to **TextKit 1** (`NSLayoutManager`) when it meets
something TK2 can't handle, or when any code touches `.layoutManager`. We have to pick one engine deliberately.
A view that changes engine at runtime is the worst outcome: behaviour, performance and bugs would depend on what
the user happens to paste.

Requirements that matter here:

- **Tables** (v1 scope, M3) map naturally to `NSTextTable` / `NSTextTableBlock`, the only native rich-text table
  model, and the one AppKit's RTF/HTML importers produce.
- **Printing/PDF must paginate correctly from day one** (R3).
- **True paginated page view** in v1.1, done the TextEdit way: one text container per page.
- Typing must feel instant on a 100-page document.

## What the spike measured

| # | Question | TextKit 1 | TextKit 2 |
|---|---|---|---|
| 1 | Default for `NSTextView()` on macOS 26 | – | ✅ yes |
| 2 | Does `NSTextTable` content force a fallback? | n/a | ❌ **No fallback, and no table either.** The view stays on TK2 but ignores the text blocks: the 2×2 cells are laid out stacked at x=5, like plain paragraphs |
| 3 | Table geometry for the same content | ✅ Cells side by side: `r0c1` at x=239 on the same line as `r0c0`; row 2 below | ❌ Stacked, as above |
| 4 | Typing and a newline inside a "cell" | – | Still TK2, still not a table |
| 5 | `NSTextList` bullets | ✅ | ✅ Stay on TK2 |
| 6 | Touching `.layoutManager` | – | Forces a permanent fallback to TK1 |
| 7 | `NSPrintOperation` → PDF, 65k words | 103 pages, 0.3 s | 103 pages, 0.4 s |
| 8 | Text flowing through one container per page | ✅ 103 `NSTextContainer`s laid out in 0.09 s | ❌ `NSTextLayoutManager` has one `textContainer`. Pages would need a layout manager per page or custom fragment placement |
| 9 | Insert 1 char mid-document + relayout, 65k words (offscreen) | 1.2 ms/keystroke (non-contiguous layout) | 0.45 ms/keystroke |

Row 9 is only a proxy: offscreen and without real drawing. Both engines are an order of magnitude under the 16 ms
frame budget, so typing latency doesn't decide this.

Row 2 overturned my expectation that tables trigger a fallback. On macOS 26.5 TK2 accepts them silently and draws
them wrong. That is worse than a fallback, because nothing tells us it happened.

## Decision

Use **TextKit 1, explicitly and only.** Build every document text view as `NSTextView(usingTextLayoutManager: false)`
(or with an explicit `NSTextStorage → NSLayoutManager → NSTextContainer` stack), with
`allowsNonContiguousLayout = true`.

- Tables use `NSTextTable` / `NSTextTableBlock` and go through the `AttributedStringBridge` (ADR 0002).
- Printing and PDF use `NSPrintOperation` over a print view that shares the `NSTextStorage`.
- The v1.1 paginated view uses one `NSTextContainer` per page on a single `NSLayoutManager`. That's the
  TextEdit "Wrap to Page" design, and the spike showed it works for 100+ pages.

## Consequences

- ✅ Tables, printing and future pagination all use mature, documented AppKit paths we don't have to build.
- ✅ The engine never changes at runtime, so behaviour and bugs are reproducible.
- ⚠️ We give up TK2's viewport-based layout. On very large documents TK1 non-contiguous layout is slower, though
  still well within budget for 100+ pages (row 9). Re-measure on a real 100-page `.docx` in M1.
- ⚠️ Some newer AppKit text features only fully work on TK2, such as the full in-line Writing Tools experience.
  These are non-goals for Cartilla (no AI), so the cost is acceptable.
- ⚠️ TK1 is in maintenance mode at Apple. It isn't deprecated, and TextEdit, Pages-style apps and Xcode's
  non-source editors still depend on it.
- 🔁 **Revisit when** `testTextKit2TableGeometryAndEditing` fails (TK2 has learned table layout) **and** TK2 offers
  multi-container pagination. The `AttributedStringBridge` keeps the model independent of the engine, so a later
  switch only touches `Editor/`.
- Follow-up for M1: change `EditorViewController` from the default initializer to the explicit TK1 one.
  Add a debug assertion that `textLayoutManager == nil`.
