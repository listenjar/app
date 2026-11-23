// Who is signed in: the token kept in the system credential store, the
// user it belongs to, and the ListenJar API client that sends it
// (signin.dart has the browser round trip). One per process; the window
// signs in and out through it, and Feeds (feeds.dart) follows it. No
// widgets here.
import 'dart:async';

import 'package:cancellation_token/cancellation_token.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'backend/api.dart';
import 'config.dart';
import 'signin.dart' hide signIn;
import 'signin.dart' as browser show signIn;

const callTimeout = Duration(seconds: 30);

final class Account extends ChangeNotifier {
  final _config = currentConfig();
  final _http = http.Client();
  final _life = CancellationToken();
  String? _token;

  /// The ListenJar API, as whoever is signed in.
  late final PublicApiClient api = apiClient(_config.api, _http, () => _token);

  /// Null while signed out. [restoring] covers reading the kept token at
  /// start, [signingIn] the browser round trip.
  User? user;
  Object? authError;
  bool restoring = true;
  CancellationToken? signingIn;

  /// Cancelled with the account, and after [callTimeout].
  CancellationToken timeout() => _life.merge(TimeoutCancellationToken(callTimeout));

  /// Reads the token a previous run kept and asks the API whose it is,
  /// dropping it if it no longer works.
  Future<void> restore() async {
    restoring = true;
    notifyListeners();
    try {
      _token = await loadToken();
      if (_token != null) {
        user = await currentUser(api, timeout());
        if (user == null) {
          _token = null;
          await forgetToken();
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

  /// Asks the API for the listener again: their plan and storage change
  /// on the website (checkout) and as uploads land. At most every few
  /// seconds unless [force]d; failures keep what is shown.
  Future<void> refresh({bool force = false}) async {
    final now = DateTime.now();
    if (_token == null || _refreshing || (!force && now.difference(_refreshed) < _refreshEvery)) return;
    _refreshing = true;
    _refreshed = now;
    try {
      final fresh = await api.getMe().asCancellable(timeout());
      if (_token != null) {
        user = fresh;
        notifyListeners();
      }
    } catch (_) {
      // Shown as it was; the next refresh tries again.
    } finally {
      _refreshing = false;
    }
  }

  static const _refreshEvery = Duration(seconds: 5);
  bool _refreshing = false;
  DateTime _refreshed = DateTime.fromMillisecondsSinceEpoch(0);

  /// Runs the browser round trip, at most once at a time, opening its page
  /// with [open], and keeps the token.
  Future<void> signIn(Future<void> Function(Uri) open) async {
    if (signingIn != null) return;
    final token = CancellationToken();
    signingIn = token;
    authError = null;
    notifyListeners();
    try {
      final session = await browser.signIn(api, _config.web, open, _life.merge(token));
      await saveToken(session.token);
      _token = session.token;
      user = session.user;
    } on CancelledException {
      // Cancelled, or the account closed.
    } catch (e) {
      authError = e;
    }
    signingIn = null;
    notifyListeners();
  }

  /// Revokes the token and forgets it, even when the API is unreachable.
  Future<void> signOut() async {
    final revoked = _token;
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

  /// Quiet once disposed: calls in flight then finish into nothing.
  @override
  void notifyListeners() {
    if (!_life.isCancelled) super.notifyListeners();
  }

  @override
  void dispose() {
    _life.cancel();
    _http.close();
    super.dispose();
  }
}
