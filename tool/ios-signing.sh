#!/usr/bin/env bash
# For the release workflow's ios job (.github/workflows/release.yaml): `setup`
# imports the Apple Distribution certificate from the desktop-release
# environment's secrets into a throwaway keychain, writes out the App Store
# provisioning profile and the App Store Connect API key, and hands
# tool/package-ios.sh and tool/testflight.ts their paths; `cleanup` deletes
# the keychain and the files and restores the keychain list.
set -euo pipefail

directory="${RUNNER_TEMP:?}/listenjar-ios-signing"
keychain="$directory/ios.keychain-db"
if [[ "${1:-}" == cleanup ]]; then
  if [[ -f "$directory/keychains" ]]; then
    keychains=()
    while IFS= read -r previous; do keychains+=("$previous"); done < "$directory/keychains"
    security list-keychains -d user -s "${keychains[@]}"
  fi
  if [[ -f "$keychain" ]]; then security delete-keychain "$keychain"; fi
  rm -rf "$directory"
  exit 0
fi
[[ "${1:-}" == setup ]] || { echo 'Expected setup or cleanup' >&2; exit 1; }
for name in IOS_DISTRIBUTION_P12_BASE64 IOS_DISTRIBUTION_PASSWORD IOS_PROVISIONING_PROFILE_BASE64 APP_STORE_CONNECT_KEY_P8_BASE64 APP_STORE_CONNECT_KEY_ID APP_STORE_CONNECT_ISSUER_ID; do
  [[ -n "${!name:-}" ]] || { echo "Missing signing input: $name" >&2; exit 1; }
done
umask 077
mkdir -p "$directory"
security list-keychains -d user | sed 's/^ *"//; s/"$//' > "$directory/keychains"
printf '%s' "$IOS_DISTRIBUTION_P12_BASE64" | base64 --decode > "$directory/distribution.p12"
printf '%s' "$IOS_PROVISIONING_PROFILE_BASE64" | base64 --decode > "$directory/app-store.mobileprovision"
printf '%s' "$APP_STORE_CONNECT_KEY_P8_BASE64" | base64 --decode > "$directory/app-store-connect.p8"
password="$(openssl rand -hex 32)"
security create-keychain -p "$password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$password" "$keychain"
security import "$directory/distribution.p12" -k "$keychain" -P "$IOS_DISTRIBUTION_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$keychain" > /dev/null
keychains=("$keychain")
while IFS= read -r previous; do keychains+=("$previous"); done < "$directory/keychains"
security list-keychains -d user -s "${keychains[@]}"
security find-identity -v -p codesigning "$keychain" | grep -F '"Apple Distribution: ' > /dev/null
{
  printf 'LISTENJAR_IOS_PROFILE=%s\n' "$directory/app-store.mobileprovision"
  printf 'APP_STORE_CONNECT_KEY_PATH=%s\n' "$directory/app-store-connect.p8"
} >> "${GITHUB_ENV:?}"
