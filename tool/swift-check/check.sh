#!/usr/bin/env bash
# Type-checks the Apple runners' app delegates on Linux, against stubs of the
# Flutter, UIKit and AppKit API they use (ios/, macos/ here): Swift on Linux
# has none of those frameworks, nor Objective-C, so `@objc` is dropped first.
# It catches syntax, types and calls the stubs know; Xcode still has the last
# word. Update a stub when a runner uses more of the API.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
app=$here/../../packages/desktop
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

module() { # platform name [file]
  swiftc -parse-as-library -emit-module -module-name "$2" -I "$out/$1" -o "$out/$1/$2.swiftmodule" "$here/$1/$2.swift"
}
check() { # platform files...
  local platform=$1; shift
  local sources=()
  for file in "$@"; do
    sed 's/@objc //' "$app/$file" > "$out/$platform-$(basename "$file")"
    sources+=("$out/$platform-$(basename "$file")")
  done
  swiftc -typecheck -parse-as-library -I "$out/$platform" "${sources[@]}"
  echo "$platform: ${*}"
}

mkdir -p "$out/ios" "$out/macos"
module ios UIKit
module ios Flutter
module macos Cocoa
module macos FlutterMacOS
check ios ios/Runner/AppDelegate.swift ios/Runner/SceneDelegate.swift
check macos macos/Runner/AppDelegate.swift
