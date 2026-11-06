# Releasing

Libretilla ships as a drag-to-install DMG on GitHub Releases, signed with a Developer ID and notarized.
Installed copies update themselves with [Sparkle](https://sparkle-project.org) 2.10.0 (MIT): Libretilla ▸ Check
for Updates…, and Sparkle checks on its own once a day after asking the user on the second launch. There is no
App Store build. The process is the one [Macsima](https://github.com/escalant3/macsima) uses, adapted for the
sandbox.

## How updates work

- `SUFeedURL` is `https://github.com/escalant3/libretilla/releases/latest/download/appcast.xml`, so the feed is
  the `appcast.xml` attached to the release GitHub marks as latest. Every release must attach a fresh one, and the
  repository must stay public.
- Sparkle installs an update only if its EdDSA signature matches `SUPublicEDKey` and the new app is signed by the
  same Developer ID team as the installed one.
- **The app is sandboxed and has no network entitlement.** Sparkle's two XPC services stay in the framework: the
  Downloader (sandboxed, with its own network entitlement) fetches the feed and the update, and the Installer
  replaces the app. `SUEnableDownloaderService` and `SUEnableInstallerLauncherService` turn them on, and the
  `$(PRODUCT_BUNDLE_IDENTIFIER)-spks` / `-spki` mach-lookup exceptions let the app reach the installer.
  `scripts/make-dmg.sh` signs them inside out (never `--deep`), keeps the Downloader's and the app's
  entitlements, and refuses to build if the sandbox entitlements went missing or `get-task-allow` is present.
- Sparkle sends no system profile (`SUEnableSystemProfiling` is off).
- Debug builds never start the updater, so UI tests never see its dialogs. The menu item is there but disabled.

## One-time setup

1. **Build once** so Sparkle's tools are on disk:

       scripts/make-dmg.sh

   It stops with "SPARKLE_PUBLIC_KEY is empty" until step 2 is done; the tools are there anyway. The commands
   below call them through `sparkle=build/xcode-release/SourcePackages/artifacts/sparkle/Sparkle/bin`.

2. **EdDSA key.** This stores the private key in your login keychain and prints the public key:

       sparkle=build/xcode-release/SourcePackages/artifacts/sparkle/Sparkle/bin
       $sparkle/generate_keys --account libretilla

   Put the public key in `project.yml` as `SPARKLE_PUBLIC_KEY`, run `xcodegen generate`, and commit. Back up the
   private key somewhere safe outside the repository (`$sparkle/generate_keys --account libretilla -x <file>`):
   without it, installed copies can never be updated again. `--account libretilla` keeps it apart from
   Macsima's key; pass the same `--account` to `generate_appcast` below.

3. **Notary credentials**, with an app-specific password from account.apple.com:

       xcrun notarytool store-credentials libretilla-notary --apple-id <your Apple ID> --team-id QAGRGP6VBT

4. **Signing identity.** `security find-identity -v -p codesigning` shows it:
   `Developer ID Application: Diego Muñoz Escalante (QAGRGP6VBT)`.

## Each release

Set the version once, the same value as `MARKETING_VERSION`:

    version=0.9
    sparkle=build/xcode-release/SourcePackages/artifacts/sparkle/Sparkle/bin

1. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml` (the build number must grow every
   time; Sparkle compares it), run `xcodegen generate`, and commit. Run the tests and `scripts/check.sh`.
2. Build, sign and verify:

       SIGN_IDENTITY="Developer ID Application: Diego Muñoz Escalante (QAGRGP6VBT)" scripts/make-dmg.sh

3. Notarize and staple. Do this before step 4: stapling changes the DMG, and Sparkle's signature must cover the
   final file.

       xcrun notarytool submit build/release/Libretilla-$version.dmg --keychain-profile libretilla-notary --wait
       xcrun stapler staple build/release/Libretilla-$version.dmg
       xcrun stapler validate build/release/Libretilla-$version.dmg
       spctl --assess --type open --context context:primary-signature -v build/release/Libretilla-$version.dmg

   If notarization is rejected, `xcrun notarytool log <submission id> --keychain-profile libretilla-notary` says
   why.

4. Update the appcast. `generate_appcast` signs the DMG with the key in your keychain and keeps the entries
   already in the folder's `appcast.xml`. If `build/release/updates` is gone, first download the current
   `appcast.xml` from the latest release into it (`gh release download --pattern appcast.xml -D build/release/updates`).
   Release notes go next to the DMG as `Libretilla-$version.md`. `--embed-release-notes` puts them inside the
   appcast; without it the appcast links to a `.md` that isn't a release asset (Macsima 0.3 had that broken link).

       mkdir -p build/release/updates
       cp build/release/Libretilla-$version.dmg build/release/updates/
       $EDITOR build/release/updates/Libretilla-$version.md
       $sparkle/generate_appcast --account libretilla --embed-release-notes --download-url-prefix \
           https://github.com/escalant3/libretilla/releases/download/v$version/ build/release/updates

   Then check `appcast.xml`:
   - `--download-url-prefix` rewrites every entry's URL, older releases' too. Point each older DMG back at its
     own tag (`.../download/v0.9/Libretilla-0.9.dmg`). Editing the file is safe: the signatures are per file,
     and the feed itself is not signed.
   - With an older DMG in the folder, it also makes a delta update (`Libretilla<build>-<old build>.delta`) listed
     under the new tag. Attach it in step 5, or Sparkle's delta download fails and it falls back to the full DMG.

5. Tag and publish. Attach the DMG, the delta and the appcast, put the DMG's SHA-256 in the notes (the website
   shows it), and don't mark the release as a pre-release (the feed follows "latest"):

       shasum -a 256 build/release/Libretilla-$version.dmg
       git tag v$version && git push origin v$version
       gh release create v$version build/release/Libretilla-$version.dmg build/release/updates/*.delta \
           build/release/updates/appcast.xml \
           --title "Libretilla $version" --notes-file build/release/updates/Libretilla-$version.md

6. Check: an installed older copy finds the update under Libretilla ▸ Check for Updates…, installs it and
   relaunches as the new version with its documents and settings intact.

## The DMG window

The image opens in a small Finder window with large icons, the app on the left and Applications on the right, and
shows the app's icon as the disk's. The layout is `scripts/dmg/DS_Store`, which `make-dmg.sh` copies into every
image as `.DS_Store`. To change it, edit and run `scripts/dmg/make-layout.sh` (it scripts Finder, which asks for
permission the first time) and commit the new file.

## Checking a release on a clean Mac

Before 1.0, and whenever the signing or the Sparkle setup changes: on a fresh macOS 26 VM or a second Mac,
download the DMG with a browser (so it carries the quarantine flag), then

    spctl -a -vvv -t install ~/Downloads/Libretilla-$version.dmg
    xcrun stapler validate ~/Downloads/Libretilla-$version.dmg

Open it, drag Libretilla to Applications, and launch it: no Gatekeeper warning beyond the usual "downloaded from
the internet" prompt. Open a `.docx` from Finder, edit, quit, reopen.

## Testing an update locally

Without touching the real key or feed: make a throwaway key, a separate bundle id (so its sandbox container is
separate too) and a feed on `127.0.0.1`. `make-dmg.sh` takes `SPARKLE_FEED_URL`, `SPARKLE_PUBLIC_KEY`,
`MARKETING_VERSION`, `CURRENT_PROJECT_VERSION` and `PRODUCT_BUNDLE_IDENTIFIER` from the environment. Build an
older and a newer version, run `generate_appcast --ed-key-file <key>` over a folder with the newer DMG, serve the
folder with `python3 -m http.server`, install the older app, and use Check for Updates….

## Licenses

Libretilla is MIT. The DMG also carries ZIPFoundation and Sparkle (MIT, with the BSD, MIT and zlib notices of the
code Sparkle bundles); their notices are in the About panel (`Resources/Credits.rtf`) and
`THIRD_PARTY_LICENSES.md`.
