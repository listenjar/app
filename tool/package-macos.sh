#!/usr/bin/env bash
# Builds the release macOS app with Sparkle's update key and packages it as
# build/release/ListenJar-X.Y.Z-macos.dmg, the download and
# the update payload both (`moon run desktop:package-macos`).
#
#   LISTENJAR_UPDATE_PUBLIC_KEY  the Ed25519 public key updates are signed
#                                with (Info.plist's SUPublicEDKey); required
#   LISTENJAR_SIGNING_IDENTITY   "Developer ID Application: … (TEAM)": sign
#                                inside out with the hardened runtime, then
#                                notarize and staple the app and the DMG
#   LISTENJAR_NOTARY_PROFILE     notarytool's keychain profile for that
#   LISTENJAR_SIGNING_KEYCHAIN   the keychain holding both (tool/macos-signing.sh)
#
# Without an identity the app keeps its ad-hoc signature: enough to try the
# DMG and updates on this Mac, not to hand out.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

key="${LISTENJAR_UPDATE_PUBLIC_KEY:?Set LISTENJAR_UPDATE_PUBLIC_KEY, the Ed25519 public key updates are signed with}"
identity="${LISTENJAR_SIGNING_IDENTITY:-}"
keychain="${LISTENJAR_SIGNING_KEYCHAIN:-}"
version="$(node tool/release.ts identity | node -p 'JSON.parse(require("fs").readFileSync(0)).version')"
app=packages/desktop/build/macos/Build/Products/Release/ListenJar.app
out=build/release
dmg="$out/ListenJar-$version-macos.dmg"

(cd packages/desktop && flutter build macos --release)
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$app/Contents/Info.plist")" != "$key" ]]; then
  echo "The built app does not carry LISTENJAR_UPDATE_PUBLIC_KEY: run flutter clean and package again." >&2
  exit 1
fi

sign() {
  codesign --force --timestamp --options runtime --sign "$identity" ${keychain:+--keychain "$keychain"} "$@"
}
notarize() {
  xcrun notarytool submit "$1" --keychain-profile "${LISTENJAR_NOTARY_PROFILE:?Set LISTENJAR_NOTARY_PROFILE}" \
    ${keychain:+--keychain "$keychain"} --wait --timeout 30m
}

if [[ -n "$identity" ]]; then
  # Inside out: Sparkle's helpers as its documentation signs them, then every
  # framework, the Share extension and the app, each keeping the entitlements
  # Xcode resolved for it (the sandbox, Sparkle's services).
  sparkle="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
  sign "$sparkle/XPCServices/Installer.xpc"
  sign --preserve-metadata=entitlements "$sparkle/XPCServices/Downloader.xpc"
  sign "$sparkle/Autoupdate"
  sign "$sparkle/Updater.app"
  for framework in "$app"/Contents/Frameworks/*.framework; do sign "$framework"; done
  for extension in "$app"/Contents/PlugIns/*.appex; do sign --preserve-metadata=entitlements "$extension"; done
  sign --preserve-metadata=entitlements "$app"
  codesign --verify --deep --strict "$app"
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  ditto -c -k --keepParent "$app" "$work/ListenJar.zip"
  notarize "$work/ListenJar.zip"
  xcrun stapler staple "$app"
fi
codesign --verify --deep --strict "$app"

mkdir -p "$out"
staging="$(mktemp -d)"
cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"
rm -f "$dmg"
hdiutil create -quiet -volname ListenJar -srcfolder "$staging" -fs APFS -format ULFO "$dmg"
rm -rf "$staging"

if [[ -n "$identity" ]]; then
  sign "$dmg"
  notarize "$dmg"
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
  spctl --assess --type execute --verbose=2 "$app"
fi
echo "$dmg"
