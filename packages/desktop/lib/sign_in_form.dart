// Signing in, in Settings' account panel (AccountPanel in cloud.dart): the
// app's version of listenjar.com/login, with the same three ways in, the same
// order and the same words. Google and a passkey first, then the email form,
// which also signs up and asks for a password link; both links open on
// listenjar.com, and the person comes back here to sign in with the password.
// Signing up passes Cloudflare Turnstile first, as on listenjar.com/signup
// (turnstile.dart): its widget sits above Create account, or, without a
// WebView, opens in the browser when Create account is pressed.
// The way this device signed in last wears listenjar.com's "Last used" mark.
import 'dart:async';

import 'package:cancellation_token/cancellation_token.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import 'account.dart';
import 'config.dart';
import 'marks.dart';
import 'signin.dart';
import 'theme.dart' as brand;
import 'turnstile.dart';

/// What the email form is for.
enum _Mode { signIn, signUp, forgot }

/// The email an email form last sent, and what it was.
typedef _Sent = ({String email, _Mode mode});

/// The WebView's widget gave no token in time.
final class _Unchecked implements Exception {
  const _Unchecked();
}

/// The person chose Cancel while the browser's check was open.
final class _Abandoned implements Exception {
  const _Abandoned();
}

/// listenjar.com's words for a held-back email (apps/web's emailLimits.ts).
String tooManyEmails(Duration retryAfter) {
  final seconds = retryAfter.inSeconds < 1 ? 1 : retryAfter.inSeconds;
  final minutes = (seconds / 60).ceil();
  final wait = switch (seconds) {
    1 => 'in a second',
    < 60 => 'in $seconds seconds',
    _ when minutes == 1 => 'in a minute',
    _ when minutes < 90 => 'in $minutes minutes',
    _ => 'in ${(minutes / 60).ceil()} hours',
  };
  return 'That’s a lot of emails for now. Try again $wait.';
}

final class SignInForm extends StatefulWidget {
  const SignInForm({super.key, required this.account, required this.describe, this.why});
  final Account account;

  /// What signing in is for, as a heading and a line under it, in place of
  /// Listenjar Cloud's: the plans sheet's "Sign in to get 10 GB".
  final (String, String)? why;

  /// Says what went wrong when it isn't one of the refusals this form
  /// explains itself (cloud.dart's `failure`).
  final String Function(Object error) describe;

  @override
  State<SignInForm> createState() => _SignInFormState();
}

