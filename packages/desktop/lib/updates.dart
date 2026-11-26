// In-app updates: Sparkle on macOS (macos/Runner/AppDelegate.swift) and
// WinSparkle on Windows (windows/runner/updates.h), over `listenjar/updates`,
// and apk_updates.dart on Android. Each checks listenjar/app's latest
// GitHub release once a day and installs only what is signed with the key
// release builds carry (tool/release.ts; on Android, the APK's own signing
// key); debug and local builds have no key, so no updater. Linux and iOS
// update elsewhere.
import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import 'apk_updates.dart';
import 'log.dart';
import 'plans.dart' show formatBytes;
import 'theme.dart' as brand;

/// What the updater says. [automaticDownloads] is macOS only: WinSparkle
/// and Android always ask before they download. [status] is Android's: what
/// its update is doing, or how it went.
typedef UpdateState = ({String version, bool available, bool canCheck, bool automatic, bool? automaticDownloads, String? status});

/// Whether this platform updates from inside the app at all.
final bool updatesSupported = Platform.isMacOS || Platform.isWindows || Platform.isAndroid;

/// Null until the native side answers, and on platforms without updates.
final updates = ValueNotifier<UpdateState?>(null);

const _channel = MethodChannel('listenjar/updates');
final _log = Logger('updates');

/// Reads the updater's state and follows its changes: Sparkle's own window
/// can turn automatic installs on.
Future<void> startUpdates() async {
  if (!updatesSupported) return;
  if (Platform.isAndroid) {
    void follow() => updates.value = switch (apkUpdates.value) {
      null => null,
      final a => (version: a.version, available: a.available, canCheck: true, automatic: a.automatic, automaticDownloads: null, status: a.status),
    };
    apkUpdates.addListener(follow);
    return startApkUpdates();
  }
  _channel.setMethodCallHandler((call) async {
    if (call.method == 'changed') updates.value = _parse(call.arguments);
  });
  updates.value = _parse(await _channel.invokeMethod<Object?>('state'));
  _log.info('${updates.value}');
}

/// Checks now; the native updater shows what it finds in its own window,
/// Android in [UpdatePrompt]. While Android downloads one, stops it.
Future<void> checkForUpdates() => Platform.isAndroid ? checkApkUpdate() : _channel.invokeMethod<void>('check');

Future<void> setAutomaticUpdates(bool enabled) async {
  if (Platform.isAndroid) return setApkAutomatic(enabled);
  updates.value = _parse(await _channel.invokeMethod<Object?>('setAutomatic', enabled));
}

Future<void> setAutomaticDownloads(bool enabled) async =>
  updates.value = _parse(await _channel.invokeMethod<Object?>('setAutomaticDownloads', enabled));

/// For `ext.listenjar.state` (main.dart).
Map<String, Object?>? updatesState() => switch (updates.value) {
  null => null,
  final u => {
    'version': u.version,
    'available': u.available,
    'canCheck': u.canCheck,
    'automatic': u.automatic,
    'automaticDownloads': u.automaticDownloads,
    if (u.status != null) 'status': u.status,
    if (Platform.isAndroid) 'android': apkUpdatesState(),
  },
};

UpdateState _parse(Object? arguments) {
  final map = arguments is Map ? arguments : const {};
  return (
    version: map['version'] as String? ?? '',
    available: map['available'] == true,
    canCheck: map['canCheck'] == true,
    automatic: map['automatic'] == true,
    automaticDownloads: map['automaticDownloads'] as bool?,
    status: null,
  );
}

/// Asks about each newer Android release apk_updates.dart finds, as
/// Sparkle's window does: install it, not now, or skip this version.
final class UpdatePrompt extends StatefulWidget {
  const UpdatePrompt({super.key, required this.child});
  final Widget child;

  @override
  State<UpdatePrompt> createState() => _UpdatePromptState();
}

class _UpdatePromptState extends State<UpdatePrompt> {
  bool _asking = false;

  @override
  void initState() {
    super.initState();
    apkOffer.addListener(_offered);
    WidgetsBinding.instance.addPostFrameCallback((_) => _offered());
  }

  @override
  void dispose() {
    apkOffer.removeListener(_offered);
    super.dispose();
  }

  Future<void> _offered() async {
    final release = apkOffer.value;
    if (release == null || _asking || !mounted) return;
    _asking = true;
    apkOffer.value = null;
    try {
      final answer = await showDialog<_Answer>(context: context, builder: (context) => _ask(context, release));
      switch (answer) {
        case _Answer.update:
          unawaited(installApkUpdate(release));
        case _Answer.skip:
          await skipApkUpdate(release);
        case _Answer.later || null:
      }
    } finally {
      _asking = false;
    }
  }

  Widget _ask(BuildContext context, ApkRelease release) {
    final text = Theme.of(context).textTheme;
    final current = updates.value?.version ?? '';
    Widget answer(_Answer answer, brand.Tone tone, String label) => TextButton(
      style: brand.button(tone),
      onPressed: () => Navigator.pop(context, answer),
      child: Text(label),
    );
    return AlertDialog(
      backgroundColor: brand.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(brand.radiusSheet)),
      title: Text('ListenJar ${release.version} is out', style: text.titleLarge),
      content: Text(
        '${current.isEmpty ? '' : 'You have $current. '}'
        'It downloads here (${formatBytes(release.length)}), then Android asks you to install it. '
        'Playback stops while it installs.',
        style: text.bodyMedium!.copyWith(color: brand.fgSoft),
      ),
      // A phone's width: one full-width button each, the update first.
      actions: [
        Column(crossAxisAlignment: CrossAxisAlignment.stretch, spacing: 8, children: [
          brand.accentShadow(enabled: true, child: answer(_Answer.update, brand.Tone.accent, 'Update')),
          answer(_Answer.later, brand.Tone.quiet, 'Not now'),
          answer(_Answer.skip, brand.Tone.quiet, 'Skip this version'),
        ]),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

enum _Answer { update, later, skip }
