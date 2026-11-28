# Product

<!-- impeccable:product-schema 1 -->

## Platform

adaptive

## Users

Podcast listeners. Anyone who wants a classic podcast player, free and without an account; and,
among them, listeners who also want videos they did not make (YouTube videos, other people's
channels, audiobooks posted as video) as podcast feeds.

## Product Purpose

The Listenjar app is a podcast player first: follow any RSS feed or a show from the directory,
refresh, download for offline, Up Next, playback speed, a sleep timer, and the system's media
controls and headphone buttons. All of it is free and needs no account. A single YouTube video
plays here as an episode of its own, also free.

Free stays 100% on the device: nothing is uploaded, so nothing a listener adds ever expires.
Paying makes the player YouTube-charged. A paid plan adds YouTube playlists and channels,
followed like any show, and podcasts of the listener's own: YouTube videos they gather under
their own name and artwork. Every one starts on the device, in the app's library: its videos
list at once and stream from YouTube. The plans differ in what happens next:

- Local YouTube: that's all. The library stays on this device.
- Cloud (Cloud 10 GB or Cloud 100 GB): the same device sync also uploads each video's audio to
  Listenjar, and the show becomes a classic podcast: an RSS feed Listenjar hosts, for any podcast
  app. From there the library syncs between the listener's devices the classic way, RSS shows,
  places and Up Next, with nothing in it about YouTube. The plan's storage pays for the audio.

Shows, episodes and stored audio all match by source URL, rewritten to one canonical form per
source (YouTube's short and mobile links become its watch link), so another source than YouTube
fits the same way. The listener never picks where a show lives: the plan says.

Success: a listener who came for a podcast player stays for one that is quiet, fast and
complete; a Cloud listener sets their feeds up once and forgets them.

## Positioning

A podcast player first, a YouTube player when you pay: the player is free, and YouTube channels
(Local YouTube) and feeds for any podcast app (Cloud) are what people pay for. Downloads from
YouTube happen on the listener's own device, not on a server. The app is
open source and sends no telemetry, tracing or crash reports.

## Operating Context

- Phones, in a pocket or on a lock screen, and computers, beside other work: most listening is
  away from the window, through the system's media controls and headphones.
- Its counterpart is the Listenjar website (listenjar.com), where listeners also manage feeds.
- Talks to each podcast's host, Apple's podcast directory, YouTube, and the API in
  [public.yaml](public.yaml) (`https://api.listenjar.com`) only when signed in.

## Capabilities and Constraints

- Ships on macOS, Windows, Linux, Android and iOS.
- A Flutter app: one Dart codebase drawn by Flutter on every OS. No HTML, no webview, no browser
  build. One design language everywhere. Preview it by running the native app
  (`moon run app:dev`).
- `adaptive` above routes design work to the native, source-based reviews instead of browser
  tooling. It does not mean the design changes per OS, and there is no SwiftUI, UIKit or Compose
  here: apply iOS/Android guidance only where it is about platform conventions (shortcuts, menus,
  windows, media controls).
- Behaves like the best open-source podcast players (AntennaPod): the same directory, feed
  handling and defaults, unless there is a reason to differ.

## Brand Commitments

- Name: Listenjar. Logo: not made yet (`resources/icon.png` is a placeholder).
- Visual reference named by the user: [mave.digital](https://mave.digital/). New visual work takes its
  direction from it. Take its feel and structure, not its brand: no copying its name, logo, illustrations
  or copy.

## Evidence on Hand

None yet: no testimonials, reviews or usage numbers. Do not invent them.

## Product Principles

1. A complete podcast player, free: nothing a classic player does sits behind an account.
2. Listening comes first: the player is one press away on every screen, and the system's controls
   work everywhere.
3. Say plainly what happens on the listener's device: what it downloads, where, and that it
   deletes it.
4. Nothing leaves the device except requests to podcast hosts, Apple's directory and YouTube, and,
   signed in, uploads to Listenjar.