final class _SignInFormState extends State<SignInForm> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _emailFocus = FocusNode();
  final _passwordFocus = FocusNode();
  var _mode = _Mode.signIn;
  var _showPassword = false;
  var _sending = false;
  _Sent? _sent;

  /// What the last email request couldn't do, said here rather than as the
  /// account's error.
  String? _problem;

  /// Whether this device has passkeys to offer, once it says.
  var _passkeys = false;

  /// Turnstile's widget in a WebView, while the form signs up on a platform
  /// that has one.
  TurnstileCheck? _check;

  /// Cancels Turnstile in the browser, while its page is open.
  CancellationToken? _browserCheck;

  Account get _account => widget.account;

  @override
  void initState() {
    super.initState();
    unawaited(passkeysAvailable().then((available) {
      if (available && mounted) setState(() => _passkeys = true);
    }));
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _emailFocus.dispose();
    _passwordFocus.dispose();
    _check?.dispose();
    _browserCheck?.cancel();
    super.dispose();
  }

  void _switch(_Mode mode) => setState(() {
    _mode = mode;
    _sent = null;
    _problem = null;
    _account.authError = null;
    if (mode == _Mode.signUp && turnstileEmbeds) {
      _check ??= TurnstileCheck();
    } else {
      _check?.dispose();
      _check = null;
    }
  });

  Future<bool> _openBrowser(Uri url) => launchUrl(url, mode: LaunchMode.externalApplication);

  /// A Turnstile token: the WebView's, or the browser's page's.
  Future<String> _turnstileToken() async {
    if (_check case final check?) return await check.token() ?? (throw const _Unchecked());
    final cancel = CancellationToken();
    setState(() => _browserCheck = cancel);
    try {
      return await turnstileInBrowser((url) async {
        if (!await _openBrowser(url)) throw StateError('open the browser');
      }, cancel);
    } on CancelledException {
      if (cancel.isCancelled) throw const _Abandoned();
      rethrow;
    } finally {
      if (mounted) setState(() => _browserCheck = null);
    }
  }

  Future<void> _google() => _account.signInWithGoogle((url) async {
    if (!await _openBrowser(url)) throw StateError('open the browser');
  });

  Future<void> _submit() async {
    if (_busy) return;
    final email = _email.text.trim();
    final password = _password.text;
    switch (_mode) {
      case _Mode.signIn:
        if (email.isEmpty) return _emailFocus.requestFocus();
        if (password.isEmpty) return _passwordFocus.requestFocus();
        setState(() => _problem = null);
        TextInput.finishAutofillContext();
        await _account.signInWithPassword(email, password);
      case _Mode.signUp:
        if (email.isEmpty) return _emailFocus.requestFocus();
        if (password.characters.length < 8) {
          setState(() => _problem = 'Use at least 8 characters for your password.');
          return _passwordFocus.requestFocus();
        }
        await _send(email, () async {
          final turnstile = await _turnstileToken();
          try {
            return await _account.signUp(email, password, turnstile);
          } finally {
            // Each token works once, whatever the answer.
            _check?.spend();
          }
        }, refused: 'Check the email address, and use a password of 8 to 256 characters.');
      case _Mode.forgot:
        if (email.isEmpty) return _emailFocus.requestFocus();
        await _send(email, () => _account.requestPasswordLink(email), refused: 'Check the email address.');
    }
  }

  Future<void> _send(String email, Future<bool> Function() request, {required String refused}) async {
    setState(() {
      _sending = true;
      _problem = null;
    });
    String? problem;
    var sent = false;
    try {
      sent = await request();
      if (!sent) problem = refused;
    } catch (e) {
      problem = switch (e) {
        _Abandoned() => null,
        _Unchecked() => 'Cloudflare hasn’t finished checking that you’re a person. Wait for its check above, then try again.',
        HumanCheckRefused() => 'Cloudflare couldn’t confirm you’re a person. Try again.',
        TooManyEmails(:final retryAfter) => tooManyEmails(retryAfter),
        _ => widget.describe(e),
      };
    }
    if (!mounted) return;
    setState(() {
      _sending = false;
      _problem = problem;
      if (sent) {
        if (_mode == _Mode.signUp) TextInput.finishAutofillContext();
        _sent = (email: email, mode: _mode);
      }
    });
  }

  bool get _busy => _sending || _account.signingIn != null;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: _account,
      builder: (context, _) => switch ((_account.signingIn, _sent)) {
        _ when _browserCheck != null => _waitingForBrowser(
          text,
          _browserCheck!,
          title: 'Confirm you’re a person',
          body: 'Cloudflare checks your browser on the page that opened. The app emails your link when it’s done.',
        ),
        ((method: SignInMethod.google, :final token), _) => _waitingForBrowser(
          text,
          token,
          title: 'Finish in your browser',
          body: 'Pick your Google account on the page that opened. The app signs in when you do.',
        ),
        (null, final sent?) => _sentView(text, sent),
        _ => _form(text),
      },
    );
  }

  /// What the form is for, then the form, filling the panel as it does on a
  /// phone.
  Widget _layout(TextTheme text, String title, String lede, Widget controls) =>
    Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(title, style: text.titleMedium),
      const SizedBox(height: 6),
      Text(lede, style: text.bodyMedium!.copyWith(color: brand.fgSoft)),
      const SizedBox(height: 20),
      controls,
    ]);

  /// Google's page, or Turnstile's, is open in the browser.
  Widget _waitingForBrowser(TextTheme text, CancellationToken token, {required String title, required String body}) => _layout(
    text,
    title,
    body,
    Align(
      alignment: AlignmentDirectional.centerStart,
      child: TextButton(
        style: brand.button(brand.Tone.quiet, brand.ButtonSize.sm),
        onPressed: token.cancel,
        child: const Text('Cancel'),
      ),
    ),
  );

  /// A sign-up or password link went out.
  Widget _sentView(TextTheme text, _Sent sent) {
    final body = switch (sent.mode) {
      _Mode.signUp =>
        'Open the link we sent to ${sent.email} to make your account, then sign in here with your password. '
          'If the address already has an account, the email says so and lets you set a password.',
      _ =>
        'If ${sent.email} has an account, a link to set its password is on its way. '
          'Set it on listenjar.com, then sign in here with it. The link works for an hour.',
    };
    return _layout(
      text,
      'Check your email',
      body,
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: brand.accentShadow(
          enabled: true,
          child: TextButton(
            style: brand.button(brand.Tone.accent, brand.ButtonSize.sm),
            onPressed: () {
              if (sent.mode == _Mode.forgot) _password.clear();
              _switch(_Mode.signIn);
              _passwordFocus.requestFocus();
            },
            child: const Text('Back to sign in'),
          ),
        ),
      ),
    );
  }

  Widget _form(TextTheme text) {
    final signingIn = _account.signingIn?.method;
    final passkeyBusy = signingIn == SignInMethod.passkey;
    final passwordBusy = signingIn == SignInMethod.password || _sending;
    final last = _account.lastSignIn;
    final problem = _problem ?? switch (_account.authError) {
      null => null,
      final error => _explain(error),
    };
    final (title, lede) = switch (_mode) {
      _Mode.signIn => widget.why ?? (
        'Sign in to Listenjar Cloud',
        'Follow whole YouTube channels and playlists, and listen to them in any podcast app.',
      ),
      _Mode.signUp => (
        'Create your account',
        'We’ll email you a link to confirm the address. The same account works on listenjar.com.',
      ),
      _Mode.forgot => (
        'Set a new password',
        'We’ll email you a link that sets it, or sets a first one if you’ve signed in only with Google or a passkey.',
      ),
    };
    return _layout(text, title, lede, AutofillGroup(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (problem != null) ...[
          _Alert(problem),
          const SizedBox(height: 16),
        ],
        if (_mode == _Mode.signIn) ...[
          _LastUsed(
            shown: last == SignInMethod.google,
            child: TextButton.icon(
              style: brand.button(brand.Tone.ink),
              onPressed: _busy ? null : () => unawaited(_google()),
              icon: const GoogleMark(),
              label: const Text('Continue with Google'),
            ),
          ),
          if (_passkeys) ...[
            const SizedBox(height: 10),
            _LastUsed(
              shown: last == SignInMethod.passkey,
              child: TextButton.icon(
                style: brand.button(brand.Tone.quiet),
                onPressed: _busy ? null : () => unawaited(_account.signInWithPasskey()),
                icon: const KeyMark(),
                label: Text(passkeyBusy ? 'Waiting for your passkey…' : 'Sign in with a passkey'),
              ),
            ),
          ],
          const _OrDivider('or with your email'),
        ],
        _label(text, 'Email'),
        _field(
          text,
          controller: _email,
          focus: _emailFocus,
          enabled: !passwordBusy,
          invalid: _account.authError is WrongPassword,
          keyboard: TextInputType.emailAddress,
          hints: const [AutofillHints.email, AutofillHints.username],
          action: _mode == _Mode.forgot ? TextInputAction.done : TextInputAction.next,
          onSubmitted: () => _mode == _Mode.forgot ? unawaited(_submit()) : _passwordFocus.requestFocus(),
        ),
        if (_mode != _Mode.forgot) ...[
          const SizedBox(height: 14),
          _label(
            text,
            _mode == _Mode.signUp ? 'Password, at least 8 characters' : 'Password',
            aside: _mode == _Mode.signIn ? _link(text, 'Forgot password?', () => _switch(_Mode.forgot)) : null,
          ),
          _field(
            text,
            controller: _password,
            focus: _passwordFocus,
            enabled: !passwordBusy,
            invalid: _account.authError is WrongPassword,
            obscure: !_showPassword,
            hints: [_mode == _Mode.signUp ? AutofillHints.newPassword : AutofillHints.password],
            action: TextInputAction.done,
            onSubmitted: () => unawaited(_submit()),
            suffix: IconButton(
              tooltip: _showPassword ? 'Hide password' : 'Show password',
              onPressed: () => setState(() => _showPassword = !_showPassword),
              icon: GlyphIcon(_showPassword ? Glyphs.eyeOff : Glyphs.eye, size: 20, color: brand.fgSoft),
            ),
          ),
        ],
        if (_check case final check? when _mode == _Mode.signUp) ...[
          const SizedBox(height: 16),
          TurnstileView(check),
        ],
        const SizedBox(height: 20),
        _LastUsed(
          shown: _mode == _Mode.signIn && last == SignInMethod.password,
          child: brand.accentShadow(
            enabled: !_busy,
            child: TextButton(
              style: brand.button(brand.Tone.accent),
              onPressed: _busy ? null : () => unawaited(_submit()),
              child: Text(switch ((_mode, passwordBusy)) {
                (_Mode.signIn, true) => 'Signing in…',
                (_Mode.signIn, false) => 'Sign in',
                (_Mode.signUp, true) => 'Sending the link…',
                (_Mode.signUp, false) => 'Create account',
                (_Mode.forgot, true) => 'Sending the link…',
                (_Mode.forgot, false) => 'Email me a link',
              }),
            ),
          ),
        ),
        // Continue with Google and Create account both make accounts.
        if (_mode != _Mode.forgot) ...[
          const SizedBox(height: 14),
          const _TermsLine(),
        ],
        const SizedBox(height: 16),
        Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text(
            switch (_mode) {
              _Mode.signIn => 'New to Listenjar?',
              _Mode.signUp => 'Have an account?',
              _Mode.forgot => 'Remembered it?',
            },
            style: text.bodySmall!.copyWith(color: brand.fgSoft),
          ),
          _link(
            text,
            _mode == _Mode.signIn ? 'Create an account' : 'Sign in',
            () => _switch(_mode == _Mode.signIn ? _Mode.signUp : _Mode.signIn),
          ),
        ]),
      ]),
    ));
  }

  /// listenjar.com/login's words for each refusal.
  String _explain(Object error) => switch (error) {
    WrongPassword() =>
      'That email and password don’t match. If you signed up with Google, continue with Google, or reset your password.',
    TooManyPasswords() => 'Too many wrong passwords for this email. Wait 15 minutes, or reset your password.',
    GoogleRefused() => 'Google didn’t confirm your account. Try again, or pick another account.',
    AccessDenied() => 'You chose Cancel on Google’s page, so you’re not signed in.',
    UnknownPasskey() =>
      'That passkey isn’t connected to a Listenjar account; it may have been removed. '
        'Sign in another way, then add a new one on listenjar.com.',
    NoPasskey() => 'There’s no Listenjar passkey here. Sign in another way, then add one on listenjar.com.',
    PasskeysUnavailable() => 'This copy of Listenjar can’t use passkeys. Sign in another way.',
    _ => widget.describe(error),
  };

  Widget _label(TextTheme text, String label, {Widget? aside}) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(children: [
      Expanded(child: Text(label, style: text.bodySmall!.copyWith(fontWeight: FontWeight.w600, color: brand.fg))),
      ?aside,
    ]),
  );

  Widget _link(TextTheme text, String label, VoidCallback onPressed) => TextButton(
    style: TextButton.styleFrom(
      foregroundColor: brand.accent,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      minimumSize: const Size(0, 32),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      textStyle: text.bodySmall!.copyWith(fontWeight: FontWeight.w600),
      overlayColor: const Color(0x00000000),
    ),
    onPressed: _busy ? null : onPressed,
    child: Text(label),
  );

  Widget _field(
    TextTheme text, {
    required TextEditingController controller,
    required FocusNode focus,
    required bool enabled,
    required bool invalid,
    required List<String> hints,
    required TextInputAction action,
    required VoidCallback onSubmitted,
    TextInputType? keyboard,
    bool obscure = false,
    Widget? suffix,
  }) {
    OutlineInputBorder border(Color color, [double width = 1]) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: color, width: width),
    );
    return TextField(
      controller: controller,
      focusNode: focus,
      enabled: enabled,
      obscureText: obscure,
      autocorrect: false,
      enableSuggestions: !obscure && keyboard == null,
      keyboardType: keyboard,
      textInputAction: action,
      autofillHints: hints,
      onSubmitted: (_) => onSubmitted(),
      style: text.bodyMedium,
      cursorColor: brand.accent,
      decoration: InputDecoration(
        filled: true,
        fillColor: brand.paper,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        suffixIcon: suffix,
        enabledBorder: border(invalid ? brand.danger : brand.line),
        disabledBorder: border(brand.line),
        focusedBorder: border(invalid ? brand.danger : brand.accent.withValues(alpha: 0.6), 1.5),
      ),
    );
  }
}

