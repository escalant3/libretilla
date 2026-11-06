# Third-party licenses

Every dependency's license is checked **before** it is added (no GPL/LGPL/AGPL).
Keep this file in sync with `Package.resolved` / `project.yml`.

## Shipped in the app

| Package | Version | License | Used by | Added |
|---|---|---|---|---|
| [weichsel/ZIPFoundation](https://github.com/weichsel/ZIPFoundation) | 0.9.20 (`upToNextMinor`) | MIT, © 2017–2025 Thomas Zoechling | `Packages/LibretillaDocx`: zip read/write of `.docx` packages (ADR 0002) | 2026-11-04 |

The MIT license requires including each copyright notice with the app. The notices are bundled in
`Resources/Credits.rtf`, which the standard About panel shows (Libretilla ▸ About Libretilla). Add a new
dependency's notice there in the same commit that adds the dependency.

## Development / evaluation only (not linked into Libretilla.app)

_None._
