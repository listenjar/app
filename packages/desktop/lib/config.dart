import 'package:flutter/foundation.dart';

/// Everything the app needs to know about its environment: where the
/// ListenJar API (public.yaml) is, and the website it signs in through.
/// Besides these the app reaches only podcast hosts, Apple's podcast
/// directory and YouTube (README.md): no telemetry, tracing or crash reports.
typedef Config = ({Uri api, Uri web});

/// Release and profile builds.
final prodConfig = (api: Uri.parse('https://api.listenjar.com'), web: Uri.parse('https://listenjar.com'));

/// Debug builds: the backend's and the website's local dev servers
/// (`moon run dev` in the listenjar monorepo).
final devConfig = (api: Uri.parse('http://localhost:8787'), web: Uri.parse('http://localhost:3000'));

// The same switch as the token's storage (signin.dart), [appScheme] and each
// platform's app ID: a debug build is a separate app from a release.
Config currentConfig() => kDebugMode ? devConfig : prodConfig;

/// The URL scheme the app opens on: the sign-in callback page in the browser
/// links to `<scheme>://sign-in` to bring the app back to the front. Debug
/// builds register their own, so a dev build and an installed release don't
/// take each other's links; the platform runners pick the same one per build.
const appScheme = kDebugMode ? 'listenjar-dev' : 'listenjar';