/// Marks the way this device signed in last on its button's top edge:
/// listenjar.com's LastUsed. Merged into the button, so it is part of its
/// name: "Continue with Google, Last used".
final class _LastUsed extends StatelessWidget {
  const _LastUsed({required this.shown, required this.child});
  final bool shown;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!shown) return child;
    return MergeSemantics(
      child: Stack(clipBehavior: Clip.none, fit: StackFit.passthrough, children: [
        child,
        Positioned(
          top: -10,
          right: 12,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: brand.accent,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: brand.white, width: 3, strokeAlign: BorderSide.strokeAlignOutside),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                child: Text(
                  'Last used',
                  style: Theme.of(context).textTheme.labelSmall!.copyWith(
                    fontSize: 11,
                    height: 1,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.11,
                    color: brand.white,
                  ),
                ),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

/// What went wrong, above the buttons: listenjar.com's AuthAlert.
final class _Alert extends StatelessWidget {
  const _Alert(this.message);
  final String message;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: brand.danger.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Text(
          message,
          style: Theme.of(context).textTheme.bodySmall!.copyWith(color: const Color(0xFF9E2F28)),
        ),
      ),
    ),
  );
}

/// What making an account accepts, said by the buttons that make one, so
/// there is no box to tick: listenjar.com/signup's line. The backend stores
/// the Terms' version with the new account.
final class _TermsLine extends StatefulWidget {
  const _TermsLine();

