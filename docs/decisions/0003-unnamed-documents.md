# 0003. New, unnamed documents: system drafts until named (the Pages/TextEdit model)

- **Status:** Accepted (2026-11-04)
- **Deciders:** project owner

## Context

Bootstrap §5.4 asks where a document lives between File ▸ New and the moment it gets a name. Options considered:

1. A system-managed draft until it's named. Closing an unnamed, non-empty document shows the standard "keep this
   document?" sheet. This is how Pages and TextEdit work.
2. A draft that is filed automatically into a default folder on close, with no sheet.
3. A real `Untitled.docx` in a default folder (e.g. `~/Documents/Libretilla`) from the first keystroke.
4. Libretilla's iCloud Drive folder as the default location.
5. The app's own hidden storage, like Notes.

Libretilla is sandboxed, so options 2 and 3 would need a one-time folder grant, and option 4 would need the iCloud
capability. Option 1 needs neither.

## Decision

**Option 1.** Follow AppKit's standard document behaviour, the same as Pages and TextEdit:

- **New:** File ▸ New opens an "Untitled" window right away. Typing is autosaved as a system draft
  (`autosavesInPlace` + autosaved drafts, stored in the app's sandbox container). Nothing is written to the
  user's folders yet.
- **Quit, crash, power loss:** no prompt. Unnamed drafts come back on relaunch through window restoration and
  the autosave-information mechanism.
- **Naming:** at any time, by clicking the title in the title bar (system rename/move popover), File ▸ Save
  (`⌘S`), or File ▸ Rename…/Move To…. After that it's a real `.docx` that autosaves in place (§5.4). Typing is
  never blocked by a panel.
- **Closing an unnamed, non-empty document:** the standard system sheet asks the user to name and place it or
  delete it. **This is the one accepted exception to R9's "no save dialog, ever".** It only appears for documents
  that have never been named, and it's the platform's standard behaviour. Documents that already have a file
  never show a dialog.
- **Closing an empty unnamed document:** it's discarded silently.
- **Default location in the save sheet:** whatever AppKit remembers (the last folder used). Libretilla adds no
  custom default folder and no Settings option for one in v1.

## Consequences

- ✅ Almost no custom code: this is what `NSDocument` does out of the box. Libretilla mainly has to avoid breaking it.
- ✅ No sandbox folder grant, no iCloud capability, no untitled files piling up in Finder.
- ✅ Familiar to Mac users: identical to Pages and TextEdit.
- ⚠️ Until it's named, a document is invisible in Finder. Drafts live in
  `~/Library/Containers/app.libretilla.Libretilla/Data/Library/Autosave Information/`.
- ⚠️ The close sheet is a small departure from the Google Docs feel, accepted on purpose.
- Tests for M1:
  - New → type → quit → relaunch restores the draft.
  - `kill -9` while typing in an unnamed document loses at most a few seconds.
  - Closing an empty unnamed document shows no sheet.
  - Closing a non-empty unnamed document shows the system sheet, and Delete removes the draft.
  - A named document closes with no dialog.
- Out of scope here: the one-time backup of Word-authored originals before the first autosave (§5.4, hard case 5)
  is still open and moves to **ADR 0004**.
