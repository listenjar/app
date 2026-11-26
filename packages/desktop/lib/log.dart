// What the app is doing, for whoever debugs it.
//
// Each area logs through a Logger of its own (`Logger('youtube')`). Every
// record goes to DevTools' Logging view; outside release builds, records of
// level FINE and up also go to the console that `flutter run` prints. A
// release build keeps warnings and up. HTTP requests are logged by their
// callers (`youtube.http`), not through DevTools' Network view: dart:io's
// HTTP profiler keeps each response body as a List<int>, 8 bytes per byte,
// so streaming and downloading media grew the heap by gigabytes.
//
// [traced] times async work. The work shows as a task in DevTools'
// Performance view, and work still waiting after a while says so in the
// log, so a hang names itself.
//
// Outside release, tools that speak the VM service (the Dart MCP server's
// `vm_service callMethod`, DevTools) can ask the running app directly:
//   ext.listenjar.log      recent records; `since` a sequence number,
//                          `level` (default FINE), `logger` a name prefix
//   ext.listenjar.running  traced work not finished yet, oldest first
//   ext.listenjar.state    what the app is doing (main.dart's appState)
//   ext.listenjar.control  drives the app: `action` play (`episode` an
//                          id), pause, stop, seek (`seconds`), refresh,
//                          drag (a pointer `kind` touch, mouse or
//                          trackpad from `x`,`y` by `dx`,`dy` over `ms`),
//                          add (a YouTube `url` `into` a podcast of the
//                          listener's own: a Cloud feed id or
//                          `local:<show>`; the first in the Cloud if
//                          not given), create (a podcast of their own
//                          called `title`, in the Cloud if `cloud` is
//                          true, else on this device), rss (a podcast's
//                          feed `url`), video (a YouTube video `url`,
//                          looked up and played as Search does), follow (a YouTube
//                          playlist or channel `url`, on this device),
//                          unfollow (`show`), move (a `show` on this
//                          device to the Cloud, or a Cloud `feed` here),
//                          open (a `feed` or `show`
//                          id, `settings`, `nowPlaying`, `plans`,
//                          `newPodcast` or `search` a query, of
//                          YouTube if `youtube` is true), download
//                          (`episode`) or key (`key` up, down, left,
//                          right, space, enter, escape or tab, to
//                          whatever has focus)
//   ext.listenjar.screenshot  the window as it's drawn now, a PNG at
//                          `path` (default one in the app's temp
//                          directory, which a sandbox allows), at `scale`
//                          times its logical size (default the screen's);
//                          answers where it wrote it
// SEVERE records and uncaught errors are reported as Flutter errors, so
// they show where runtime errors show (the MCP's `get_runtime_errors`).
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:ui' as ui;

import 'package:cancellation_token/cancellation_token.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:logging/logging.dart';

export 'package:logging/logging.dart' show Level, Logger;

/// The last records, for `ext.listenjar.log`.
final _recent = Queue<LogRecord>();
const _keep = 1000;

/// Traced work not finished yet, by when it started.
final _running = <int, (Logger, String, Stopwatch)>{};
var _runs = 0;

/// Called once, first thing in main(). [state] answers
/// `ext.listenjar.state`; [control] takes `ext.listenjar.control`'s
/// parameters, which then answers with [state].
void startLogging({required Map<String, Object?> Function() state, required void Function(Map<String, String>) control}) {
  Logger.root.level = kReleaseMode ? Level.WARNING : Level.ALL;
  Logger.root.onRecord.listen(_write);
  if (kReleaseMode) return;
  // Uncaught errors from futures and streams, which otherwise only print.
  PlatformDispatcher.instance.onError = (error, stack) {
    FlutterError.reportError(FlutterErrorDetails(exception: error, stack: stack, library: 'an uncaught async error'));
    return true;
  };
  _extension('log', _logExtension);
  _extension('running', (_) => {
    'running': [
      for (final (log, what, watch) in _running.values) {'logger': log.fullName, 'what': what, 'for': _took(watch)},
    ],
  });
  _extension('state', (_) => state());
  _extension('control', (parameters) {
    control(parameters);
    return state();
  });
  developer.registerExtension('ext.listenjar.screenshot', (method, parameters) async {
    try {
      return developer.ServiceExtensionResponse.result(jsonEncode(await _screenshot(parameters)));
    } catch (e, stack) {
      return developer.ServiceExtensionResponse.error(developer.ServiceExtensionResponse.extensionError, '$e\n$stack');
    }
  });
}

