// Signing in follows RFC 8252 (OAuth for native apps): the app listens on a
// loopback port, opens listenjar.com/desktop/authorize in the browser, where
// the person signs in and allows the app, and the browser comes back to the
// port with a one-time code. The app trades the code, with the PKCE verifier
// only it knows, for its own token (POST /desktop/token in public.yaml).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cancellation_token/cancellation_token.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'backend/api.dart';
import 'config.dart';

/// How long the app waits for the browser.
const signInTimeout = Duration(minutes: 10);

/// The token's key in the system credential store.
const _tokenKey = 'api-token';

// The legacy file-based keychain on macOS needs no Keychain Sharing
// provisioning, so unsigned and ad-hoc builds can keep the token too.
const _storage = FlutterSecureStorage(mOptions: MacOsOptions(usesDataProtectionKeychain: false));

final class AccessDenied implements Exception {
  const AccessDenied();
  @override
  String toString() => 'access was not allowed in the browser';
}

/// The API client, sending `Authorization: Bearer` while [token] has one.
PublicApiClient apiClient(Uri api, http.Client client, String? Function() token) => PublicApiClient(
  baseUri: api,
  send: (request) {
    if (token() case final value?) request.headers['Authorization'] = 'Bearer $value';
    return client.send(request);
  },
);

// Debug builds keep their token, which only works against the local
// backend, in a file in the app's support directory instead: each rebuild is
// signed afresh, so the Keychain would ask for the login password on every
// run to hand an item to the "new" app.
Future<File> _debugTokenFile() async => File('${(await getApplicationSupportDirectory()).path}/$_tokenKey');

/// The token a previous run kept, null if there is none.
Future<String?> loadToken() async {
  if (!kDebugMode) return _storage.read(key: _tokenKey);
  final file = await _debugTokenFile();
  return await file.exists() ? file.readAsString() : null;
}

Future<void> saveToken(String value) async {
  if (!kDebugMode) return _storage.write(key: _tokenKey, value: value);
  final file = await _debugTokenFile();
  await file.parent.create(recursive: true);
  await file.writeAsString(value, flush: true);
}

Future<void> forgetToken() async {
  if (!kDebugMode) return _storage.delete(key: _tokenKey);
  final file = await _debugTokenFile();
  if (await file.exists()) await file.delete();
}

/// Whose the token is: null when it no longer works.
Future<User?> currentUser(PublicApiClient api, CancellationToken token) async {
  try {
    return await api.getMe().asCancellable(token);
  } on ApiStatusException catch (e) {
    if (e.statusCode == HttpStatus.unauthorized) return null;
    rethrow;
  }
}

String _randomString() {
  final random = Random.secure();
  return base64Url.encode([for (var i = 0; i < 32; i++) random.nextInt(256)]).replaceAll('=', '');
}

/// Runs the browser round trip and returns the app's new session. [open]
/// shows a URL in the default browser.
Future<Session> signIn(
  PublicApiClient api,
  Uri web,
  Future<void> Function(Uri) open,
  CancellationToken cancellation,
) async {
  final token = cancellation.merge(TimeoutCancellationToken(signInTimeout));
  final verifier = _randomString();
  final state = _randomString();
  final challenge = base64Url.encode(sha256.convert(ascii.encode(verifier)).bytes).replaceAll('=', '');

  // 127.0.0.1 rather than localhost, so no resolver or IPv6 preference can
  // send the browser elsewhere (RFC 8252 section 8.3).
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  try {
    final redirectUri = 'http://127.0.0.1:${server.port}/callback';
    final code = CancellableCompleter<String>(token);
    server.listen((request) async {
      final query = request.uri.queryParameters;
      final response = request.response;
      if (request.method != 'GET' || request.uri.path != '/callback') {
        response.statusCode = HttpStatus.notFound;
      } else if (query['state'] != state) {
        response
          ..statusCode = HttpStatus.badRequest
          ..write('This sign-in is not the one the app started.');
      } else {
        final value = query['code'] ?? '';
        final denied = query['error'] != null || value.isEmpty;
        response.headers.contentType = ContentType.html;
        response.write(denied
          ? _callbackPage('Not signed in', 'You chose Cancel, so the app isn’t signed in. Sign in again from the app.')
          : _callbackPage('Back to ListenJar', 'The app is signed in. You can close this tab.'));
        if (!code.isCompleted) denied ? code.completeError(const AccessDenied()) : code.complete(value);
      }
      await response.close();
    });

    await open(web.resolve('/desktop/authorize').replace(queryParameters: {
      'redirect_uri': redirectUri,
      'code_challenge': challenge,
      'code_challenge_method': 'S256',
      'state': state,
    }));
    return await api.createDesktopToken(body: DesktopTokenRequest(
      code: await code.future,
      codeVerifier: verifier,
      redirectUri: redirectUri,
    )).asCancellable(token);
  } finally {
    await server.close(force: true);
  }
}

