// When the feeds sync on their own: about once an hour, with or without a
// window, on every platform. Each platform only supplies the clock that
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
// The job never assumes which: it syncs the app's Feeds when this isolate
// has them, hands off to the isolate that does when another has them, and
// otherwise opens the kept account cold, syncs, and closes it again.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

import 'package:workmanager/workmanager.dart';

import 'account.dart';
import 'feeds.dart';
import 'youtube.dart';

const _every = Duration(hours: 1);

/// Where the app's Feeds take sync jobs from other isolates of the process.
const _portName = 'listenjar.sync';

/// How long a handed-off job waits for an answer before taking the app's
/// isolate for gone (it ended without unregistering).
const _answer = Duration(seconds: 10);

/// This isolate's app Feeds, once a schedule started with them.
Feeds? _app;

abstract interface class SyncSchedule {
  /// This platform's clock.
  factory SyncSchedule() => Platform.isAndroid ? _WorkManagerSchedule() : _TimerSchedule();

  /// Sends this process's sync jobs to [feeds], and has [runSyncJob] run
  /// about every hour from now on, for as long as the platform keeps the
  /// schedule: the process's life on desktop, until the app is uninstalled
  /// on Android. Safe to call on every launch.
  Future<void> start(Feeds feeds);
}

/// The one thing every platform's clock runs: a sync pass over the feeds,
/// wherever this process keeps them.
Future<void> runSyncJob() async {
  if (_app case final feeds?) return feeds.sync();
  if (IsolateNameServer.lookupPortByName(_portName) case final app?) {
    if (await _handOff(app)) return;
    IsolateNameServer.removePortNameMapping(_portName);
  }
  // Android started the process for this job.
  final youtube = YouTubeService();
  final account = Account();
  final feeds = Feeds(account, youtube);
  try {
    await account.restore();
    await feeds.sync();
  } finally {
    feeds.dispose();
    account.dispose();
    await youtube.close();
  }
}

/// Takes jobs from other isolates of this process into [feeds].
void _serve(Feeds feeds) {
  if (_app != null) return;
  _app = feeds;
  final port = ReceivePort('sync jobs');
  IsolateNameServer.removePortNameMapping(_portName);
  IsolateNameServer.registerPortWithName(port.sendPort, _portName);
  port.listen((reply) async {
    final to = reply as SendPort;
    to.send(true);
    try {
      await feeds.sync();
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
  Future<void> start(Feeds feeds) async {
    _serve(feeds);
    _timer ??= Timer.periodic(_every, (_) => unawaited(runSyncJob().catchError((_) {})));
  }
}

final class _WorkManagerSchedule implements SyncSchedule {
  static const _task = 'sync';

  @override
  Future<void> start(Feeds feeds) async {
    _serve(feeds);
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
