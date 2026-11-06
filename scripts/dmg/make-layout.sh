#!/bin/zsh
# Makes scripts/dmg/DS_Store, the Finder layout of the release image: a small window with the app on the left,
# Applications on the right, large icons, no toolbar or sidebar. scripts/make-dmg.sh copies it into every image as
# .DS_Store, so releases don't need Finder. Only rerun this to change the layout (it scripts Finder, which asks for
# permission the first time). Needs a Release build (scripts/make-dmg.sh builds one).
set -euo pipefail
cd "$(dirname "$0")/../.."
app=build/xcode-release/Build/Products/Release/Libretilla.app
[[ -d $app ]] || { echo "Build first: scripts/make-dmg.sh" >&2; exit 1 }
work=$(mktemp -d)
volume="Libretilla layout"
mkdir $work/src
ditto $app $work/src/Libretilla.app
ln -s /Applications $work/src/Applications
hdiutil create -quiet -volname $volume -srcfolder $work/src -fs APFS -format UDRW $work/layout.dmg
mount=$(hdiutil attach -nobrowse -noverify $work/layout.dmg | awk -F'\t' '/\/Volumes\// { print $NF }')
trap "hdiutil detach -quiet '$mount' 2>/dev/null || true; rm -rf '$work'" EXIT

# Window 480 × 260 points; 112-point icons, centred on two columns.
osascript <<APPLESCRIPT
tell application "Finder"
    set d to disk "$volume"
    open d
    set w to container window of d
    set current view of w to icon view
    set toolbar visible of w to false
    set statusbar visible of w to false
    set sidebar width of w to 0
    set bounds of w to {200, 200, 680, 460}
    set o to icon view options of w
    set arrangement of o to not arranged
    set icon size of o to 112
    set text size of o to 13
    set label position of o to bottom
    set shows item info of o to false
    set shows icon preview of o to true
    set position of item "Libretilla.app" of d to {130, 115}
    set position of item "Applications" of d to {350, 115}
    update d without registering applications
    delay 1
    close w
end tell
APPLESCRIPT
# Finder writes .DS_Store lazily.
for _ in {1..20}; do [[ -f "$mount/.DS_Store" ]] && break; sleep 0.5; done
sleep 1
cp "$mount/.DS_Store" scripts/dmg/DS_Store
echo "scripts/dmg/DS_Store: $(stat -f %z scripts/dmg/DS_Store) bytes"
