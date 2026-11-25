// Signing in, by the app itself, in the three ways listenjar.com has
// (public.yaml): Google, an email and password, and passkeys. Each answers a
// session whose token the system credential store keeps.
//
// Google follows RFC 8252 (OAuth for native apps): the app listens on a
// loopback port, opens Google in the browser for the "ListenJar desktop"
// client, and Google comes back to the port with a one-time code, which the
// API trades, with the PKCE verifier only the app knows, for the app's
// token. Passkeys are listenjar.com's, through the platform's own prompt
// (package:passkeys' platform halves): macOS and iOS with the app's
// Associated Domain, Android's Credential Manager and Windows Hello. Linux
// has none.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cancellation_token/cancellation_token.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:passkeys_platform_interface/passkeys_platform_interface.dart';
import 'package:passkeys_platform_interface/types/types.dart';
import 'package:path_provider/path_provider.dart';

import 'backend/api.dart';
import 'config.dart';

/// How long the app waits for the browser, or the passkey prompt.
const signInTimeout = Duration(minutes: 10);

/// The token's key in the system credential store.
const _tokenKey = 'api-token';

// The legacy file-based keychain on macOS needs no Keychain Sharing
// provisioning, so unsigned and ad-hoc builds can keep the token too.
const _storage = FlutterSecureStorage(mOptions: MacOsOptions(usesDataProtectionKeychain: false));

/// Why the API or the person said no, each with what to say about it.
sealed class SignInRefused implements Exception {
  const SignInRefused();
}

/// Cancel on Google's page.
final class AccessDenied extends SignInRefused {
  const AccessDenied();
  @override
  String toString() => 'access was not allowed in the browser';
}

/// Google refused the code, or the account has no verified email.
final class GoogleRefused extends SignInRefused {
  const GoogleRefused();
}

/// No account with that email and password.
final class WrongPassword extends SignInRefused {
  const WrongPassword();
}

/// Ten wrong passwords for the address in 15 minutes.
final class TooManyPasswords extends SignInRefused {
  const TooManyPasswords();
}

/// The passkey belongs to no account, or its answer didn't check out.
final class UnknownPasskey extends SignInRefused {
  const UnknownPasskey();
}

/// The platform has no ListenJar passkey to offer.
final class NoPasskey extends SignInRefused {
  const NoPasskey();
}

/// The platform won't use listenjar.com's passkeys for this build: one
/// without the Associated Domain, or a development build, whose passkeys are
/// localhost's.
final class PasskeysUnavailable extends SignInRefused {
  const PasskeysUnavailable();
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
Future<File> _debugFile(String key) async => File('${(await getApplicationSupportDirectory()).path}/$key');

Future<String?> _read(String key) async {
  if (!kDebugMode) return _storage.read(key: key);
  final file = await _debugFile(key);
  return await file.exists() ? file.readAsString() : null;
}

Future<void> _write(String key, String value) async {
  if (!kDebugMode) return _storage.write(key: key, value: value);
  final file = await _debugFile(key);
  await file.parent.create(recursive: true);
  await file.writeAsString(value, flush: true);
}

Future<void> _delete(String key) async {
  if (!kDebugMode) return _storage.delete(key: key);
  final file = await _debugFile(key);
  if (await file.exists()) await file.delete();
}

/// The token a previous run kept, null if there is none.
Future<String?> loadToken() => _read(_tokenKey);

Future<void> saveToken(String value) => _write(_tokenKey, value);

/// Forgets the token and who it was.
Future<void> forgetToken() async {
  await _delete(_tokenKey);
  await _delete(_userKey);
}

/// Who the kept token was when the API last said, beside it: the listener
/// and their plan, for a start while the API can't be reached.
const _userKey = 'api-user';

/// The listener the kept token was last known to be; null if none, or if
/// what was kept no longer reads.
Future<User?> loadKeptUser() async {
  final json = await _read(_userKey);
  if (json == null) return null;
  try {
    return User.fromJson(jsonDecode(json));
  } catch (_) {
    return null;
  }
}

Future<void> keepUser(User user) => _write(_userKey, jsonEncode(user.toJson()));

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

/// [call]'s answer, or [refused] for the [status] it answers.
Future<T> _refusing<T>(Future<T> call, int status, SignInRefused refused) async {
  try {
    return await call;
  } on ApiStatusException catch (e) {
    if (e.statusCode == status) throw refused;
    rethrow;
  }
}

/// Signs in with Google: opens Google's page with [open] in the default
/// browser and waits for it to come back to the app's loopback address.
Future<Session> signInWithGoogle(
  PublicApiClient api,
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
    final redirectUri = 'http://127.0.0.1:${server.port}/';
    final code = CancellableCompleter<String>(token);
    server.listen((request) async {
      final query = request.uri.queryParameters;
      final response = request.response;
      if (request.method != 'GET' || request.uri.path != '/') {
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
          ? _callbackPage('Not signed in', 'You chose Cancel on Google’s page, so the app isn’t signed in. Sign in again from the app.')
          : _callbackPage('Back to ListenJar', 'The app is finishing signing you in. You can close this tab.'));
        if (!code.isCompleted) denied ? code.completeError(const AccessDenied()) : code.complete(value);
      }
      await response.close();
    });

