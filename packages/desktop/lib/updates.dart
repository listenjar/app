// In-app updates: Sparkle on macOS (macos/Runner/AppDelegate.swift) and
// WinSparkle on Windows (windows/runner/updates.h), over `listenjar/updates`.
// Each checks listenjar/desktop's latest GitHub release once a day and
// installs only what is signed with the key release builds carry
// (tool/release.ts); debug and local builds have no key, so no updater.
// Linux, Android and iOS update through their stores.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'log.dart';

/// What the native updater says. [automaticDownloads] is macOS only:
/// WinSparkle always asks before it downloads.
typedef UpdateState = ({String version, bool available, bool canCheck, bool automatic, bool? automaticDownloads});

/// Whether this platform updates from inside the app at all.
final bool updatesSupported = Platform.isMacOS || Platform.isWindows;

/// Null until the native side answers, and on platforms without updates.
final updates = ValueNotifier<UpdateState?>(null);

const _channel = MethodChannel('listenjar/updates');
final _log = Logger('updates');

/// Reads the updater's state and follows its changes: Sparkle's own window
/// can turn automatic installs on.
Future<void> startUpdates() async {
  if (!updatesSupported) return;
  _channel.setMethodCallHandler((call) async {
    if (call.method == 'changed') updates.value = _parse(call.arguments);
  });
  updates.value = _parse(await _channel.invokeMethod<Object?>('state'));
  _log.info('${updates.value}');
}

/// Checks now; the native updater shows what it finds in its own window.
Future<void> checkForUpdates() => _channel.invokeMethod<void>('check');

Future<void> setAutomaticUpdates(bool enabled) async =>
  updates.value = _parse(await _channel.invokeMethod<Object?>('setAutomatic', enabled));

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
  );
}
