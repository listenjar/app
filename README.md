# ListenJar desktop

The [ListenJar](https://listenjar.com) app for macOS, Windows, Linux, Android and iOS, in Flutter.

It is a podcast player first, free and without an account: follow any RSS feed or a show from
the directory, refresh, download, Up Next, playback speed and a sleep timer, with the system's
media controls and headphone buttons. A single YouTube video plays as an episode of its own.
Signing in adds ListenJar Cloud: YouTube playlists, channels and custom podcasts as feeds that
ListenJar hosts, which the paid plans pay storage for.

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

## Player

| File | What |
| --- | --- |
| [library.dart](packages/desktop/lib/library.dart) | Shows, episodes, Up Next and settings, in SQLite (`library.sqlite`) |
| [rss.dart](packages/desktop/lib/rss.dart) | Fetches and parses RSS and Atom feeds and OPML, from the address as given (`http` too, as AntennaPod does) |
| [podcasts.dart](packages/desktop/lib/podcasts.dart) | Following, refreshing (conditional GETs) and OPML import and export |
| [directory.dart](packages/desktop/lib/directory.dart) | Search and top charts from Apple's podcast directory, as AntennaPod uses |
| [player.dart](packages/desktop/lib/player.dart) | [just_audio](https://pub.dev/packages/just_audio) behind [audio_service](https://pub.dev/packages/audio_service): the lock screen, notification, headphones and media keys |
| [downloads.dart](packages/desktop/lib/downloads.dart) | Episode downloads ([background_downloader](https://pub.dev/packages/background_downloader)), YouTube's through youtubei, and the storage rules (`tidyDownloads`) |
| [storage_page.dart](packages/desktop/lib/storage_page.dart) | Settings → Storage: the space downloads take, show by show, and the rules for it |

The media session is the platform's own: Android's and iOS's through audio_service, macOS's
Now Playing, MPRIS on Linux ([audio_service_mpris](https://pub.dev/packages/audio_service_mpris))
and the System Media Transport Controls on Windows ([windows_media.dart](packages/desktop/lib/windows_media.dart)).
Windows and Linux play through libmpv ([just_audio_media_kit](https://pub.dev/packages/just_audio_media_kit)).

Storage works like Telegram's Storage Usage. A ring shows the shows whose downloads take the
most space (the five largest, then the rest as one part); untick shows to delete only the rest.
Downloads can be capped at 2, 5, 10 or 25 GB (no limit by default): past the cap, the downloads
played or downloaded longest ago go first. Played episodes' downloads go right away (the
default), after a day or a week, or stay; downloads unplayed for a week, a month or three
months can go too. The episode playing and Up Next always stay, and a running download is never
touched. The rules run when the app starts, every hour, after a download finishes or an episode
ends, and when they change; each deletion logs on the `storage` logger with its reason.

SQLite comes from [`package:sqlite3`](https://pub.dev/packages/sqlite3)'s build hook. QuickJS
is compiled by youtubei's build hook. Neither needs a system library.

## Run

Flutter 3.50 and [oasmith](https://github.com/responsibleapi/oasmith), and [aube](https://aube.dev)
for the YouTube.js bundle, all pinned in [mise.toml](mise.toml). Initialize submodules recursively first.

```sh
moon run desktop:dev       # macOS against backend:dev on :8787, hot reloads on save (tool/dev.dart)
moon run desktop:build     # release macOS app in packages/desktop/build/macos
moon run desktop:reinstall # it, Developer ID signed, into /Applications
moon run desktop:check     # flutter analyze
```

`desktop:codegen` (public.yaml → `lib/backend`, [pricing](pricing) → `lib/pricing`) and `desktop:scripts` (packages/youtubejs →
`packages/youtubei/native/youtubejs.js` → `native/scripts.g.c`) run before each of those, and
moon caches both on their inputs. For other platforms run `moon run desktop:codegen
desktop:scripts`, then `flutter run -d windows|linux|ios|<android device>` in `packages/desktop`.

- Windows builds QuickJS with MSYS2's MinGW-w64 compiler (MSVC can't build it): UCRT64's GCC on
  x64, CLANGARM64's Clang on arm64; see [packages/youtubei](packages/youtubei). The media
  controls (smtc_windows) build with [Rust](https://rustup.rs). Flutter builds for the machine it
  runs on, so build and run arm64 on Windows on Arm (a Windows 11 Arm VM on an Apple silicon Mac
  works), with Flutter cloned at mise.toml's tag (Flutter publishes no arm64 Windows SDK), Visual
  Studio's ARM64 C++ tools, Rust and MSYS2 with `pacman -S mingw-w64-clang-aarch64-clang`. Its
  libmpv is media-kit's audio-only aarch64 build (pubspec.yaml's override). Windows on Arm also
  installs and runs the x64 installer, emulated.
- Linux needs libmpv: `libmpv-dev` to build and `libmpv2` to run on Debian and Ubuntu (`mpv-libs`
  on Fedora, `mpv` on Arch). Without it the app opens but can't play.
- iOS needs Xcode. Its app icon is still Flutter's: `desktop:icons` doesn't render iOS yet.

Off their platforms, two checks type-check the native runners:

- `moon run desktop:swift-check` (Linux): the iOS and macOS AppDelegates against stub UIKit,
  Cocoa and Flutter modules, with [Swift for Linux](https://www.swift.org/install/linux/)
  ([tool/swift-check](tool/swift-check)).
- `moon run desktop:windows-check` (Linux, macOS): the Windows runner's C++ against the Flutter
  engine's headers, with `zig c++ -target x86_64-windows-gnu` (and the updater for aarch64)
  ([tool/windows-check](tool/windows-check)).

[mise.toml](mise.toml) installs Swift (Linux only) and Zig for them.

Android runs in [Redroid](https://github.com/remote-android/redroid-doc) on a Linux machine with
the binder module (`sudo modprobe binder_linux devices="binder,hwbinder,vndbinder"`):

```sh
docker run -itd --rm --privileged --name redroid -p 5555:5555 redroid/redroid:14.0.0_64only-latest
adb connect localhost:5555
flutter run -d localhost:5555
```

## Releases

Every push to master releases the app:

1. [version.yaml](.github/workflows/version.yaml) runs `desktop:release-prepare`
   ([tool/release.dart](tool/release.dart)), which takes the next version: the next patch above
   the newest `vX.Y.Z` tag, or the `version:` in [packages/desktop/pubspec.yaml](packages/desktop/pubspec.yaml)
   when that is newer, with the next build number (Android's versionCode, and what the updaters
   compare). It commits the bump as `Release vX.Y.Z` on top of the pushed commit, with a
   `Source-commit:` trailer, and pushes only the tag; master never moves. Raise the pubspec's
   version for a new minor or major.
2. It then dispatches [release.yaml](.github/workflows/release.yaml) on that tag, which builds
   every platform on its own runner into `build/release/`: `desktop:package-macos` (a Developer
   ID signed, notarized DMG; [tool/package-macos.sh](tool/package-macos.sh)),
   [tool/package-windows.ps1](tool/package-windows.ps1) (an Inno Setup installer each for x64
   and arm64, on a runner of that architecture),
   `desktop:package-linux` (a tar.gz) and `desktop:package-android` (an APK signed with the
   permanent release key, which [tool/release.dart](tool/release.dart) checks).
3. [tool/release.ts](tool/release.ts) signs the DMG and the installers for the updaters
   (Ed25519), writes `appcast-macos.xml`, `appcast-windows-x64.xml` and `appcast-windows-arm64.xml`,
   attests each package's build provenance (`gh attestation verify <file> --repo
   listenjar/desktop`), uploads all five with
   their manifests, and only then makes the release the latest, whose appcasts the apps read.
4. Beside them, the ios job sends the release to TestFlight for iPhone and iPad:
   `desktop:package-ios` ([tool/package-ios.sh](tool/package-ios.sh)) builds an IPA signed for
   the App Store, and [tool/testflight.ts](tool/testflight.ts) uploads it, waits for App Store
   Connect to process it, adds it to the external **Public** group and submits it to Beta App
   Review. Anyone joins with the group's public link, up to 10,000 testers:
   <https://testflight.apple.com/join/HHHDHV2a>; each build reaches them once Apple approves it,
   and expires after 90 days. The GitHub release doesn't wait for the ios job. macOS stays on
   the DMG above, one download link and Sparkle updates.

Secrets live only in GitHub and, on a Mac, in `~/.secrets/listenjar`; never in this repo. On
GitHub they are in the `desktop-release` environment, which only `v*` tags can use, so the
macos, windows, android, ios and publish jobs run only on a release tag; `moon run desktop-signing:restore`
in the listenjar monorepo fills it from `~/.secrets/listenjar/desktop-signing`.

- Secrets: `MACOS_CERTIFICATE_P12_BASE64`, `MACOS_CERTIFICATE_PASSWORD`, `MACOS_NOTARY_KEY_P8_BASE64`,
  `MACOS_NOTARY_KEY_ID`, `MACOS_NOTARY_ISSUER_ID` (Developer ID signing and notarization),
  `MACOS_UPDATE_SEED_BASE64`, `WINDOWS_UPDATE_SEED_BASE64` (each updater's Ed25519 private seed),
  and `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD` (the APK release key, a PKCS12
  keystore whose store password is also the key's), and `IOS_DISTRIBUTION_P12_BASE64`,
  `IOS_DISTRIBUTION_PASSWORD`, `IOS_PROVISIONING_PROFILE_BASE64` (the Apple Distribution
  certificate and the App Store profile, renewed yearly), `APP_STORE_CONNECT_KEY_P8_BASE64`,
  `APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID` (an Admin App Store Connect API
  key, for TestFlight).
- Variables: `MACOS_SIGNING_IDENTITY`, `MACOS_TEAM_ID`, `MACOS_UPDATE_PUBLIC_KEY`,
  `WINDOWS_UPDATE_PUBLIC_KEY` (the matching public keys, which the builds compile in), and
  `ANDROID_KEY_ALIAS` (the APK release key's alias).

Android updates an installed app only with an APK signed by the same key, so that key never
changes, and release builds are signed with nothing else: debug builds with the debug key,
release builds ([build.gradle.kts](packages/desktop/android/app/build.gradle.kts)) with the
keystore `ANDROID_KEYSTORE_PATH`, `ANDROID_KEYSTORE_PASSWORD` and `ANDROID_KEY_ALIAS` name, or on
a Mac without them with `~/.secrets/listenjar/desktop-signing/android`'s; with neither, a release
build fails. Where Maven Central turns Gradle away (429 on GitHub's runners, 403 on some
networks), `cp tool/maven-mirror.gradle ~/.gradle/init.d/` resolves it through Google's mirror,
as the release workflow does. `desktop:package-android` also refuses an APK whose certificate isn't the one
[passkeys.ts](passkeys.ts) lists.

This repo builds on its own, without the monorepo: [mise.toml](mise.toml) pins every tool the
DMG and the APK need (Flutter, Node, aube, oasmith, moon, Java and the Android SDK; Xcode aside),
[.moon](.moon) is a workspace of this one project, and the plans and prices come from the
committed [pricing](pricing) catalog, which `moon run root:pricing-sync` in the monorepo writes.

## Shared links

A YouTube or podcast link shared to the app opens as if typed into its link field: a video is
added as an episode (or, signed in on a paid plan, to a podcast of your choice), a playlist or
channel goes to ListenJar Cloud, anything else is searched
([shared_links.dart](packages/desktop/lib/shared_links.dart)). Each platform hands links over on
the `listenjar/links` channel:

| Platform | How a link arrives |
| --- | --- |
| Android | The share sheet (`text/plain`) and YouTube's https links ([MainActivity.kt](packages/desktop/android/app/src/main/kotlin/com/listenjar/desktop/MainActivity.kt)); since Android 12, links open in the app only once its "Open supported links" setting is on, as the app can't verify youtube.com |
| iOS, macOS | `listenjar://open?url=…`, which the website and shortcuts can open (AppDelegate.swift) |
| Windows | Command-line arguments, forwarded to the running instance with `WM_COPYDATA` ([instance.cpp](packages/desktop/windows/runner/instance.cpp)) |
| Linux | Command-line arguments |

A share extension for iOS and macOS and a Windows share target (which needs MSIX packaging) are
still to come.

## Debugging

Each part of the app logs through a `Logger` of its own ([log.dart](packages/desktop/lib/log.dart)):
`youtube`, `youtube.http`, `youtube.js` (YouTube.js's own log), `podcasts`, `rss`, `player`,
`downloads`, `storage`, `links`. Outside release builds, records of level FINE and up print to
`flutter run`'s console and go to DevTools' Logging view; warnings and up go there in release.
`traced()` wraps slow work (each YouTube request, resolving a video, a feed refresh): it logs how
long the work took and how it ended, shows it as a task in DevTools' Performance view and the
VM timeline (Chrome trace JSON), and warns every 10 s while it waits.

Debug builds answer service extensions, which the Dart MCP server's `vm_service callMethod` and
DevTools can call:

| Extension | Answer |
| --- | --- |
| `ext.listenjar.log` | Recent records; `since` a sequence number, `level` (default FINE), `logger` a name prefix |
| `ext.listenjar.running` | Traced work not finished yet, oldest first |
| `ext.listenjar.state` | Account plan, what plays, Up Next, downloads, links waiting (no names or email) |

SEVERE records and uncaught async errors are reported as Flutter errors, so they show where
runtime errors show (the MCP's `get_runtime_errors`).

## Icons

[resources/icon.svg](resources/icon.svg) is the one source. `moon run desktop:icons` renders it
for macOS, Windows, Android and Linux (not iOS yet): as is for release and profile builds, and with a red
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

## What the app talks to

Feeds and episode files come from each podcast's own host. Podcast search and the charts go to
Apple's directory (`itunes.apple.com`, `rss.marketingtools.apple.com`), and YouTube search and
videos to YouTube. The ListenJar API only when you're signed in. Nothing else: no telemetry,
tracing or crash reports.
