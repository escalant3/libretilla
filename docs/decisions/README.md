# Architecture decision records

| # | Title | Status |
|---|---|---|
| [0001](0001-textkit.md) | Text engine: TextKit 2, with a tracked gap register | Accepted |
| [0002](0002-docx-library.md) | DOCX layer: our own lossless OOXML codec, built incrementally ([evaluation](0002-swiftdocx-evaluation.md)) | Accepted |
| [0003](0003-unnamed-documents.md) | New, unnamed documents: system drafts until named (Pages/TextEdit model) | Accepted |
| [0004](0004-original-backups.md) | Protecting Word-authored originals: private copy + Versions | Accepted |
| [0005](0005-formatting-model.md) | Formatting: Word properties are the truth, the display follows (commands, reconcile, lists) | Accepted |
| [0006](0006-tables.md) | Tables: drawn row attachments with a cell editor sheet (TextKit 2 can't lay out tables) | Accepted |
| [0007](0007-headers-footers.md) | Headers and footers: kept, printed, and edited in a sheet | Accepted |

Copy [`0000-template.md`](0000-template.md) for new records. Record a decision whenever a native control can't do
something, or before adding a dependency.