    final google = await api
      .desktopGoogleAuthUrl(redirectUri: redirectUri, state: state, codeChallenge: challenge)
      .asCancellable(token);
    await open(Uri.parse(google.url));
    return await _refusing(
      api.signInWithGoogle(body: GoogleSignIn(code: await code.future, codeVerifier: verifier, redirectUri: redirectUri)),
      HttpStatus.badRequest,
      const GoogleRefused(),
    ).asCancellable(token);
  } finally {
    await server.close(force: true);
  }
}

/// Signs in with an email and password.
Future<Session> signInWithPassword(PublicApiClient api, String email, String password, CancellationToken token) async {
  try {
    return await api.signInWithPassword(body: PasswordSignIn(email: email.trim(), password: password)).asCancellable(token);
  } on ApiStatusException catch (e) {
    throw switch (e.statusCode) {
      HttpStatus.badRequest || HttpStatus.unauthorized => const WrongPassword(),
      HttpStatus.tooManyRequests => const TooManyPasswords(),
      _ => e,
    };
  }
}

/// Emails [email] a link that makes its account with [password], or, when
/// it has one, a link that sets its password. False when the API refused
/// the address or the password's length.
Future<bool> signUp(PublicApiClient api, String email, String password, CancellationToken token) =>
  _accepted(api.signUp(body: SignUp(email: email.trim(), password: password)), token);

/// Emails [email], if it has an account, a link that sets its password.
Future<bool> requestPasswordLink(PublicApiClient api, String email, CancellationToken token) =>
  _accepted(api.requestPasswordLink(body: PasswordLinkRequest(email: email.trim())), token);

Future<bool> _accepted(Future<void> call, CancellationToken token) async {
  try {
    await call.asCancellable(token);
    return true;
  } on ApiStatusException catch (e) {
    if (e.statusCode == HttpStatus.badRequest) return false;
    rethrow;
  }
}

/// Whether this device has a passkey prompt the app can use. The app's
/// minimums (macOS 15, iOS 18, Android 9 / API 28) all have one, but there
/// it serves only listenjar.com, and only to a build listenjar.com vouches
/// for (/.well-known/apple-app-site-association, assetlinks.json): a debug
/// build signs in to localhost, which none of them will. Windows needs
/// Windows Hello's WebAuthn.
Future<bool> passkeysAvailable() async {
  if (kIsWeb) return false;
  if (Platform.isMacOS || Platform.isIOS || Platform.isAndroid) return !kDebugMode;
  if (!Platform.isWindows) return false;
  try {
    return (await PasskeysPlatform.instance.getAvailability()).hasPasskeySupport;
  } on PlatformException {
    return false;
  }
}

/// The platform's answer to listenjar.com's [options], or the
/// [SignInRefused] its refusal means.
Future<AuthenticateResponseType> _passkeyAnswer(WebAuthnJson options, CancellationToken token) async {
  final platform = PasskeysPlatform.instance;
  try {
    return await platform
      .authenticate(AuthenticateRequestType.fromJson(
        Map<String, dynamic>.of(options),
        preferImmediatelyAvailableCredentials: false,
      ))
      .asCancellable(token, onCancel: () => unawaited(platform.cancelCurrentAuthenticatorOperation()));
  } on PlatformException catch (e) {
    throw switch (e.code) {
      // A build signed without its provisioning profile (tool/sign-macos.sh)
      // has no application identifier to match the Associated Domain to.
      'failed' when e.message?.contains('application identifier') ?? false => const PasskeysUnavailable(),
      'cancelled' || 'user-cancelled' => const CancelledException(),
      'android-no-credential' || 'no-credentials-available' || 'not-found' => const NoPasskey(),
      'domain-not-associated' ||
      'deviceNotSupported' ||
      'android-passkey-unsupported' ||
      'not-supported' => const PasskeysUnavailable(),
      _ => e,
    };
  }
}

/// Signs in with a passkey the platform offers for listenjar.com. Cancelling
/// the prompt cancels [cancellation]'s wait as if the person pressed Cancel.
Future<Session> signInWithPasskey(PublicApiClient api, CancellationToken cancellation) async {
  final token = cancellation.merge(TimeoutCancellationToken(signInTimeout));
  final options = await api.passkeySignInOptions().asCancellable(token);
  final answer = await _passkeyAnswer(options, token);
  // AuthenticationResponseJSON, as SimpleWebAuthn's server takes it.
  return _refusing(
    api.signInWithPasskey(body: {
      'id': answer.id,
      'rawId': answer.rawId,
      'type': 'public-key',
      'response': {
        'clientDataJSON': answer.clientDataJSON,
        'authenticatorData': answer.authenticatorData,
        'signature': answer.signature,
        if (answer.userHandle.isNotEmpty) 'userHandle': answer.userHandle,
      },
      'clientExtensionResults': <String, Object?>{},
    }),
    HttpStatus.unauthorized,
    const UnknownPasskey(),
  ).asCancellable(token);
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
