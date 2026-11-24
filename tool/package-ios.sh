#!/usr/bin/env bash
# Builds the release iOS app and exports it for App Store Connect as
# build/release/ListenJar-X.Y.Z-ios.ipa (`moon run desktop:package-ios`), which
# tool/testflight.ts uploads to TestFlight.
#
#   LISTENJAR_IOS_PROFILE  an App Store provisioning profile for
#                          com.listenjar.desktop: sign with it and its Apple
#                          Distribution certificate, which must be in the
#                          keychain search list (tool/ios-signing.sh)
#
# Without a profile Xcode signs automatically, with this Mac's team account.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

profile="${LISTENJAR_IOS_PROFILE:-}"
version="$(node tool/release.ts identity | node -p 'JSON.parse(require("fs").readFileSync(0)).version')"
out=build/release
ipa="$out/ListenJar-$version-ios.ipa"
# Release.xcconfig includes it, for the Runner target only.
signing=packages/desktop/ios/Flutter/Signing.xcconfig
work="$(mktemp -d)"
trap 'rm -rf "$work" "$signing"' EXIT
options="$work/ExportOptions.plist"
plist() { /usr/libexec/PlistBuddy "$@"; }

plist -c 'Add :method string app-store-connect' -c 'Add :destination string export' \
  -c 'Add :uploadSymbols bool true' -c 'Add :manageAppVersionAndBuildNumber bool false' "$options" > /dev/null
if [[ -n "$profile" ]]; then
  security cms -D -i "$profile" > "$work/profile.plist"
  name="$(plist -c 'Print :Name' "$work/profile.plist")"
  uuid="$(plist -c 'Print :UUID' "$work/profile.plist")"
  team="$(plist -c 'Print :TeamIdentifier:0' "$work/profile.plist")"
  application="$(plist -c 'Print :Entitlements:application-identifier' "$work/profile.plist")"
  bundle="${application#"$team."}"
  # Xcode 16 and later read the first, older ones the second.
  for directory in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" "$HOME/Library/MobileDevice/Provisioning Profiles"; do
    mkdir -p "$directory"
    cp "$profile" "$directory/$uuid.mobileprovision"
  done
  cat > "$signing" <<EOF
CODE_SIGN_STYLE = Manual
DEVELOPMENT_TEAM = $team
CODE_SIGN_IDENTITY = Apple Distribution
CODE_SIGN_IDENTITY[sdk=iphoneos*] = Apple Distribution
PROVISIONING_PROFILE_SPECIFIER = $name
EOF
  plist -c 'Add :signingStyle string manual' -c "Add :teamID string $team" -c 'Add :provisioningProfiles dict' \
    -c "Add :provisioningProfiles:$bundle string $name" "$options" > /dev/null
else
  plist -c 'Add :signingStyle string automatic' "$options" > /dev/null
fi

rm -rf packages/desktop/build/ios/ipa
(cd packages/desktop && flutter build ipa --release --export-options-plist="$options")
built=(packages/desktop/build/ios/ipa/*.ipa)
[[ ${#built[@]} -eq 1 && -f "${built[0]}" ]] || { echo "Expected one .ipa in packages/desktop/build/ios/ipa" >&2; exit 1; }
mkdir -p "$out"
cp "${built[0]}" "$ipa"
echo "$ipa"
