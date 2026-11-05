# Cartilla

*Cartilla* (Spanish for "notebook") is a small, distraction-free word processor for macOS. **Its native file format
is `.docx`**: you open a Word document, write, and it's saved back to that same file automatically, with no Save
dialogs. You can export to PDF. There's no ribbon, no AI and no cloud.

> **Status: Milestone 4.** Opens `.docx` and autosaves edits back to the same file, losslessly. It has the
> everyday formatting tools, plus tables, images, links, page setup and PDF export. M4 adds an outline sidebar,
> a Dark Mode page, VoiceOver headings, Settings, and English and Spanish throughout. Release work (signing,
> DMG) is next. See [`docs/STATUS.md`](docs/STATUS.md).

## Requirements

- Apple Silicon Mac (arm64 only), **macOS 26** or later
- To build: Xcode 26, plus [XcodeGen](https://github.com/yonaskolb/XcodeGen) only if you edit `project.yml`

## Build & run

In Xcode: `open Cartilla.xcodeproj`, then ⌘R.

From the terminal, without opening Xcode (Xcode 26 must still be installed, because `xcodebuild` ships with it):

```sh
xcodebuild -project Cartilla.xcodeproj -scheme Cartilla -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/Cartilla.app                       # launch
open -a build/DerivedData/Build/Products/Debug/Cartilla.app ~/Documents/Some.docx  # open a file with it
```

The build is ad-hoc signed, which is enough to run it on the Mac that built it. `build/` is git-ignored.
Opening a document through `open` (or Finder) matters, because the sandbox only grants access to files opened that
way. Cartilla autosaves over the file you open, so try it on a copy.

`Cartilla.xcodeproj` is generated from `project.yml` and committed. After changing `project.yml`, run
`xcodegen generate` and commit both files. CI fails if they drift apart.

## Test

```sh
xcodebuild test -project Cartilla.xcodeproj -scheme Cartilla -destination 'platform=macOS,arch=arm64'
(cd Packages/CartillaDocx && swift test)
```

Lint: `find App Document Editor UI Tests UITests Packages/CartillaDocx -name '*.swift' -not -path '*/.build/*' -print0 | xargs -0 swift format lint --strict`
(swift-format ships with Xcode; config in `.swift-format`). Format files one at a time with
`swift format format --in-place <file>`: in swift-format 6.3, `--in-place` only rewrites the first file when given several.

## Layout

| Path | What |
|---|---|
| `App/` | Entry point, app delegate, main menu, Info.plist, entitlements (sandboxed) |
| `Document/` | `NSDocument` subclass (autosave in place) and window controller |
| `Editor/` | Text view and page canvas (TextKit 2: [ADR 0001](docs/decisions/0001-textkit.md), [known gaps](docs/TEXTKIT2_GAPS.md)) |
| `UI/` | Toolbar, format bar, save status |
| `Packages/CartillaDocx/` | `DocxCodec`, document model, attributed-string bridge ([ADR 0002](docs/decisions/0002-docx-library.md)) |
| `Resources/` | Assets, `Localizable.xcstrings` (English, Spanish) |
| `Fixtures/` | `.docx` test corpus ([README](Fixtures/README.md)) |
| `scripts/` | Fixture generators; later build, sign, notarize, DMG |
| `docs/decisions/` | Architecture decision records |

## License

[MIT](LICENSE). Third-party notices: [`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md).
"Word" and ".docx" are used descriptively only. Cartilla is not affiliated with Microsoft.