/// The first window's picture, as `ext.listenjar.screenshot` writes it.
Future<Map<String, Object?>> _screenshot(Map<String, String> parameters) async {
  final path = parameters['path'] ?? '${Directory.systemTemp.path}/listenjar-screenshot.png';
  // A window behind others gets no frames, so its animations stand still:
  // draw it for a moment, letting them settle.
  final settle = Stopwatch()..start();
  while (settle.elapsedMilliseconds < 600) {
    SchedulerBinding.instance.scheduleForcedFrame();
    await SchedulerBinding.instance.endOfFrame.timeout(const Duration(seconds: 1), onTimeout: () {});
    await Future<void>.delayed(const Duration(milliseconds: 16));
  }
  final view = RendererBinding.instance.renderViews.first;
  final layer = view.debugLayer! as OffsetLayer;
  // The root layer already scales logical pixels to the screen's.
  final ratio = view.flutterView.devicePixelRatio;
  final scale = double.tryParse(parameters['scale'] ?? '') ?? ratio;
  final image = await layer.toImage(Offset.zero & view.size * ratio, pixelRatio: scale / ratio);
  try {
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    await File(path).writeAsBytes(png!.buffer.asUint8List());
    return {'path': path, 'width': image.width, 'height': image.height};
  } finally {
    image.dispose();
  }
}

void _extension(String name, Map<String, Object?> Function(Map<String, String> parameters) answer) {
  developer.registerExtension('ext.listenjar.$name', (method, parameters) async {
    try {
      return developer.ServiceExtensionResponse.result(jsonEncode(answer(parameters), toEncodable: (o) => '$o'));
    } catch (e, stack) {
      return developer.ServiceExtensionResponse.error(developer.ServiceExtensionResponse.extensionError, '$e\n$stack');
    }
  });
}

Map<String, Object?> _logExtension(Map<String, String> parameters) {
  final since = int.tryParse(parameters['since'] ?? '') ?? -1;
  final name = parameters['level']?.toUpperCase() ?? 'FINE';
  final level = Level.LEVELS.firstWhere((l) => l.name == name, orElse: () => Level.FINE);
  final prefix = parameters['logger'] ?? '';
  return {
    'last': _recent.isEmpty ? since : _recent.last.sequenceNumber,
    'records': [
      for (final r in _recent)
        if (r.sequenceNumber > since && r.level >= level && r.loggerName.startsWith(prefix))
          {
            'seq': r.sequenceNumber,
            'time': r.time.toIso8601String(),
            'level': r.level.name,
            'logger': r.loggerName,
            'message': r.message,
            if (r.error != null) 'error': '${r.error}',
          },
    ],
  };
}

void _write(LogRecord r) {
  _recent.add(r);
  if (_recent.length > _keep) _recent.removeFirst();
  developer.log(
    r.message,
    time: r.time,
    sequenceNumber: r.sequenceNumber,
    level: r.level.value,
    name: r.loggerName,
    error: r.error,
    stackTrace: r.stackTrace,
  );
  if (kReleaseMode || r.level < Level.FINE) return;
  if (r.level >= Level.SEVERE) {
    // Printed by Flutter's error reporting, and seen by error tools.
    FlutterError.reportError(FlutterErrorDetails(
      exception: r.error ?? r.message,
      stack: r.stackTrace,
      library: r.loggerName,
      context: r.error == null ? null : ErrorDescription(r.message),
    ));
    return;
  }
  final time = r.time.toIso8601String().substring(11, 23);
  final error = r.error == null ? '' : ': ${r.error}';
  debugPrint('$time ${r.level.name.padRight(7)} ${r.loggerName}  ${r.message}$error');
}

/// Runs [body] as [what] on [log]: how long it took and how it ended, with
/// [describe] saying what it returned. It warns every [slowAfter] while it
/// waits.
Future<T> traced<T>(
  Logger log,
  String what,
  Future<T> Function() body, {
  String Function(T result)? describe,
  Duration slowAfter = const Duration(seconds: 10),
}) async {
  final task = developer.TimelineTask(filterKey: log.fullName)..start(what);
  final watch = Stopwatch()..start();
  final run = _runs++;
  _running[run] = (log, what, watch);
  log.finest('$what…');
  final slow = Timer.periodic(slowAfter, (_) => log.warning('$what: still waiting after ${_took(watch)}'));
  try {
    final result = await body();
    final said = describe == null ? '' : ' → ${describe(result)}';
    log.fine('$what in ${_took(watch)}$said');
    return result;
  } on CancelledException {
    log.fine('$what cancelled after ${_took(watch)}');
    rethrow;
  } catch (e, stack) {
    log.warning('$what failed after ${_took(watch)}', e, stack);
    rethrow;
  } finally {
    slow.cancel();
    _running.remove(run);
    task.finish();
  }
}

String _took(Stopwatch watch) {
  final ms = watch.elapsedMilliseconds;
  return ms < 1000 ? '${ms}ms' : '${(ms / 1000).toStringAsFixed(1)}s';
}
