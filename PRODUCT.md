# Product

<!-- impeccable:product-schema 1 -->

## Platform

adaptive

## Users

Podcast listeners who want videos they did not make (YouTube videos, other people's channels, audiobooks
posted as video) as a podcast feed in the podcast app they already use.

## Product Purpose

The ListenJar desktop app does the syncing for a listener's ListenJar feeds: it downloads what they added on
their own computer, uploads it to ListenJar, and deletes the local files once the upload is done. The
listener then hears it in their podcast app.

Success: the listener sets it up once and forgets it; episodes show up in their podcast app without them
looking at this window.

## Positioning

Downloads happen on the listener's own computer, not on a server. The app is open source, and it sends
nothing anywhere but the ListenJar API: no telemetry, tracing or crash reports.

## Operating Context

- Runs in the background on a computer that is switched on; syncing stops when it is off.
- Its counterpart is the ListenJar website (listenjar.com), where listeners also manage feeds.
- Talks only to the API in [public.yaml](public.yaml) (`https://api.listenjar.com`).

## Capabilities and Constraints

- Ships on macOS, Windows and Linux; iOS and Android later.
- 100% native desktop app in Go: MyGo native UI (Go `ui` package, drawn on the GPU). No HTML, no
  webview, no WebAssembly or browser build. One design language on every OS. Preview it by running the
  native app (`moon run desktop:dev`).
- `adaptive` above is the only Impeccable platform value for a native app that is neither iOS nor
  Android. It routes design work to the native, source-based reviews instead of browser tooling. It
  does not mean the design changes per OS, and there is no SwiftUI, UIKit or Compose here: apply
  iOS/Android guidance only where it is about platform conventions (shortcuts, menus, windows).
- Today it is a placeholder: a title, a Refresh button and a list of feeds.

## Brand Commitments

- Name: ListenJar. Logo: not made yet (`resources/icon.png` is a placeholder).
- Visual reference named by the user: [mave.digital](https://mave.digital/). New visual work takes its
  direction from it. Take its feel and structure, not its brand: no copying its name, logo, illustrations
  or copy.

## Evidence on Hand

None yet: no testimonials, reviews or usage numbers. Do not invent them.

## Product Principles

1. Quiet by default: sync state is visible at a glance, and the window is rarely needed.
2. Say plainly what it does on the listener's computer: what it downloads, where, and that it deletes it.
3. Nothing leaves the computer except uploads to ListenJar.
