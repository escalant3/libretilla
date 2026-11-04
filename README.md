# Cartilla

*Cartilla* (Spanish for "notebook") is a small, distraction-free word processor for macOS. **Its native file format
is `.docx`**: you open a Word document, write, and it's saved back to that same file automatically, with no Save
dialogs. You can export to PDF. There's no ribbon, no AI and no cloud.

> **Status: Milestone 2.** Opens `.docx`, autosaves edits back to the same file losslessly, and has the
> everyday formatting tools: a format bar, Word styles and headings, bulleted and numbered lists, alignment,
> spacing, a ruler, and Find and Replace. Tables, images and links arrive in Milestone 3. See
> [`docs/STATUS.md`](docs/STATUS.md).

## Requirements

- Apple Silicon Mac (arm64 only), **macOS 26** or later
- To build: Xcode 26, plus [XcodeGen](https://github.com/yonaskolb/XcodeGen) only if you edit `project.yml`

## Build & run

```sh
open Cartilla.xcodeproj               # then ⌘R
# or
xcodebuild -project Cartilla.xcodeproj -scheme Cartilla -destination 'platform=macOS,arch=arm64' build
```

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
