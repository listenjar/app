#!/usr/bin/env bash
# Signs a built ListenJar.app ($1) with a Developer ID and the hardened
# runtime, inside out, then verifies it: tool/package-macos.sh before it
# notarizes, tool/reinstall-macos.sh before it installs.
#
#   LISTENJAR_SIGNING_IDENTITY   "Developer ID Application: … (TEAM)"; required
#   LISTENJAR_SIGNING_KEYCHAIN   the keychain holding it, if not the default
set -euo pipefail

app="${1:?Usage: tool/sign-macos.sh path/to/ListenJar.app}"
identity="${LISTENJAR_SIGNING_IDENTITY:?Set LISTENJAR_SIGNING_IDENTITY, the Developer ID to sign with}"
keychain="${LISTENJAR_SIGNING_KEYCHAIN:-}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

sign() {
  codesign --force --timestamp --options runtime --sign "$identity" ${keychain:+--keychain "$keychain"} "$@"
}
# Re-signs $1 with the entitlements Xcode resolved for it, less
# get-task-allow: Xcode adds that when it signs to run locally, and the notary
# service rejects it.
sign_entitled() {
  local entitlements
  entitlements="$work/$(basename "$1").entitlements"
  codesign --display --entitlements - --xml "$1" > "$entitlements"
  if [[ ! -s "$entitlements" ]]; then
    sign "$1"
    return
  fi
  /usr/libexec/PlistBuddy -c 'Delete :com.apple.security.get-task-allow' "$entitlements" 2>/dev/null || true
  sign --entitlements "$entitlements" "$1"
}

# Inside out: Sparkle's helpers as its documentation signs them, then every
# framework, the Share extension and the app, each keeping the entitlements
# Xcode resolved for it (the sandbox, Sparkle's services; sign_entitled).
sparkle="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$sparkle/XPCServices/Installer.xpc"
sign_entitled "$sparkle/XPCServices/Downloader.xpc"
sign "$sparkle/Autoupdate"
sign "$sparkle/Updater.app"
for framework in "$app"/Contents/Frameworks/*.framework; do sign "$framework"; done
for extension in "$app"/Contents/PlugIns/*.appex; do sign_entitled "$extension"; done
sign_entitled "$app"
codesign --verify --deep --strict "$app"
