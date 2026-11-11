# Libretilla

*Libretilla* is Spanish for "small notebook". It's a small, distraction-free word processor for macOS, and **its
native file format is `.docx`**. Open a Word document, write, and your changes are saved back to that same file
automatically. There are no Save dialogs. When you're done, export to PDF.

> **Status: Milestone 4 (pre-release).** Libretilla opens `.docx` files and autosaves edits back to the same file
> without losing anything. It has the everyday formatting tools, tables, images, links, page setup, PDF export, an
> outline sidebar, Dark Mode, and English and Spanish throughout. Signed releases are next. See
> [`docs/STATUS.md`](docs/STATUS.md).

## Principles

- **Minimal.** A menu bar, one compact toolbar, a formatting bar and an optional ruler. No ribbon.
- **Small.** One focused app with two dependencies (ZIPFoundation and Sparkle). No AI, no cloud, no accounts, no
  telemetry.
- **Distraction-free.** A clean page on a quiet canvas. You never have to think about saving.
- **Word-compatible.** Files open and save without losing data. Parts of a document that Libretilla doesn't edit,
  including Word features it has no UI for, are written back byte for byte.

## Native by design

Libretilla is a plain AppKit app built from standard macOS controls, so it gets the platform's best features for free
and never fights them:

- **Dark Mode** follows the system, including the page itself. It's display only: printing and PDFs always come out
  on white paper.
- **System autosave and Versions.** Edits are saved in place as you type. File ▸ Browse All Versions… brings back
  earlier states, and the standard Revert and Duplicate commands work as they do in every Mac app.
- **Crisp text on Retina displays.** TextKit 2 renders text at the screen's full resolution, at any zoom.
- **The system's writing tools:** spell and grammar checking, autocorrect, and the native find & replace bar.
- **Window tabs, full screen, Open Recent, Print** and the standard keyboard shortcuts.
- **Accessibility.** VoiceOver labels throughout, with a headings rotor for moving around a document.
- **Sandboxed, with no network access.** Libretilla only sees the files you open with it. The one connection is
  the update check, made by Sparkle's sandboxed helper; it sends nothing about you or your documents.

## Requirements

- Apple Silicon Mac (arm64 only), **macOS 26** or later
- To build: Xcode 26, plus [XcodeGen](https://github.com/yonaskolb/XcodeGen) only if you edit `project.yml`

## Build & run

In Xcode: `open Libretilla.xcodeproj`, then ⌘R.

From the terminal, without opening Xcode (Xcode 26 must still be installed, because `xcodebuild` ships with it):

```sh
xcodebuild -project Libretilla.xcodeproj -scheme Libretilla -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/Libretilla.app                       # launch
open -a build/DerivedData/Build/Products/Debug/Libretilla.app ~/Documents/Some.docx  # open a file with it
```

The build is ad-hoc signed, which is enough to run it on the Mac that built it. `build/` is git-ignored.
Open documents through `open` (or Finder): the sandbox only grants access to files opened that way.

> **Libretilla autosaves over the file you open, so try it on a copy first.** It keeps a private copy of each
> original for 30 days (File ▸ Restore Original…), but that is a safety net, not a backup.

`Libretilla.xcodeproj` is generated from `project.yml` and committed. After changing `project.yml`, run
`xcodegen generate` and commit both files. CI fails if they drift apart.

## Test

```sh
xcodebuild test -project Libretilla.xcodeproj -scheme Libretilla -destination 'platform=macOS,arch=arm64'
(cd Packages/LibretillaDocx && swift test)
```

UI tests put their windows on the Mac's built-in display, whichever display has the menu bar (an external 1×
monitor makes the accessibility audit's contrast checks fail). Choose another with
`TEST_RUNNER_LIBRETILLA_UI_TEST_SCREEN="<display name>"` (or `main`) before `xcodebuild test`.

Lint: `find App Document Editor UI Tests UITests Packages/LibretillaDocx -name '*.swift' -not -path '*/.build/*' -print0 | xargs -0 swift format lint --strict`
(swift-format ships with Xcode; config in `.swift-format`). Format files one at a time with
`swift format format --in-place <file>`: in swift-format 6.3, `--in-place` only rewrites the first file when given several.

`scripts/check.sh` runs CI's quick checks. To run it before every push: `git config core.hooksPath .githooks`.

## Layout

| Path | What |
|---|---|
| `App/` | Entry point, app delegate, main menu, Info.plist, entitlements (sandboxed) |
| `Document/` | `NSDocument` subclass (autosave in place) and window controller |
| `Editor/` | Text view and page canvas (TextKit 2: [ADR 0001](docs/decisions/0001-textkit.md), [known gaps](docs/TEXTKIT2_GAPS.md)) |
| `UI/` | Toolbar, format bar, outline, settings, save status |
| `Packages/LibretillaDocx/` | `DocxCodec`, document model, attributed-string bridge ([ADR 0002](docs/decisions/0002-docx-library.md)) |
| `Resources/` | Assets, `Localizable.xcstrings` (English, Spanish) |
| `Fixtures/` | `.docx` test corpus ([README](Fixtures/README.md)) |
| `scripts/` | Checks, fixture generators, icon renderer |
| `docs/decisions/` | Architecture decision records |

## License

[MIT](LICENSE). Third-party notices: [`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md).

**Absolutely no warranty.** Libretilla is provided "as is", without warranty of any kind, express or implied. It
writes directly to your documents, so keep backups. In no event shall the authors be liable for any claim, damages
or other liability arising from the use of this software. See [LICENSE](LICENSE) for the full terms.

"Word" and ".docx" are used descriptively only. Libretilla is not affiliated with Microsoft.
