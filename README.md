# ListenJar desktop

The [ListenJar](https://listenjar.com) app for macOS, Windows, Linux and Android, in Flutter.

It talks to the ListenJar API described in [public.yaml](public.yaml) (OpenAPI 3.2), through
a Dart client that [oasmith](https://github.com/responsibleapi/oasmith) generates into the
Git-ignored `packages/desktop/lib/backend`.

## Layout

A [pub workspace](https://dart.dev/tools/pub/workspaces) ([pubspec.yaml](pubspec.yaml)):

| Path | What |
| --- | --- |
| [packages/desktop](packages/desktop) | The Flutter app |
| [packages/youtubei](packages/youtubei) | [listenbox/YouTube.js](https://github.com/listenbox/YouTube.js) in embedded QuickJS, for Dart |
| [packages/youtubejs](packages/youtubejs) | Git submodule of the YouTube.js fork (`master`), which youtubei bundles |

SQLite comes from [`package:sqlite3`](https://pub.dev/packages/sqlite3)'s build hook. QuickJS
is compiled by youtubei's build hook. Neither needs a system library.

## Run

Flutter 3.50 and [oasmith](https://github.com/responsibleapi/oasmith) (the monorepo's mise.toml), and
[aube](https://aube.dev) for the YouTube.js bundle. Initialize submodules recursively first.

```sh
moon run desktop:dev     # macOS against backend:dev on :8787, hot reloads on save (tool/dev.dart)
moon run desktop:build   # release macOS app in packages/desktop/build/macos
moon run desktop:check   # flutter analyze
```

`desktop:codegen` (public.yaml → `lib/backend`) and `desktop:bundle` (packages/youtubejs →
`packages/youtubei/native/youtubejs.js`) run before each of those. For other platforms run
`flutter run -d windows|linux|<android device>` in `packages/desktop` after them. Windows builds
QuickJS with MinGW-w64 GCC (MSVC can't build it); see [packages/youtubei](packages/youtubei).

## Icons

[resources/icon.svg](resources/icon.svg) is the one source. `moon run desktop:icons` renders it
for macOS, Windows, Android and Linux: as is for release and profile builds, and with a red
DEBUG ribbon for debug builds, so a dev build never passes for the installed app.

## Configuration

There are two configurations, in [config.dart](packages/desktop/lib/config.dart), and nothing
else to set:

- Debug builds call a local backend on `http://localhost:8787` and sign in through the local
  website on `http://localhost:3000`.
- Release builds call `https://api.listenjar.com` and sign in through `https://listenjar.com`.

## Design

The app wears listenjar.com's design system, recorded in the listeners monorepo's
[DESIGN.md](../../DESIGN.md): the website dashboard's paper side, in
[theme.dart](packages/desktop/lib/theme.dart) (tokens, type, buttons, panels) and
[marks.dart](packages/desktop/lib/marks.dart) (the logo and icons, drawn from the website's
paths). Change a token on the website, change it here.

## Signing in

"Sign in with your browser" follows [RFC 8252](https://www.rfc-editor.org/rfc/rfc8252)
([signin.dart](packages/desktop/lib/signin.dart)): the app listens on a random `127.0.0.1`
port, opens `listenjar.com/desktop/authorize` in the default browser, where you sign in and
allow the app, and trades the one-time code the browser brings back for its own token, proving
with PKCE that it started the sign-in. The page the browser lands on opens `listenjar://sign-in`
(`listenjar-dev://` in debug builds), which each platform's runner registers, to bring the app
back to the front. The token lives in the system credential store
(Keychain, Credential Manager, Secret Service or the Android Keystore); "Sign out" revokes and
forgets it.

The app sends nothing anywhere else: no telemetry, tracing or crash reports.
