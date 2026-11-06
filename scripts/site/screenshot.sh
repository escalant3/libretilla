#!/bin/zsh
# Retakes the website's screenshots (site/screenshot-light.png and -dark.png).
#
# Writes the sample document (scripts/site/sample.py), runs SiteScreenshotUITests
# once from a throwaway Xcode project in build/site (the test file is copied into
# UITests/ for the run and removed afterwards), then crops the empty canvas below
# the text and scales each window shot to 1600 px wide (scripts/site/crop.swift). Run it on a Retina display.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=build/site
rm -rf $out/shots.xcresult $out/attachments
mkdir -p $out
python3 scripts/site/sample.py "$PWD/$out/A small notebook.docx" >/dev/null

# xcodebuild adds Sparkle's pin to the package's Package.resolved: put the file back afterwards.
resolved=Packages/LibretillaDocx/Package.resolved
cp $resolved $out/Package.resolved
cp scripts/site/SiteScreenshotUITests.swift UITests/
trap "rm -f UITests/SiteScreenshotUITests.swift; cp $out/Package.resolved $resolved" EXIT
xcodegen generate --quiet --spec project.yml --project $out
# The spec also rewrites these from project.yml; they must come out unchanged.
git diff --exit-code --quiet -- App/Info.plist App/Libretilla.entitlements
TEST_RUNNER_LIBRETILLA_SITE_DOC="$PWD/$out/A small notebook.docx" xcodebuild test \
  -project $out/Libretilla.xcodeproj -scheme Libretilla -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath $out/DerivedData -only-testing:LibretillaUITests/SiteScreenshotUITests \
  -resultBundlePath $out/shots.xcresult -quiet \
  CODE_SIGN_ENTITLEMENTS="$PWD/App/Libretilla.entitlements" INFOPLIST_FILE="$PWD/App/Info.plist"

xcrun xcresulttool export attachments --path $out/shots.xcresult --output-path $out/attachments >/dev/null
for mode in light dark; do
  file=$(python3 -c 'import json,sys
for a in json.load(open(sys.argv[1]))[0]["attachments"]:
    if a["suggestedHumanReadableName"].startswith("site-" + sys.argv[2]): print(a["exportedFileName"])' \
    $out/attachments/manifest.json $mode)
  # Keep the window's top 1150 px (2x): title bar, toolbar and the page's text.
  swift scripts/site/crop.swift "$out/attachments/$file" site/screenshot-$mode.png 1150 1600
done
