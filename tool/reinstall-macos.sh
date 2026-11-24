#!/usr/bin/env bash
# Builds the release macOS app as a release would, with Sparkle's update key,
# signs it with this Mac's Developer ID (tool/sign-macos.sh) and replaces
# /Applications/ListenJar.app with it, quitting and reopening the app
# (`moon run desktop:reinstall`). It isn't notarized: an app built here
# carries no quarantine, so Gatekeeper never asks.
#
# The update key, the identity and the provisioning profile come from
# ~/.secrets/listenjar/desktop-signing (LISTENJAR_UPDATE_PUBLIC_KEY,
# LISTENJAR_SIGNING_IDENTITY and LISTENJAR_PROVISIONING_PROFILE override them);
# the Developer ID's certificate and key must be in the login keychain.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

secrets="$HOME/.secrets/listenjar/desktop-signing/macos"
LISTENJAR_UPDATE_PUBLIC_KEY="${LISTENJAR_UPDATE_PUBLIC_KEY:-$(cat "$secrets/update-public-key-base64")}"
LISTENJAR_SIGNING_IDENTITY="${LISTENJAR_SIGNING_IDENTITY:-$(node -p 'require(process.argv[1]).appleSigningIdentity' "$secrets/config.json")}"
# The Developer ID provisioning profile that lets the app use listenjar.com's
# passkeys, when there is one (tool/sign-macos.sh).
if [[ -z "${LISTENJAR_PROVISIONING_PROFILE:-}" && -f "$secrets/developer-id.provisionprofile" ]]; then
  LISTENJAR_PROVISIONING_PROFILE="$secrets/developer-id.provisionprofile"
fi
export LISTENJAR_UPDATE_PUBLIC_KEY LISTENJAR_SIGNING_IDENTITY LISTENJAR_PROVISIONING_PROFILE
app=packages/desktop/build/macos/Build/Products/Release/ListenJar.app
installed=/Applications/ListenJar.app
bundle=com.listenjar.desktop

if ! security find-identity -v -p codesigning | grep -qF "\"$LISTENJAR_SIGNING_IDENTITY\""; then
  echo "No \"$LISTENJAR_SIGNING_IDENTITY\" in the keychain: import $secrets/developer-id.p12 (its password is in export-password)." >&2
  exit 1
fi

(cd packages/desktop && flutter build macos --release)
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$app/Contents/Info.plist")" != "$LISTENJAR_UPDATE_PUBLIC_KEY" ]]; then
  echo "The built app does not carry LISTENJAR_UPDATE_PUBLIC_KEY: run flutter clean and reinstall again." >&2
  exit 1
fi
tool/sign-macos.sh "$app"

# Quit the running app (the installed copy or any other), waiting up to 10 s.
if pgrep -qf "ListenJar.app/Contents/MacOS/"; then
  osascript -e "tell application id \"$bundle\" to quit" || true
  for _ in {1..20}; do pgrep -qf "ListenJar.app/Contents/MacOS/" || break; sleep 0.5; done
  if pgrep -qf "ListenJar.app/Contents/MacOS/"; then
    echo "ListenJar is still running: quit it and reinstall again." >&2
    exit 1
  fi
fi

# Copy to a temporary folder on the same volume, then move it in, so a failed
# copy leaves the old app in place and /Applications only ever holds
# ListenJar.app: launchers index any .app that shows up there, under its name.
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
ditto "$app" "$staging/ListenJar.app"
rm -rf "$installed"
mv "$staging/ListenJar.app" "$installed"
mdimport "$installed"
codesign --verify --deep --strict "$installed"
codesign --display --verbose=2 "$installed" 2>&1 | grep -E '^(Identifier|Authority=Developer ID Application|TeamIdentifier|Timestamp)'
echo "Installed $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$installed/Contents/Info.plist") ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$installed/Contents/Info.plist")) at $installed"
open "$installed"
