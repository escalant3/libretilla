#!/bin/sh
# Produce Fixtures/generated/11-pandoc.docx with pandoc (deterministic via SOURCE_DATE_EPOCH).
set -eu
ROOT=$(CDPATH= cd "$(dirname "$0")/../.." && pwd)
CDPATH= cd "$ROOT/scripts/fixtures/assets"
SOURCE_DATE_EPOCH=1767225600 pandoc pandoc-source.md -o "$ROOT/Fixtures/generated/11-pandoc.docx"
echo "Fixtures/generated/11-pandoc.docx ($(pandoc --version | head -1))"
