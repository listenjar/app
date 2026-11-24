// Episodes kept on the device to play offline, in `episodes/` under the app's
// support directory. A feed's audio downloads through background_downloader,
// which goes on while the app is in the background (URLSession on iOS,
// WorkManager on Android) and resumes after a restart. A YouTube video's
// audio downloads in the app, in the 1 MiB ranges YouTube's media servers
// expect (transfer.dart, the sync's own downloader), and resumes the same
// way. The library (library.dart) keeps each episode's state; this file only
// moves bytes, and deletes them again when the listener's storage rules say
// so ([tidyDownloads]). No widgets here.
import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:cancellation_token/cancellation_token.dart';

import 'faststart.dart';
import 'library.dart';
import 'log.dart';
import 'rss.dart' show userAgent;
import 'transfer.dart' as transfer;
import 'youtube.dart';

final _log = Logger('downloads');
final _storageLog = Logger('storage');

/// How often the storage rules run while the app is open, besides after
/// each change they depend on.
const _tidyEvery = Duration(hours: 1);

const _group = 'episodes';
const _folder = 'episodes';

final class Downloads {
  Downloads(this._library, this._youtube);

  final Library _library;
  final YouTubeService _youtube;
  final _http = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  final _life = CancellationToken();

  /// YouTube downloads in flight, by episode.
  final _youtubeRunning = <int, CancellationToken>{};
  transfer.Journal? _journal;
  StreamSubscription<TaskUpdate>? _updates;
  Timer? _tidyTimer;

  /// Library writes for progress, at most this often per episode.
  final _lastProgress = <int, DateTime>{};

  bool get _mobile => Platform.isAndroid || Platform.isIOS;

  /// Picks up downloads the system finished or the app left running.
  Future<void> start() async {
    _updates = FileDownloader().updates.listen(_update);
    await FileDownloader().start(autoCleanDatabase: true);
    for (final episode in _library.unfinishedDownloads()) {
      if (episode.youtubeId != null) unawaited(_youtubeDownload(episode));
    }
    _tidyTimer ??= Timer.periodic(_tidyEvery, (_) => unawaited(tidyDownloads(_library, this)));
    await tidyDownloads(_library, this);
  }

  /// Downloads [episode]; [automatic] ones wait for Wi-Fi on a phone when
  /// the listener asked.
  Future<void> download(PodcastEpisode episode, {bool automatic = false}) async {
    if (episode.downloaded || episode.downloadState == DownloadState.downloading) return;
    _library.setDownload(episode.id, DownloadState.queued, progress: 0);
    if (episode.youtubeId != null) {
      unawaited(_youtubeDownload(episode));
      return;
    }
    final url = episode.audioUrl;
    if (url == null) return;
    final task = DownloadTask(
      taskId: _taskId(episode.id),
      url: url,
      filename: '${episode.id}${_extension(url, episode.audioType)}',
      directory: _folder,
      baseDirectory: BaseDirectory.applicationSupport,
      group: _group,
      headers: const {'User-Agent': userAgent},
      updates: Updates.statusAndProgress,
      requiresWiFi: automatic && _mobile && _library.settings.wifiOnly,
      retries: 3,
      allowPause: true,
      displayName: episode.title,
      metaData: '${episode.id}',
    );
    if (!await FileDownloader().enqueue(task)) {
      _library.setDownload(episode.id, DownloadState.failed, error: 'Couldn’t start the download');
    }
  }

  /// New episodes of shows set to download them.
  Future<void> downloadNew(Iterable<PodcastEpisode> episodes) async {
    for (final e in episodes) {
      final show = _library.podcast(e.podcastId);
      if (show == null || !show.followed) continue;
      if (_library.settings.autoDownload || show.autoDownload) await download(e, automatic: true);
    }
  }

  /// Stops [episode]'s download, if running, and deletes what it saved.
  Future<void> delete(PodcastEpisode episode) async {
    _youtubeRunning.remove(episode.id)?.cancel();
    await FileDownloader().cancelTaskWithId(_taskId(episode.id));
    final file = _library.downloadFile(episode);
    if (file != null && await file.exists()) await file.delete();
    final journal = _journal;
    if (journal != null) await journal.forget(_youtubeKey(episode.id));
    _library.setDownload(episode.id, DownloadState.none);
  }

