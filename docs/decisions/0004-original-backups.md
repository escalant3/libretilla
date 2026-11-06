# 0004. Protecting Word-authored originals: private copy + Versions

- **Status:** Accepted (2026-11-04)
- **Deciders:** project owner

## Context

Libretilla autosaves over the user's real `.docx` (bootstrap §5.4). Until the lossless round-trip suite has proven
itself on real Word, LibreOffice and Google Docs files, a codec bug could damage a file the user cares about.
Bootstrap §5.4 hard case 5 asks for a one-time backup before the first autosave over a file Libretilla didn't create.

Libretilla is sandboxed. It can write the file the user opened, but not a sibling like `Report (original).docx`
without an extra folder permission.

## Decision

**Keep a private copy, and rely on Versions as well.**

- **Private copy.** Before the first save of an opened document in each session, Libretilla copies the **untouched
  original bytes** it read at open time into its sandbox container:
  `~/Library/Containers/app.libretilla.Libretilla/Data/Library/Application Support/Libretilla/Originals/`.
  - The copy is skipped when an identical copy (by SHA-256) already exists.
  - Copies are kept for **30 days**, then pruned at launch.
  - Unnamed drafts (ADR 0003) have no original, so they are never copied.
- **Restore.** File ▸ Restore Original… replaces the document's content with the most recent private copy. This is
  an ordinary edit: it can be undone, and it autosaves.
- **Versions.** On volumes that support it, macOS also keeps the "last opened" version
  (File ▸ Revert To ▸ Last Opened). That comes free with `NSDocument` and needs no code.

## Consequences

- ✅ Works on every volume, including exFAT, FAT and network shares without Versions. No prompts, and nothing
  added next to the user's file.
- ⚠️ The copies live in a hidden folder. Restore Original… is the user-facing way to reach them.
- ⚠️ Disk use is bounded by the 30-day pruning. Documents are small, so this is acceptable.
- 🔁 Revisit after the round-trip suite passes on a corpus of real Word files. The private copy may then become
  optional (a Settings switch) rather than always on.
