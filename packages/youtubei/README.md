# youtubei

The real [YouTube.js fork](https://github.com/listenbox/YouTube.js) inside
[QuickJS](https://bellard.org/quickjs/), for Dart: the port of the Go `youtubei` crate in
[listenbox/client](https://github.com/listenbox/client/tree/master/crates/youtubei). The caller
owns HTTP transport, cookies, format selection, downloads and application policy. This package
owns the QuickJS runtime, its host primitives and live objects.

Session and player bootstrap, endpoint payloads, parsers, continuations and signature/`n`
deciphering belong to YouTube.js. Fix those defects in the fork
([packages/youtubejs](../youtubejs)), never with Dart workarounds or extra requests. The HTTP
boundary is **YouTube.js → its `fetch` → the caller's `Fetch`**.

## Use

```dart
final yt = await startYouTubei(httpClientFetch(HttpClient()..userAgent = null));
await initialize(yt, const SessionOptions(timezone: 'Europe/Berlin'));
final page = await playlistHead(yt, 'PL…', token: cancellation);
final info = await videoInfo(yt, 'dQw4w9WgXcQ', Client.visionOS, token: cancellation);
final url = await decipher(yt, info.formats.first, token: cancellation);
await release(yt, info.formats.map((f) => f.handle));
await closeYouTubei(yt);
```

`startYouTubei` spawns an isolate that owns the runtime: every QuickJS value is created, used and
freed there. Calls overlap while they await host I/O; `closeYouTubei` drains accepted calls
before freeing the runtime. Each operation takes a `CancellationToken`
([cancellation_token](https://pub.dev/packages/cancellation_token)): cancelling completes the call
with the token's exception at once, cancels the fetches it started and interrupts JavaScript
running on its behalf. Fetch bodies stay bytes, with headers, status and host errors preserved
(`YouTubeiException.cause`).

Playlist continuations, formats and deciphering keep live handles; `continuation` consumes a
page's, `release` frees the rest. The snapshots stay usable afterwards. `callYouTubei` is the
escape hatch for upstream methods the typed operations don't cover: it returns a JSON value and
never exports a live object.

QuickJS has no `Intl`, so `SessionOptions.timezone` is required.

## Layout

- [native/bridge.c](native/bridge.c), [native/bridge.h](native/bridge.h): one runtime and
  context, the synchronous `__host(name, json)` call into the engine isolate, native UTF-8
  encode/decode, and per-call interrupts.
- [native/host.js](native/host.js): the web and Node primitives the bundle uses (fetch, streams,
  URL, timers, encoding, crypto, cache): the subset it needs, not a general runtime.
- [native/bindings.js](native/bindings.js): the thin bindings to the live YouTube.js API.
- [native/scripts.c](native/scripts.c) compiles host.js, the bundle and bindings.js into the
  library with C23 `#embed` (clang 19+ or GCC 15+); the app needs no JavaScript runtime or
  download at run time.
- [hook/build.dart](hook/build.dart) builds it all as a code asset with
  [native_toolchain_c](https://pub.dev/packages/native_toolchain_c); on Windows it uses MinGW-w64
  GCC (`hooks.user_defines.youtubei.mingw_cc`, default `C:\msys64\ucrt64\bin\gcc.exe`), since
  MSVC can't build QuickJS.
- [lib/src/bindings.g.dart](lib/src/bindings.g.dart): `@Native` bindings FFIgen generates from
  bridge.h (`moon run desktop:ffigen`).

`native/youtubejs.js` is the Git-ignored bundle `moon run desktop:bundle` builds from the pinned
fork; the build hook fails with that command if it is missing.

## QuickJS

[native/quickjs](native/quickjs) is a Git submodule of https://github.com/bellard/quickjs,
pinned to the 2026-06-04 release commit `3d5e064e9dd67c70f7962836505a7fa067bf0a4e`, the same
pin as Happen's code mode. The hook compiles only the interpreter sources and the bridge: no
`qjs`, libc module or Node.
