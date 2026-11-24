// When the feeds sync and the podcasts refresh on their own: about once an
// hour, with or without a window, on every platform. Each platform only supplies the clock that
// runs the one job, [runSyncJob]:
//
// - macOS, Windows: the process outlives its window (tray.dart), so an
//   hourly timer in it is enough.
// - Android: the OS stops apps it doesn't show, so WorkManager keeps the
//   schedule, across reboots too, and starts the process just for the job
//   when it isn't running, on an engine and isolate of its own (dataSync
//   foreground service, its notification saying so, which may outlast a
//   plain job's ten minutes for a long video).
//
// - iOS: the OS suspends the app; it refreshes when opened and on resume
//   (shell.dart), and while it plays, the hourly timer runs.
//
// The job never assumes which: it syncs the app's Feeds and refreshes its
// Podcasts when this isolate has them, hands off to the isolate that does
// when another has them, and otherwise opens the kept account and the
// library cold, syncs and refreshes, and closes them again.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

import 'package:workmanager/workmanager.dart';

import 'account.dart';
import 'backend/api.dart' show Plan;
import 'downloads.dart';
import 'feeds.dart';
import 'library.dart';
import 'podcasts.dart';
import 'youtube.dart';

const _every = Duration(hours: 1);

/// Where the app's Feeds take sync jobs from other isolates of the process.
const _portName = 'listenjar.sync';

/// How long a handed-off job waits for an answer before taking the app's
/// isolate for gone (it ended without unregistering).
const _answer = Duration(seconds: 10);

/// This isolate's app Feeds and Podcasts, once a schedule started with them.
(Feeds, Podcasts)? _app;

abstract interface class SyncSchedule {
  /// This platform's clock.
  factory SyncSchedule() => Platform.isAndroid ? _WorkManagerSchedule() : _TimerSchedule();

  /// Sends this process's sync jobs to [feeds], and has [runSyncJob] run
  /// about every hour from now on, for as long as the platform keeps the
  /// schedule: the process's life on desktop, until the app is uninstalled
  /// on Android. Safe to call on every launch.
  Future<void> start(Feeds feeds, Podcasts podcasts);
}

/// The one thing every platform's clock runs: a sync pass over the feeds,
/// wherever this process keeps them.
Future<void> runSyncJob() async {
  if (_app case (final feeds, final podcasts)?) {
    await Future.wait([feeds.sync(), podcasts.refreshAll(force: true)]);
    return;
  }
  if (IsolateNameServer.lookupPortByName(_portName) case final app?) {
    if (await _handOff(app)) return;
    IsolateNameServer.removePortNameMapping(_portName);
  }
  // Android started the process for this job.
  final youtube = YouTubeService();
  final account = Account();
  final feeds = Feeds(account, youtube);
  final library = await Library.open();
  final downloads = Downloads(library, youtube);
  final podcasts = Podcasts(library, downloads, youtube)..paid = () => account.restoring ? null : account.user?.plan == Plan.paid;
  try {
    await downloads.start();
    await account.restore();
    await Future.wait([feeds.sync(), podcasts.refreshAll(force: true)]);
  } finally {
    podcasts.dispose();
    await downloads.close();
    library.dispose();
    feeds.dispose();
    account.dispose();
    await youtube.close();
  }
}

/// Takes jobs from other isolates of this process into [feeds] and
/// [podcasts].
void _serve(Feeds feeds, Podcasts podcasts) {
  if (_app != null) return;
  _app = (feeds, podcasts);
  final port = ReceivePort('sync jobs');
  IsolateNameServer.removePortNameMapping(_portName);
  IsolateNameServer.registerPortWithName(port.sendPort, _portName);
  port.listen((reply) async {
    final to = reply as SendPort;
    to.send(true);
    try {
      await Future.wait([feeds.sync(), podcasts.refreshAll(force: true)]);
    } finally {
      to.send(false);
    }
  });
}

/// Has the isolate behind [app] run the job; false if it doesn't answer.
Future<bool> _handOff(SendPort app) async {
  final reply = ReceivePort();
  final answers = StreamIterator(reply);
  try {
    app.send(reply.sendPort);
    if (!await answers.moveNext().timeout(_answer, onTimeout: () => false)) return false;
    while (await answers.moveNext()) {
      if (answers.current == false) break;
    }
    return true;
  } finally {
    reply.close();
  }
}

final class _TimerSchedule implements SyncSchedule {
  Timer? _timer;

  @override
  Future<void> start(Feeds feeds, Podcasts podcasts) async {
    _serve(feeds, podcasts);
    _timer ??= Timer.periodic(_every, (_) => unawaited(runSyncJob().catchError((_) {})));
  }
}

final class _WorkManagerSchedule implements SyncSchedule {
  static const _task = 'sync';

  @override
  Future<void> start(Feeds feeds, Podcasts podcasts) async {
    _serve(feeds, podcasts);
    await Workmanager().initialize(_runScheduled);
    await Workmanager().registerPeriodicTask(
      _task,
      _task,
      frequency: _every,
      constraints: Constraints(networkType: NetworkType.connected),
      // Launches don't push the next run back.
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
      foregroundServiceConfig: ForegroundServiceConfig(
        notificationTitle: 'ListenJar',
        notificationText: 'Syncing your podcasts',
        notificationChannelId: 'sync',
        notificationChannelName: 'Syncing',
      ),
    );
  }
}

/// Where WorkManager enters Dart, in a fresh engine, possibly in a process
/// it just started.
@pragma('vm:entry-point')
void _runScheduled() {
  Workmanager().executeTask((task, _) async {
    if (task != _WorkManagerSchedule._task) return true;
    try {
      await runSyncJob();
      return true;
    } catch (_) {
      // WorkManager tries again with backoff.
      return false;
    }
  });
}
