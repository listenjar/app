#!/usr/bin/env bash
# Compiles the Windows runner (packages/desktop/windows/runner) for
# x86_64-windows-gnu (and its release updater for aarch64 too) with zig, against the Win32 headers zig ships and the
# Flutter Windows embedder and C++ wrapper headers in the Flutter checkout.
# Nothing links and nothing runs: it catches what a compiler catches, off
# Windows. MSVC on Windows still has the last word.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
windows=$here/../../packages/desktop/windows
platform=$(mise where flutter)/engine/src/flutter/shell/platform
cache=$(mktemp -d)
trap 'rm -rf "$cache"' EXIT
export ZIG_GLOBAL_CACHE_DIR=$cache ZIG_LOCAL_CACHE_DIR=$cache
# zig writes a Windows target's object beside the working directory whatever
# -o says, so compile from the throwaway directory, with the zig this
# directory's mise.toml picks.
zig=$(mise which zig)
cd "$cache"
# WinSparkle's header (runner/updates.cpp), from the archive windows/CMakeLists.txt pins.
curl -fsSL -o winsparkle.zip https://github.com/vslavik/winsparkle/releases/download/v0.9.4/WinSparkle-0.9.4.zip
echo "6037df37fc263bd1650a1c4949681a9d40ffe991d01f35892a406cb5d103c976  winsparkle.zip" | shasum -a 256 -c --status
unzip -q winsparkle.zip 'WinSparkle-0.9.4/include/*'
target=x86_64-windows-gnu
compile() { # source [defines...]
  local source=$1; shift
  # zig's -fsyntax-only fails on Windows targets; compile to a throwaway object instead.
  "$zig" c++ -target "$target" -std=c++17 -c -o "$cache/$(basename "$source" .cpp).obj" -DUNICODE -D_UNICODE "$@" \
    -I "$windows/runner" -I "$windows" -I "$cache/WinSparkle-0.9.4/include" \
    -I "$platform/windows/public" -I "$platform/common/public" \
    -I "$platform/common/client_wrapper/include" -I "$platform/common/client_wrapper/include/flutter" \
    -I "$platform/windows/client_wrapper/include" -I "$platform/windows/client_wrapper/include/flutter" \
    "$source"
}
for source in "$windows"/runner/*.cpp; do
  compile "$source"
  echo "windows: runner/$(basename "$source")"
done
# As a release build compiles it, with an update key and pubspec.yaml's version.
compile "$windows/runner/updates.cpp" -DLISTENJAR_UPDATE_PUBLIC_KEY='"key"' \
  -DFLUTTER_VERSION_MAJOR=1 -DFLUTTER_VERSION_MINOR=2 -DFLUTTER_VERSION_PATCH=3 -DFLUTTER_VERSION_BUILD=4
echo "windows: runner/updates.cpp (release)"
# The arm64 release build reads its own appcast (_M_ARM64, as MSVC defines it).
target=aarch64-windows-gnu
compile "$windows/runner/updates.cpp" -D_M_ARM64 -DLISTENJAR_UPDATE_PUBLIC_KEY='"key"' \
  -DFLUTTER_VERSION_MAJOR=1 -DFLUTTER_VERSION_MINOR=2 -DFLUTTER_VERSION_PATCH=3 -DFLUTTER_VERSION_BUILD=4
echo "windows: runner/updates.cpp (arm64 release)"
