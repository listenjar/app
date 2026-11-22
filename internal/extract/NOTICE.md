# Notice

The YouTube extractor in this package, the `internal/engine` subset it uses and
`internal/jsrun` are ported from **downbit** (`downbit/reconstructed`), a
manual source reconstruction of the Downbit v0.2.x executable built from its
retained Go metadata, embedded assets and decompiler output. It is not
Downbit's original source: comments marked `RECOVERY:` and erased identifiers
are the reconstruction's, and live-service parity is not proven.

The code is copied as is. Changes for this module:

- Import paths: `downbit/internal/engine` became
  `github.com/listenjar/desktop/internal/engine`.
- Only what the YouTube extractor needs is copied. Files marked
  `ListenJar port:` are excerpts and say what was left out. Downbit's
  download, DASH, mux, licensing, GUI, CLI, other providers and tests are not
  ported.
- `engine.Format` drops its unexported DASH field, and `engine.Options` drops
  `Section`.
- `jsrun.Run` is downbit's `runJS`. It uses the app's running MyGo
  application loop instead of starting one on demand.
- `resolve.go` is new: `ResolveYouTube`, the entry point for ListenJar.

User-facing error strings still name Downbit in places, as in the source.

## Third-party assets

`assets/youtube-library.js` and `assets/youtube-solver.js` are byte-for-byte
copies of the [yt-dlp/ejs](https://github.com/yt-dlp/ejs) build that Downbit
embeds. They solve the YouTube player's signature and n-parameter challenges.
Their license headers are kept intact:

| File                  | Licence                   | Bundled dependencies                                                                                        |
| --------------------- | ------------------------- | ----------------------------------------------------------------------------------------------------------- |
| `youtube-solver.js`   | Unlicense (yt-dlp/ejs)    | none                                                                                                        |
| `youtube-library.js`  | Unlicense (yt-dlp/ejs)    | [meriyah](https://github.com/meriyah/meriyah) 6.1.4 (ISC), [astring](https://github.com/davidbonnet/astring) 1.9.0 (MIT) |