  /// Deletes files left behind by a show the listener stopped following.
  Future<void> deleteFiles(Iterable<String> relativePaths) async {
    for (final path in relativePaths) {
      final file = File('${_library.directory.path}/$path');
      if (await file.exists()) await file.delete();
    }
  }

  String _taskId(int episode) => 'episode-$episode';

  String _extension(String url, String? type) {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    final dot = path.lastIndexOf('.');
    if (dot != -1 && path.length - dot <= 5) return path.substring(dot);
    return switch (type) {
      'audio/mp4' || 'audio/x-m4a' || 'audio/m4a' || 'audio/aac' => '.m4a',
      'audio/ogg' || 'audio/opus' => '.ogg',
      'video/mp4' => '.mp4',
      _ => '.mp3',
    };
  }

  void _update(TaskUpdate update) {
    final id = int.tryParse(update.task.metaData);
    if (id == null) return;
    switch (update) {
      case TaskStatusUpdate(:final status, :final exception):
        switch (status) {
          case TaskStatus.enqueued || TaskStatus.waitingToRetry || TaskStatus.paused:
            _library.setDownload(id, DownloadState.queued);
          case TaskStatus.running:
            _library.setDownload(id, DownloadState.downloading);
          case TaskStatus.complete:
            _library.setDownload(id, DownloadState.done, path: '$_folder/${update.task.filename}', progress: 1);
            unawaited(tidyDownloads(_library, this));
          case TaskStatus.notFound:
            _library.setDownload(id, DownloadState.failed, error: 'The episode’s audio is gone (HTTP 404)');
          case TaskStatus.failed:
            _library.setDownload(id, DownloadState.failed, error: exception?.description ?? 'The download failed');
          case TaskStatus.canceled:
            _library.setDownload(id, DownloadState.none);
        }
      case TaskProgressUpdate(:final progress) when progress >= 0:
        _progress(id, progress);
      case TaskProgressUpdate():
        break;
    }
  }

  /// Saves progress quietly, and shows it a few times a second at most.
  void _progress(int episode, double progress) {
    final now = DateTime.now();
    final last = _lastProgress[episode];
    final show = last == null || now.difference(last) > const Duration(milliseconds: 400);
    if (show) _lastProgress[episode] = now;
    _library.setDownload(episode, DownloadState.downloading, progress: progress, notify: show);
  }

  String _youtubeKey(int episode) => 'episode-$episode';

  Future<transfer.Journal> _openJournal() async => _journal ??= transfer.Journal.open(Directory('${_library.directory.path}/offline'));

  Future<void> _youtubeDownload(PodcastEpisode episode) async {
    final id = episode.youtubeId;
    if (id == null || _youtubeRunning.containsKey(episode.id)) return;
    final token = CancellationToken();
    _youtubeRunning[episode.id] = token;
    final merged = _life.merge(token);
    try {
      final journal = await _openJournal();
      final session = await _youtube.session(merged);
      final (media, reason) = await session.media(id, channel: false, token: merged);
      if (media == null) throw StateError(reason ?? 'YouTube won’t give this video’s audio');
      _library.setDownload(episode.id, DownloadState.downloading);
      final key = _youtubeKey(episode.id);
      File part;
      while (true) {
        try {
          part = await transfer.download(
            _http,
            journal,
            key,
            media.audio,
            (done, total) => _progress(episode.id, total == 0 ? 0 : done / total),
            merged,
          );
          break;
        } on MediaUnavailable {
          if (!await session.fallback(media, merged)) rethrow;
        }
      }
      final name = '${episode.id}${media.contentType == 'audio/webm' ? '.webm' : '.m4a'}';
      await Directory('${_library.directory.path}/$_folder').create(recursive: true);
      // A regular M4A rather than YouTube's fragments, which AVPlayer plays
      // at twice the length, the second half silent (faststart.dart).
      final rewritten = media.contentType == 'audio/mp4' ? await faststart(part, merged) : null;
      await (rewritten ?? part).rename('${_library.directory.path}/$_folder/$name');
      await journal.forget(key);
      _library.setDownload(episode.id, DownloadState.done, path: '$_folder/$name', progress: 1);
      unawaited(tidyDownloads(_library, this));
    } on CancelledException {
      // Deleted, or the app is closing; a restart resumes the latter.
    } catch (e, stack) {
      _log.warning('YouTube download of ${episode.id} failed', e, stack);
      _library.setDownload(episode.id, DownloadState.failed, error: '$e');
    } finally {
      _youtubeRunning.remove(episode.id);
    }
  }

