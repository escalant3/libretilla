#!/bin/sh
# CI's quick checks (.github/workflows/ci.yml), run locally before pushing: swift format lint, the Xcode project
# in sync with project.yml, and a reproducible fixture corpus. Tests are separate (swift test, xcodebuild test).
# The .githooks/pre-push hook runs this; enable it once per clone with `git config core.hooksPath .githooks`.
set -eu
cd "$(dirname "$0")/.."

echo "› swift format lint --strict"
find App Document Editor UI Tests UITests Packages/LibretillaDocx \
    -name '*.swift' -not -path '*/.build/*' -print0 | xargs -0 swift format lint --strict

echo "› Xcode project in sync with project.yml"
xcodegen generate --quiet
git diff --exit-code -- Libretilla.xcodeproj App/Info.plist App/Libretilla.entitlements

echo "› Fixture corpus is reproducible"
python3 scripts/fixtures/make_corpus.py >/dev/null
git diff --exit-code -- Fixtures/generated Resources/Blank.docx

echo "✓ All checks passed"
