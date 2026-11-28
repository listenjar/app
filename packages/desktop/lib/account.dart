// Who is signed in: the token kept in the system credential store, the
// user it belongs to, and the Listenjar API client that sends it
// (signin.dart has the ways to sign in). One per process; the window
// signs in and out through it, and Feeds (feeds.dart) follows it. No
// widgets here.
import 'dart:async';

import 'package:cancellation_token/cancellation_token.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import 'backend/api.dart';
import 'config.dart';
import 'signin.dart' hide signInWithGoogle, signInWithPasskey, signInWithPassword, signUp, requestPasswordLink;
import 'signin.dart' as auth;

final _log = Logger('account');

const callTimeout = Duration(seconds: 30);

/// The ways to sign in, as listenjar.com's sign-in page has them.
enum SignInMethod { google, passkey, password }

final class Account extends ChangeNotifier {
  final _config = currentConfig();
  final _http = http.Client();
  final _life = CancellationToken();
  String? _token;

  /// The Listenjar API, as whoever is signed in.
  late final PublicApiClient api = apiClient(_config.api, _http, () => _token);

  /// Null while signed out. [restoring] covers reading the kept token at
  /// start, [signingIn] the sign-in under way and how, which its token
  /// cancels.
  User? user;
  Object? authError;
  bool restoring = true;
  ({SignInMethod method, CancellationToken token})? signingIn;

  /// Cancelled with the account, and after [callTimeout].
  CancellationToken timeout() => _life.merge(TimeoutCancellationToken(callTimeout));

  /// Reads the token a previous run kept and asks the API whose it is,
  /// dropping it if it no longer works. When the API can't say (offline, or
  /// failing), the listener stays who they were last time, with their plan,
  /// and the API is asked again until it answers.
  Future<void> restore() async {
    restoring = true;
    notifyListeners();
    try {
      _token = await loadToken();
      if (_token != null) {
        try {
          user = await currentUser(api, timeout());
          if (user == null) {
            await _forget();
          } else {
            await keepUser(user!);
          }
        } on CancelledException {
          rethrow;
        } catch (e) {
          _log.info('Couldn’t ask the API who is signed in; going on as last time', e);
          user = await loadKeptUser();
          _retrySoon();
        }
      }
    } on CancelledException {
      if (_life.isCancelled) return;
    } catch (e) {
      authError = e;
    }
    restoring = false;
    notifyListeners();
  }

  /// Once [restore] knows who is signed in, and their plan; at once after.
  Future<void> restored() async {
    if (!restoring) return;
    final done = Completer<void>();
    void check() {
      if (!restoring && !done.isCompleted) done.complete();
    }

    addListener(check);
    try {
      await done.future;
    } finally {
      removeListener(check);
    }
  }

  /// While the API hasn't answered since the start, asks again, less often
  /// each time.
  Timer? _retry;
  var _retryIn = _firstRetry;
  static const _firstRetry = Duration(seconds: 5);
  static const _lastRetry = Duration(minutes: 5);

  bool get _retrying => _retry != null;

  void _stopRetrying() {
    _retry?.cancel();
    _retry = null;
    _retryIn = _firstRetry;
  }

  void _retrySoon() {
    _retry?.cancel();
    _retry = Timer(_retryIn, () => unawaited(refresh(force: true)));
    _retryIn = _retryIn * 2 > _lastRetry ? _lastRetry : _retryIn * 2;
  }

  /// Signed out here: the token was revoked or expired.
  Future<void> _forget() async {
    _stopRetrying();
    _token = null;
    user = null;
    await forgetToken();
  }