  Future<void> close() async {
    _tidyTimer?.cancel();
    _life.cancel();
    await _updates?.cancel();
    _journal?.close();
    _http.close(force: true);
  }
}

/// The bytes [download]'s file takes; zero when it's gone.
Future<int> _downloadBytes(Library library, PodcastEpisode download) async {
  final file = library.downloadFile(download);
  if (file == null) return 0;
  try {
    return await file.length();
  } on FileSystemException {
    return 0;
  }
}

/// A pass of [tidyDownloads] running, and whether another was asked for
/// meanwhile.
Future<void>? _tidying;
var _tidyAgain = false;

/// Applies the listener's storage rules (Settings, Storage) to finished
/// downloads, in order: played episodes past [PlayerSettings.removePlayedAfter],
/// downloads unused for [PlayerSettings.removeUnplayedAfter], then the
/// longest unused until the rest fit [PlayerSettings.storageLimit]. The
/// episode playing and Up Next stay, and running downloads aren't touched.
/// Calls while a pass runs fold into one more pass after it.
Future<void> tidyDownloads(Library library, Downloads downloads) async {
  if (_tidying case final running?) {
    _tidyAgain = true;
    return running;
  }
  final pass = () async {
    do {
      _tidyAgain = false;
      try {
        await _tidy(library, downloads);
      } catch (e, stack) {
        _storageLog.warning('Tidying downloads failed', e, stack);
      }
    } while (_tidyAgain);
  }();
  _tidying = pass;
  try {
    await pass;
  } finally {
    _tidying = null;
  }
}

Future<void> _tidy(Library library, Downloads downloads) async {
  final settings = library.settings;
  final now = DateTime.now();
  final playing = library.nowPlaying;
  final queued = {for (final e in library.queue) e.id};
  final stored = library.storedDownloads();
  // The episode playing stays until it's played through; Up Next holds only
  // unplayed ones.
  bool kept(StoredDownload d) => queued.contains(d.episode.id) || (d.episode.id == playing && !d.episode.played);
  final gone = <int>{};
  Future<void> remove(StoredDownload d, String why) async {
    _storageLog.info('Deleting “${d.episode.title}” (${d.episode.from}): $why');
    gone.add(d.episode.id);
    await downloads.delete(d.episode);
  }

  for (final d in stored) {
    if (kept(d)) continue;
    final played = settings.removePlayedAfter;
    final unused = settings.removeUnplayedAfter;
    if (played != null && d.episode.played && !(d.playedAt ?? d.lastUsed).isAfter(now.subtract(played))) {
      await remove(d, played == Duration.zero ? 'played' : 'played over ${_period(played)} ago');
    } else if (unused != null && !d.lastUsed.isAfter(now.subtract(unused))) {
      await remove(d, 'unplayed for ${_period(unused)}');
    }
  }

  final limit = settings.storageLimit;
  if (limit == null) return;
  final left = [for (final d in stored) if (!gone.contains(d.episode.id)) d];
  final sizes = [for (final d in left) await _downloadBytes(library, d.episode)];
  var total = sizes.fold(0, (a, b) => a + b);
  for (final (i, d) in left.indexed) {
    if (total <= limit) break;
    if (kept(d)) continue;
    await remove(d, 'downloads were over the ${_gigabytes(limit)} limit');
    total -= sizes[i];
  }
  if (total > limit) _storageLog.info('Downloads still over the ${_gigabytes(limit)} limit: the rest are playing or in Up Next');
}

String _period(Duration d) => switch (d.inDays) {
  0 => '${d.inHours} hours',
  1 => 'a day',
  final days when days % 30 == 0 => '${days ~/ 30} ${days == 30 ? 'month' : 'months'}',
  final days when days % 7 == 0 => '${days ~/ 7} ${days == 7 ? 'week' : 'weeks'}',
  final days => '$days days',
};

String _gigabytes(int bytes) => '${(bytes / 1e9).toStringAsFixed(bytes % 1000000000 == 0 ? 0 : 1)} GB';
