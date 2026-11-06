#!/bin/zsh
# Builds the Release app and packs it into build/release/Libretilla-<version>.dmg.
# See docs/RELEASING.md for the whole release, including notarization.
#
#   scripts/make-dmg.sh                          ad-hoc signed, for local tries
#   SIGN_IDENTITY="Developer ID Application: …" scripts/make-dmg.sh
#                                                signed for notarization
#
# The version and Sparkle settings come from project.yml. For a test build, SPARKLE_FEED_URL,
# SPARKLE_PUBLIC_KEY, MARKETING_VERSION, CURRENT_PROJECT_VERSION and PRODUCT_BUNDLE_IDENTIFIER in the
# environment override them.
set -euo pipefail
cd "$(dirname "$0")/.."

identity=${SIGN_IDENTITY:--}
derived=build/xcode-release
out=build/release

overrides=()
for setting in SPARKLE_FEED_URL SPARKLE_PUBLIC_KEY MARKETING_VERSION CURRENT_PROJECT_VERSION PRODUCT_BUNDLE_IDENTIFIER; do
  [[ -n ${(P)setting:-} ]] && overrides+=("$setting=${(P)setting}")
done

xcodegen generate --quiet
# Without CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO, Xcode adds get-task-allow to an ad-hoc Release build too.
xcodebuild -project Libretilla.xcodeproj -scheme Libretilla -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath $derived $overrides \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO build -quiet

built=$derived/Build/Products/Release/Libretilla.app
plist() { /usr/libexec/PlistBuddy -c "Print $1" $built/Contents/Info.plist }
version=$(plist CFBundleShortVersionString)
build=$(plist CFBundleVersion)
if [[ -z $(plist SUPublicEDKey) ]]; then
  echo "SPARKLE_PUBLIC_KEY is empty in project.yml: the app could never check for updates (docs/RELEASING.md)." >&2
  exit 1
fi

rm -rf $out/stage && mkdir -p $out/stage
ditto $built $out/stage/Libretilla.app
app=$out/stage/Libretilla.app
sparkle=$app/Contents/Frameworks/Sparkle.framework

# Libretilla is sandboxed, so Sparkle's XPC services stay: the Downloader fetches updates (the app has no
# network entitlement) and the Installer replaces the app. Sign inside out, as Sparkle's documentation says
# (never --deep). The Downloader and the app keep the entitlements they were built with. A Developer ID needs
# the hardened runtime and a secure timestamp for notarization.
flags=(--force --sign $identity)
[[ $identity != - ]] && flags+=(--options runtime --timestamp)
codesign $flags $sparkle/Versions/B/XPCServices/Installer.xpc
codesign $flags --preserve-metadata=entitlements $sparkle/Versions/B/XPCServices/Downloader.xpc
codesign $flags $sparkle/Versions/B/Autoupdate
codesign $flags $sparkle/Versions/B/Updater.app
codesign $flags $sparkle
codesign $flags --preserve-metadata=entitlements $app
codesign --verify --deep --strict $app

# The sandbox (and its Sparkle exceptions) must survive the re-signing; a debugging entitlement must not
# ship (notarization rejects it).
entitlements=$(codesign -d --entitlements - --xml $app 2>/dev/null | plutil -convert xml1 -o - -)
for key in com.apple.security.app-sandbox com.apple.security.files.user-selected.read-write \
    com.apple.security.temporary-exception.mach-lookup.global-name; do
  [[ $entitlements == *"<key>$key</key>"* ]] || { echo "Signed app lost the $key entitlement." >&2; exit 1 }
done
[[ $entitlements != *get-task-allow* ]] || { echo "Signed app has get-task-allow: not a Release build?" >&2; exit 1 }

# Drag-to-install image: the app and a link to /Applications, in a small window with large icons
# (scripts/dmg/DS_Store, made by scripts/dmg/make-layout.sh), and the app's icon as the disk's.
ln -s /Applications $out/stage/Applications
cp scripts/dmg/DS_Store $out/stage/.DS_Store
cp $app/Contents/Resources/AppIcon.icns $out/stage/.VolumeIcon.icns
dmg=$out/Libretilla-$version.dmg
rm -f $dmg $out/rw.dmg
hdiutil create -quiet -volname "Libretilla $version" -srcfolder $out/stage -fs APFS -format UDRW $out/rw.dmg
# The volume shows its .VolumeIcon.icns only with the custom-icon flag on its root, which the image must carry.
mount=$(hdiutil attach -nobrowse -noverify -noautoopen $out/rw.dmg | awk -F'\t' '/\/Volumes\// { print $NF }')
SetFile -a C "$mount"
hdiutil detach -quiet "$mount"
hdiutil convert -quiet $out/rw.dmg -format UDZO -o $dmg
rm -f $out/rw.dmg
[[ $identity != - ]] && codesign --force --sign $identity --timestamp $dmg
rm -rf $out/stage

echo "$dmg  (version $version, build $build, signed with ${identity/#-/ad-hoc})"
