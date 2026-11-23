# YouTube extraction traffic

Ported from the Go youtubei crate's AGENTS.md (listenbox/client).

## Layer ownership: keep the Dart API thin

- `youtubei` owns the QuickJS runtime, its isolate and scheduling, object lifetimes, native
  primitives (native/bridge.c, native/host.js) and thin bindings (native/bindings.js) to the live
  YouTube.js API. Bindings call upstream methods and read upstream properties; they never
  implement a second YouTube client.
- `packages/youtubejs` owns every YouTube HTTP operation: session and player bootstrap, endpoint
  selection, request construction, response parsing, continuations and signature/`n`
  deciphering. Let its real code run inside QuickJS.
- Never issue YouTube requests from Dart, hand-build payloads, parse responses, extract player
  algorithms or add fallback requests here. The HTTP boundary is
  **YouTube.js → its `fetch` → the caller's `Fetch`**; a `Fetch` performs the requested I/O and
  returns bytes, nothing more.
- Application policy (which client to request, rendition selection, downloads, uploads) belongs
  to the app, outside this package.
- Fix parser, request and player-runtime defects in the fork, then bump its pin; never conceal
  them with Dart workarounds or hard-coded responses.

## Request budget

- Minimize HTTP requests while still completing the caller's goal. Request count is part of the
  extraction contract, not a later optimization.
- Prefer one player response that supplies both metadata and usable streams, and reuse it.
- Request another client only when a response lacks a required capability or its media URLs
  refuse the download. Never probe every client speculatively.
- Keep live cookie-backed investigation read-only and credentials out of logs.