/// The page the browser lands on, in listenjar.com's look (DESIGN.md): the
/// authorize page's white card on paper. It hands the person back to the app
/// through [appScheme], which the runners register (Info.plist, the Android
/// manifest, the Windows registry, a Linux .desktop file) and which focuses
/// the running window; the button covers browsers that want a click first.
String _callbackPage(String title, String body) {
  const link = '$appScheme://sign-in';
  return '<!doctype html><html lang="en"><meta charset="utf-8">'
    '<meta name="viewport" content="width=device-width,initial-scale=1">'
    '<meta name="color-scheme" content="light"><meta name="theme-color" content="#f5f4f0">'
    '<title>$title | ListenJar</title>'
    '<link rel="icon" href="data:image/svg+xml,${Uri.encodeComponent(_mark)}">'
    '<style>$_callbackStyle</style>'
    '<main><section>$_mark<h1>$title</h1><p>$body</p>'
    '<a class="button" href="$link">Open ListenJar'
    '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M5 12h13M13 6l6 6-6 6"/></svg></a>'
    '</section></main>'
    '<script>location.href = "$link"</script></html>';
}

/// The mark on its periwinkle tile (apps/web/src/assets/favicon.svg).
const _mark = '<svg class="mark" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200" aria-hidden="true">'
  '<rect width="200" height="200" rx="44" fill="#5165EE"/>'
  '<path d="M60 96A44 44 0 0 1 104 140H144A84 84 0 0 0 60 56" fill="none" stroke="#fff" stroke-width="21" '
  'stroke-linecap="round" stroke-linejoin="round"/><circle cx="60" cy="140" r="14" fill="#fff"/></svg>';

/// The tokens of apps/web/src/styles/app.css that the page uses.
const _callbackStyle = r'''
*{box-sizing:border-box;margin:0}
body{min-height:100svh;display:grid;place-items:center;padding:24px clamp(16px,4vw,40px);
background:#f5f4f0;color:#1c1d20;-webkit-font-smoothing:antialiased;
font:16px/1.55 system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif}
::selection{background:#e7e4fc;color:#0a0b0f}
section{width:100%;max-width:460px;background:#fff;border-radius:28px;padding:clamp(24px,4vw,36px);
box-shadow:0 12px 32px -14px rgb(23 26 56/.18)}
.mark{display:block;width:44px;height:44px;margin-bottom:22px}
h1{font-size:clamp(24px,3vw,30px);line-height:1.15;font-weight:700;letter-spacing:-.03em;text-wrap:balance}
p{margin-top:12px;color:#5b5e69}
.button{display:inline-flex;align-items:center;gap:8px;margin-top:28px;min-height:44px;padding:0 20px;
border-radius:14px;background:#5165ee;color:#fff;font-weight:600;font-size:15px;line-height:1;text-decoration:none;
box-shadow:0 10px 24px -12px rgb(81 101 238/.9);transition:background-color 150ms cubic-bezier(.16,1,.3,1)}
.button:hover{background:#4054e0}
.button:active{transform:translateY(1px)}
.button:focus-visible{outline:2px solid #5165ee;outline-offset:3px}
.button svg{width:18px;height:18px;fill:none;stroke:currentColor;stroke-width:1.8;stroke-linecap:round;stroke-linejoin:round}
''';
