// Cloudflare Turnstile for signing up by email and asking for a password link
// (public.yaml's /desktop/signups and /desktop/password-resets check its
// token): the same widget as listenjar.com's sign-up. Turnstile runs only on a page of the widget's own hostname, so the
// app shows listenjar.com/app-check, which holds nothing but the widget: in a
// WebView on macOS, iOS and Android, where the page hands each token over
// the `ListenjarTurnstile` JavaScript channel. Windows and Linux have no
// WebView the app ships with, so there the page opens in the browser and
// hands the token to the app's loopback address instead (signin.dart's
// turnstileInBrowser), like signing in with Google.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'config.dart';
import 'theme.dart' as brand;

/// Whether this platform shows the widget in a WebView.
bool get turnstileEmbeds => !kIsWeb && (Platform.isMacOS || Platform.isIOS || Platform.isAndroid);

/// The widget's height on the page: Turnstile's own, 65 points.
const _height = 66.0;

/// The page in its WebView, and the newest token it gave that isn't spent.
/// Each token works once and for 300 seconds.
final class TurnstileCheck extends ChangeNotifier {
  TurnstileCheck() {
    unawaited(_load());
  }

  late final WebViewController controller = WebViewController()
    ..setJavaScriptMode(JavaScriptMode.unrestricted)
    ..addJavaScriptChannel('ListenjarTurnstile', onMessageReceived: (message) => _heard(message.message));

  String? _token;
  final _waiting = <Completer<String>>[];

  /// The widget couldn't run: offline, blocked, or Cloudflare refused this
  /// WebView. Cleared by [retry].
  bool failed = false;

  Future<void> _load() async {
    // The panel shows through around the widget. WKWebView on macOS has no
    // transparent background, so there the page's paper shows instead.
    try {
      await controller.setBackgroundColor(const Color(0x00000000));
    } on UnimplementedError {
      // macOS
    }
    await controller.loadRequest(currentConfig().web.resolve('/app-check'));
  }

  void _heard(String raw) {
    final message = switch (_decode(raw)) {
      final Map<String, Object?> map => map,
      _ => const <String, Object?>{},
    };
    switch (message) {
      case {'token': final String token} when token.isNotEmpty:
        _token = token;
        failed = false;
        for (final waiting in _waiting) {
          waiting.complete(token);
        }
        _waiting.clear();
      case {'expired': true}:
        _token = null;
      case {'error': _}:
        failed = true;
    }
    notifyListeners();
  }

  static Object? _decode(String raw) {
    try {
      return jsonDecode(raw);
    } on FormatException {
      return null;
    }
  }

  /// The unspent token, waiting for the widget when it has none; null when
  /// [timeout] passes first.
  Future<String?> token({Duration timeout = const Duration(seconds: 20)}) {
    if (_token case final token?) return Future.value(token);
    final waiting = Completer<String>();
    _waiting.add(waiting);
    return waiting.future.then<String?>((token) => token).timeout(timeout, onTimeout: () {
      _waiting.remove(waiting);
      return null;
    });
  }

  /// Uses up the token, and asks the page for the next.
  void spend() {
    _token = null;
    unawaited(controller.reload());
  }

  /// Loads the page again after it failed.
  void retry() {
    failed = false;
    notifyListeners();
    unawaited(controller.reload());
  }
}

/// The widget, sized as Turnstile draws it, and what to do when it fails.
final class TurnstileView extends StatelessWidget {
  const TurnstileView(this.check, {super.key});
  final TurnstileCheck check;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    Semantics(
      label: 'Cloudflare’s check that you’re a person',
      child: SizedBox(height: _height, child: WebViewWidget(controller: check.controller)),
    ),
    ListenableBuilder(
      listenable: check,
      builder: (context, _) => !check.failed
        ? const SizedBox.shrink()
        : Row(children: [
            Expanded(
              child: Text(
                'Cloudflare’s check didn’t load. Check your connection, then try again.',
                style: Theme.of(context).textTheme.bodySmall!.copyWith(color: brand.fgSoft),
              ),
            ),
            TextButton(
              style: brand.button(brand.Tone.quiet, brand.ButtonSize.sm),
              onPressed: check.retry,
              child: const Text('Try again'),
            ),
          ]),
    ),
  ]);
}
