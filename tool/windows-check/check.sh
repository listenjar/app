#!/usr/bin/env bash
# Compiles the Windows runner (packages/desktop/windows/runner) for
# x86_64-windows-gnu with zig, against the Win32 headers zig ships and the
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
for source in "$windows"/runner/*.cpp; do
  # zig's -fsyntax-only fails on Windows targets; compile to a throwaway object instead.
  "$zig" c++ -target x86_64-windows-gnu -std=c++17 -c -o "$cache/$(basename "$source" .cpp).obj" -DUNICODE -D_UNICODE \
    -I "$windows/runner" -I "$windows" \
    -I "$platform/windows/public" -I "$platform/common/public" \
    -I "$platform/common/client_wrapper/include" -I "$platform/common/client_wrapper/include/flutter" \
    -I "$platform/windows/client_wrapper/include" -I "$platform/windows/client_wrapper/include/flutter" \
    "$source"
  echo "windows: runner/$(basename "$source")"
done
