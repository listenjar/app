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

The Dart API is YouTube.js's: the same classes, methods and property names (`basic_info`,
`streaming_data`, `has_continuation`), with YouTube.js's namespaces as libraries imported under
their names.

```dart
import 'package:youtubei/youtubei.dart';
import 'package:youtubei/yt_nodes.dart' as YTNodes;

final innertube = await Innertube.create(timezone: 'Europe/Berlin', retrieve_player: true, cache: UniversalCache(true, cacheDirectory));
final info = await innertube.getBasicInfo('dQw4w9WgXcQ', client: InnerTubeClient.VISIONOS, token: cancellation);
final url = await info.streaming_data!.adaptive_formats.first.decipher(innertube.session.player, token: cancellation);
final search = await innertube.search('lofi', token: cancellation);
for (final node in search.results) {
  if (node is YTNodes.Video) print(node.title);
}
var playlist = await innertube.getPlaylist('PL…');
while (playlist.has_continuation) playlist = await playlist.getContinuation();
await innertube.close();
```

Where the APIs differ, Dart forces it:

- Each async method takes a `CancellationToken`
  ([cancellation_token](https://pub.dev/packages/cancellation_token)) where YouTube.js takes an
  AbortSignal, or takes none: cancelling completes the call with the token's exception at once,
  cancels the fetches it started and interrupts JavaScript running on its behalf.
- `Innertube.create` starts a QuickJS runtime of its own, in an isolate that owns every value;
  `close` stops it once accepted calls finish. Without a `fetch`, requests go through a dart:io
  `HttpClient`; with one, the caller's `Fetch` gets each request as bytes, headers and status
  (failures reach Dart as `InnertubeError.cause`). `log` receives YouTube.js's log lines.
- QuickJS has no `Intl`, so pass `timezone`.
- `new YT.Playlist(actions, data)` is `await YT.Playlist.create(actions, data)`: building one runs
  JavaScript in the runtime's isolate.
- Values are snapshots of the properties ListenJar reads so far; add others by their upstream
  names in [lib/src](lib/src). A node of a class not mirrored is a plain `YTNode` with its
  `type`. Formats, players, playlists and API responses stay live in YouTube.js until the Dart
  object is collected.
- `UniversalCache` keeps files as YouTube.js's Node cache does: one per key, in
  `persistent_directory` (by default `.cache/youtubei.js` in the working directory) or, when not
  persistent, the system temp directory. Without a cache, nothing is kept.

## Layout

- [native/bridge.c](native/bridge.c), [native/bridge.h](native/bridge.h): one runtime and
  context, native random bytes and UTF-8 encode/decode, the outbox, and per-call interrupts.
  Dart calls JavaScript; JavaScript never calls Dart. JavaScript queues what it needs from Dart
  (finished calls, fetches, digests, cache reads and writes, timers, log lines) in an outbox Dart
  takes after each call in, and Dart answers by calling in again.
- [native/host.js](native/host.js): the web and Node primitives the bundle uses (fetch, streams,
  URL, timers, encoding, crypto, cache): the subset it needs, not a general runtime.
- [native/bindings.js](native/bindings.js): the thin bindings: each calls the YouTube.js method
  the Dart one mirrors and serializes what it returns.
- `native/scripts.g.c` holds host.js, the bundle and bindings.js as C string literals, which
  any C compiler builds into the library, and the bundle's sequence (its YouTube.js commit's
  committer time, `Bundle.sequence`); the app needs no JavaScript runtime or download at run time.
  `Innertube.create(bundle: …)` runs another bundle's source instead (a signed release of the fork
  for `Bundle.abi`, which the caller fetches and verifies); one that fails to evaluate throws a
  `BundleError`. [tool/scripts.mjs](tool/scripts.mjs) writes it (`moon run app:scripts`, cached
  on the scripts), heading it with each script's SHA-256, and the build hook stops with that
  command when it is missing or older than a script.
- [hook/build.dart](hook/build.dart) builds it all as a code asset with
  [native_toolchain_c](https://pub.dev/packages/native_toolchain_c); on Windows it uses MSYS2's
  MinGW-w64 compilers, since MSVC can't build QuickJS: GCC for x64 (`C:\msys64\ucrt64\bin\gcc.exe`)
  and Clang for arm64 (`C:\msys64\clangarm64\bin\clang.exe`), or
  `hooks.user_defines.youtubei.mingw_cc`.
- [lib/src/bindings.g.dart](lib/src/bindings.g.dart): `@Native` bindings FFIgen generates from
  bridge.h (`moon run app:ffigen`).

`native/youtubejs.js` is the Git-ignored bundle `moon run app:bundle` builds from the pinned
fork; `app:scripts` builds it first.

## QuickJS

[native/quickjs](native/quickjs) is a Git submodule of https://github.com/bellard/quickjs,
pinned to the 2026-06-04 release commit `3d5e064e9dd67c70f7962836505a7fa067bf0a4e`, the same
pin as Happen's code mode. The hook compiles only the interpreter sources and the bridge: no
`qjs`, libc module or Node.