  @override
  State<_TermsLine> createState() => _TermsLineState();
}

final class _TermsLineState extends State<_TermsLine> {
  late final _terms = TapGestureRecognizer()..onTap = () => _open('/terms');
  late final _privacy = TapGestureRecognizer()..onTap = () => _open('/privacy');

  void _open(String path) =>
    unawaited(launchUrl(currentConfig().web.resolve(path), mode: LaunchMode.externalApplication));

  @override
  void dispose() {
    _terms.dispose();
    _privacy.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall!.copyWith(fontSize: 12.5, height: 1.45, color: brand.fgSoft);
    final link = style.copyWith(
      color: brand.fg,
      fontWeight: FontWeight.w500,
      decoration: TextDecoration.underline,
      decorationColor: brand.fg.withValues(alpha: 0.3),
    );
    return Text.rich(
      TextSpan(style: style, children: [
        const TextSpan(text: 'By continuing, you agree to Listenjar’s '),
        TextSpan(text: 'Terms of Service', style: link, recognizer: _terms, mouseCursor: SystemMouseCursors.click),
        const TextSpan(text: ' and '),
        TextSpan(text: 'Privacy Policy', style: link, recognizer: _privacy, mouseCursor: SystemMouseCursors.click),
        const TextSpan(text: '.'),
      ]),
      textAlign: TextAlign.center,
    );
  }
}

/// The rule between the one-click ways in and the email form.
final class _OrDivider extends StatelessWidget {
  const _OrDivider(this.label);
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 20),
    child: Row(children: [
      const Expanded(child: Divider(color: brand.line, height: 1)),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Text(
          label,
          style: Theme.of(context).textTheme.bodySmall!.copyWith(fontSize: 13, fontWeight: FontWeight.w500, color: brand.fgSoft),
        ),
      ),
      const Expanded(child: Divider(color: brand.line, height: 1)),
    ]),
  );
}