  /// Asks the API for the listener again: their plan and storage change
  /// on Stripe (checkout, the billing portal) and as uploads land. At most every few
  /// seconds unless [force]d; failures keep what is shown, and a token the
  /// API no longer takes signs out.
  Future<void> refresh({bool force = false}) async {
    final now = DateTime.now();
    if (_token == null || _refreshing || (!force && now.difference(_refreshed) < _refreshEvery)) return;
    _refreshing = true;
    _refreshed = now;
    final asked = _token;
    try {
      final fresh = await currentUser(api, timeout());
      if (_token != asked) return;
      _stopRetrying();
      if (fresh == null) {
        await _forget();
      } else {
        user = fresh;
        await keepUser(fresh);
      }
      notifyListeners();
    } catch (_) {
      // Shown as it was; the next refresh tries again.
      if (_retrying && _token == asked) _retrySoon();
    } finally {
      _refreshing = false;
    }
  }

  static const _refreshEvery = Duration(seconds: 5);
  bool _refreshing = false;
  DateTime _refreshed = DateTime.fromMillisecondsSinceEpoch(0);

  /// Signs in with Google, opening its page in the browser with [open].
  Future<void> signInWithGoogle(Future<void> Function(Uri) open) =>
    _signIn(SignInMethod.google, (token) => auth.signInWithGoogle(api, open, token));

  /// Signs in with a passkey from the platform's prompt.
  Future<void> signInWithPasskey() => _signIn(SignInMethod.passkey, (token) => auth.signInWithPasskey(api, token));

  Future<void> signInWithPassword(String email, String password) =>
    _signIn(SignInMethod.password, (token) => auth.signInWithPassword(api, email, password, token));

  /// Emails a sign-up link; false when the address or password won't do.
  Future<bool> signUp(String email, String password) => auth.signUp(api, email, password, timeout());

  /// Emails a link that sets the password; false when the address won't do.
  Future<bool> requestPasswordLink(String email) => auth.requestPasswordLink(api, email, timeout());

  /// Runs one sign-in at a time and keeps the token it gets.
  Future<void> _signIn(SignInMethod method, Future<Session> Function(CancellationToken) how) async {
    if (signingIn != null) return;
    final token = CancellationToken();
    signingIn = (method: method, token: token);
    authError = null;
    notifyListeners();
    try {
      final session = await how(_life.merge(token));
      await saveToken(session.token);
      await keepUser(session.user);
      _token = session.token;
      user = session.user;
    } on CancelledException {
      // Cancelled, or the account closed.
    } on SignInRefused catch (e) {
      _log.info('${method.name} sign-in refused: ${e.runtimeType}');
      authError = e;
    } catch (e, stack) {
      _log.warning('${method.name} sign-in failed', e, stack);
      authError = e;
    }
    signingIn = null;
    notifyListeners();
  }

  /// Revokes the token and forgets it, even when the API is unreachable.
  Future<void> signOut() async {
    final revoked = _token;
    _stopRetrying();
    user = null;
    _token = null;
    notifyListeners();
    try {
      await forgetToken();
      if (revoked != null) await apiClient(_config.api, _http, () => revoked).logout().asCancellable(timeout());
    } on CancelledException {
      return;
    } catch (e) {
      authError = e is ApiStatusException ? null : e;
      notifyListeners();
    }
  }

  /// Deleting an account removes every feed, its RSS, audio and artwork on
  /// the server, which takes longer than an ordinary call.
  static const _deleteTimeout = Duration(minutes: 3);

  /// Deletes the account on the server, with everything of it, then forgets
  /// it here as signing out does. The server's 401 means it is gone already.
  /// Throws when the server couldn't: the listener stays signed in, and
  /// asking again finishes the job.
  Future<void> deleteAccount() async {
    try {
      await api.deleteAccount().asCancellable(_life.merge(TimeoutCancellationToken(_deleteTimeout)));
    } on ApiStatusException catch (e) {
      if (e.statusCode != 401) rethrow;
    }
    _log.info('account deleted');
    user = null;
    _token = null;
    authError = null;
    notifyListeners();
    await forgetToken();
  }

  /// Quiet once disposed: calls in flight then finish into nothing.
  @override
  void notifyListeners() {
    if (!_life.isCancelled) super.notifyListeners();
  }

  @override
  void dispose() {
    _life.cancel();
    _retry?.cancel();
    _http.close();
    super.dispose();
  }
}
