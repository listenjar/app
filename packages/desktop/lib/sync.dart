// The sync engine: keeps each of the listener's feeds in step with its
// YouTube source. Ported from the Listenbox client's Go sync engine
// (crates/sync-engine/sync.go), against the ListenJar API (public.yaml):
//
// 1. Read what the feed has (listEpisodes) and what the source holds now
//    (youtube.dart). A podcast of the listener's own has no source: its
//    episodes are what they added, and the engine only uploads their audio.
// 2. Remove episodes whose videos left a playlist or channel.
// 3. For every video the feed lacks: resolve it, add it (createEpisode).
//    Audio is stored once per video, so if anyone's feed has it already the
//    episode is live and that's all. Otherwise download it on this computer
//    (transfer.dart), rewrite YouTube's AAC as a regular M4A (faststart.dart),
//    upload it (uploads.dart: createUpload, a PUT straight
//    to R2, completeEpisode), delete the file.
//
// A free listener's single video is all the backend takes from them; a plan
// that's full stops the feed until there's room (PlanLimit).
//
// Transient failures retry up to five times with backoff. When YouTube
// rate-limits the session, the rest waits for the next pass. Every feed is
// checked on each scheduled pass (about hourly, schedule.dart), and right
// away when it is added.
//
// Pure Dart (no Flutter), so it also runs from a plain `dart` script.
import 'dart:async';
import 'dart:io';

import 'package:cancellation_token/cancellation_token.dart';
import 'package:http/http.dart' as http;

import 'backend/api.dart';
import 'faststart.dart';
import 'links.dart';
import 'transfer.dart';
import 'uploads.dart';
import 'youtube.dart';

const _videoWorkers = 2;
const _attempts = 5;

/// A skipped video (private, removed, live) is asked about again after this.
const _skipMemory = Duration(hours: 24);

/// What the listener's plan doesn't allow: the feed waits until they change it.
final class PlanLimit implements Exception {
  const PlanLimit(this.message, {this.storageFull = false});
  final String message;

  /// 507: the plan's storage is full. Otherwise 402: the plan has no
  /// ListenJar Cloud (Free, Local), which this takes.
  final bool storageFull;

  static const pricing = 'listenjar.com/pricing';

  /// 402 and 507 from the API, as the listener reads them.
  static PlanLimit? of(Object e) => switch (e) {
    ApiStatusException(statusCode: 402) => const PlanLimit(
      'Playlists, channels and podcasts of your own in ListenJar Cloud need a 10 GB or 100 GB plan: $pricing',
    ),
    ApiStatusException(statusCode: 507) => const PlanLimit(
      'Your plan’s storage is full. Remove episodes or pick a bigger plan: $pricing',
      storageFull: true,
    ),
    _ => null,
  };

  @override
  String toString() => message;
}

enum FeedPhase { waiting, scanning, syncing, upToDate, failed }

/// What the engine is doing with one feed, for the window.
final class FeedSync {
  FeedPhase phase = FeedPhase.waiting;

  /// Episodes in the feed's RSS.
  int episodes = 0;

  /// Videos this pass still has to add, and how many it added or skipped.
  int queued = 0;
  int added = 0;
  int skipped = 0;
  int failed = 0;

  /// Videos a [PlanLimit] stopped: they sync once the plan allows.
  int waiting = 0;

  /// The video in flight, what is happening to it and how far along it is.
  String? current;
  String? stage;
  double? fraction;
  Object? error;
  DateTime? checkedAt;
}

final class SyncEngine {
  SyncEngine(this._api, this._youtube, this._support);

  final _listeners = <void Function()>[];

  /// Called when an episode of [Feed] `feedId` goes live in its RSS: a feed's
  /// first one is when it gets an RSS URL (public.yaml).
  void Function(String feedId)? onPublished;

  /// Called, at most ten times a second, when any feed's status changes.
  void addListener(void Function() listener) => _listeners.add(listener);
  void removeListener(void Function() listener) => _listeners.remove(listener);

  final PublicApiClient _api;
  final YouTubeService _youtube;
  final Future<Directory> Function() _support;
  final _life = CancellationToken();

  /// Media servers and uploads, apart from YouTube's API connections.
  final _mediaHttp = HttpClient()
    ..userAgent = null
    ..connectionTimeout = const Duration(seconds: 30)
    ..idleTimeout = const Duration(seconds: 30);

  Journal? _journal;
  Future<Journal>? _opening;
  Timer? _notify;

  List<Feed> _feeds = const [];
  final _status = <String, FeedSync>{};
  bool _running = false;
  bool _again = false;

  /// Waiting for the pass running now, or the one after it, to end.
  final _passed = <Completer<void>>[];

  FeedSync? statusOf(String feedId) => _status[feedId];

  /// The listener's feeds, first or changed: syncs any new one now. The
  /// engine keeps no clock; the schedule (schedule.dart) asks for passes.
  void updateFeeds(List<Feed> feeds) {
    final known = _feeds.map((f) => f.id).toSet();
    _feeds = feeds;
    _status.removeWhere((id, _) => !feeds.any((f) => f.id == id));
    if (feeds.any((f) => !known.contains(f.id))) syncNow();
    _changed();
  }

  /// Runs a pass now, unless one is running already, and completes when
  /// that pass is done: a scheduled sync (Feeds.sync).
  Future<void> syncAndWait() {
    if (_life.isCancelled) return Future.value();
    final passed = Completer<void>();
    _passed.add(passed);
    if (!_running) syncNow();
    return passed.future;
  }

  /// Runs a pass over every feed, or another right after the current one.
  void syncNow() {
    if (_life.isCancelled) return;
    if (_running) {
      _again = true;
      return;
    }
    unawaited(_pass());
  }

  /// Resolves what the listener pasted with YouTube and adds it to the listener's feeds.
  Future<Feed> add(String input, CancellationToken token) async {
    final link = parseYouTubeLink(input);
    if (link == null) throw const FormatException('That isn’t a YouTube video, playlist or channel link.');
    final kind = switch (link.kind) {
      SourceKind.video => SourceRefKind.video,
      SourceKind.playlist => SourceRefKind.playlist,
      SourceKind.channel => SourceRefKind.channel,
    };
    final merged = _life.merge(token);
    final resolved = await (await _youtube.session(merged)).resolve(SourceRef(kind, link.id, link.url), merged);
    final Feed feed;
    try {
      feed = await _api
        .addFeed(body: NewFeed(
          source: Source(kind: link.kind, url: resolved.url),
          title: _clip(resolved.title, 500),
          imageUrl: resolved.artworkUrl,
        ))
        .asCancellable(merged);
    } on ApiStatusException catch (e) {
      throw PlanLimit.of(e) ?? e;
    }
    if (!_feeds.any((f) => f.id == feed.id)) updateFeeds([feed, ..._feeds]);
    return feed;
  }

  /// Adds the pasted video to [feed], a podcast of the listener's own:
  /// reads its details from YouTube and records the episode; the next pass,
  /// started now, downloads and uploads its audio.
  Future<Episode> addVideo(Feed feed, String input, CancellationToken token) async {
    final link = parseYouTubeLink(input);
    if (link == null || link.kind != SourceKind.video) {
      throw const FormatException('That isn’t a YouTube video link.');
    }
    final merged = _life.merge(token);
    final (media, reason) = await (await _youtube.session(merged)).media(link.id, channel: false, token: merged);
    if (media == null) throw StateError(reason ?? 'YouTube didn’t play it.');
    final Episode episode;
    try {
      episode = await _api
        .createEpisode(
          feedId: feed.id,
          body: NewEpisode(
            sourceUrl: link.url,
            title: _clip(media.title, 500),
            description: _clip(media.description, 10000),
            publishedAt: media.publishedAt.toIso8601String(),
            durationSeconds: media.durationSeconds,
          ),
        )
        .asCancellable(merged);
    } on ApiStatusException catch (e) {
      throw PlanLimit.of(e) ?? e;
    }
    if (episode.uploadedAt != null) onPublished?.call(feed.id);
    syncNow();
    return episode;
  }

  Future<void> close() async {
    _life.cancel();
    for (final passed in _passed) {
      passed.complete();
    }
    _passed.clear();
    _notify?.cancel();
    _journal?.close();
    _mediaHttp.close(force: true);
    _listeners.clear();
  }

  /// Coalesces progress into at most ten repaints a second.
  void _changed() {
    if (_notify != null || _life.isCancelled) return;
    _notify = Timer(const Duration(milliseconds: 100), () {
      _notify = null;
      if (_life.isCancelled) return;
      for (final listener in [..._listeners]) {
        listener();
      }
    });
  }

  Future<Journal> _openJournal() => _opening ??= _support().then(Journal.open).then((journal) => _journal = journal);

  Future<void> _pass() async {
    _running = true;
    try {
      do {
        _again = false;
        for (final feed in [..._feeds]) {
          if (_life.isCancelled) return;
          if (!_feeds.any((f) => f.id == feed.id)) continue;
          try {
            await _syncFeed(feed);
          } on RateLimited catch (e) {
            // Nothing more will work this session: the rest waits.
            for (final other in _feeds) {
              final status = _status[other.id] ??= FeedSync();
              if (status.phase != FeedPhase.upToDate || other == feed) {
                status
                  ..phase = FeedPhase.failed
                  ..error = '$e. Trying again in an hour.';
              }
            }
            _changed();
            await _youtube.restart();
            break;
          }
        }
      } while (_again && !_life.isCancelled);
    } finally {
      _running = false;
      for (final passed in _passed) {
        passed.complete();
      }
      _passed.clear();
    }
  }

  Future<void> _syncFeed(Feed feed) async {
    final status = _status[feed.id] ??= FeedSync();
    // null for a podcast of the listener's own.
    final source = switch (feed.source) {
      final s? => SourceRef.parse(s.kind.value, s.url),
      null => null,
    };
    if (feed.source != null && source == null) return;
    status
      ..phase = FeedPhase.scanning
      ..error = null
      ..added = 0
      ..skipped = 0
      ..failed = 0
      ..waiting = 0
      ..queued = 0;
    _changed();
    try {
      final token = _life;
      final youtube = await _youtube.session(token);
      final journal = await _openJournal();
      final inventory = await _api.listEpisodes(feedId: feed.id).asCancellable(token);
      // A podcast of the listener's own holds what they added, nothing to remove.
      final snapshot = source == null
        ? Snapshot(
            title: feed.title,
            artworkUrl: feed.imageUrl,
            videos: [
              for (final e in inventory)
                if (parseYouTubeLink(e.sourceUrl) case YouTubeLink(kind: SourceKind.video, :final id))
                  Video(id: id, title: e.title, durationSeconds: e.durationSeconds),
            ],
            canRemove: false,
          )
        : await youtube.snapshot(source, token);
      // Episodes match by source URL, whatever the source.
      final present = {for (final v in snapshot.videos) youTubeVideoUrl(v.id)};

      if (snapshot.canRemove) {
        for (final episode in inventory) {
          if (present.contains(episode.sourceUrl)) continue;
          await _retry(() => _api.deleteEpisode(feedId: feed.id, episodeId: episode.id).asCancellable(token), token);
          await journal.forget(_key(feed, episode.sourceUrl));
        }
      }

      final uploaded = {for (final e in inventory) if (e.uploadedAt != null) e.sourceUrl};
      status.episodes = uploaded.where(present.contains).length + (snapshot.canRemove ? 0 : uploaded.difference(present).length);
      final additions = [
        for (final video in snapshot.videos)
          if (!uploaded.contains(youTubeVideoUrl(video.id)) && journal.skipped(_key(feed, youTubeVideoUrl(video.id)), _skipMemory) == null) video,
      ];
      status
        ..phase = additions.isEmpty ? FeedPhase.upToDate : FeedPhase.syncing
        ..queued = additions.length;
      _changed();

      // Newest first, as the source lists them; a few at a time.
      var next = 0;
      Object? limited;
      PlanLimit? stopped;
      Future<void> worker() async {
        while (next < additions.length && limited == null && stopped == null) {
          final video = additions[next++];
          try {
            await _transferVideo(feed, source?.kind == SourceRefKind.channel, video, youtube, journal, status, token);
          } on RateLimited catch (e) {
            limited = e;
          } on PlanLimit catch (e) {
            stopped = e;
          } on CancelledException {
            rethrow;
          } catch (e) {
            status.failed++;
            status.error = e;
          }
          status.queued--;
          _changed();
        }
      }

      await Future.wait([for (var i = 0; i < _videoWorkers; i++) worker()]);
      if (limited case final RateLimited e) throw e;
      if (stopped case final PlanLimit e) {
        status
          ..failed += 1
          ..error = e
          ..waiting = additions.length - status.added - status.skipped
          ..queued = 0;
      }
      status
        ..phase = status.failed > 0 ? FeedPhase.failed : FeedPhase.upToDate
        ..current = null
        ..stage = null
        ..fraction = null
        ..checkedAt = DateTime.now();
    } on CancelledException {
      return;
    } on RateLimited {
      rethrow;
    } catch (e) {
      status
        ..phase = FeedPhase.failed
        ..error = e;
    } finally {
      _changed();
    }
  }

  Future<void> _transferVideo(
    Feed feed,
    bool channel,
    Video video,
    YouTube youtube,
    Journal journal,
    FeedSync status,
    CancellationToken token,
  ) async {
    final key = _key(feed, youTubeVideoUrl(video.id));
    void show(String stage, [int done = 0, int total = 0]) {
      status
        ..current = video.title
        ..stage = stage
        ..fraction = total > 0 ? done / total : null;
      _changed();
    }

    await _retry(() async {
      show('Looking up');
      final (media, reason) = await youtube.media(video.id, channel: channel, token: token);
      if (media == null) {
        journal.skip(key, reason!);
        status.skipped++;
        return;
      }

      final Episode episode;
      try {
        episode = await _api
          .createEpisode(
            feedId: feed.id,
            body: NewEpisode(
              sourceUrl: youTubeVideoUrl(video.id),
              title: _clip(media.title, 500),
              description: _clip(media.description, 10000),
              publishedAt: media.publishedAt.toIso8601String(),
              durationSeconds: media.durationSeconds,
            ),
          )
          .asCancellable(token);
      } on ApiStatusException catch (e) {
        throw PlanLimit.of(e) ?? e;
      }

      // Someone's feed has this video's audio already: live with nothing to download.
      if (episode.uploadedAt == null) {
        File file;
        while (true) {
          try {
            file = await download(_mediaHttp, journal, key, media.audio, (d, t) => show('Downloading', d, t), token);
            break;
          } on MediaUnavailable {
            if (!await youtube.fallback(media, token)) rethrow;
          }
        }

        // A regular M4A rather than YouTube's fragments, which AVPlayer (and
        // so Apple Podcasts) plays at twice the length (faststart.dart).
        show('Preparing');
        final rewritten = media.contentType == 'audio/mp4' ? await faststart(file, token) : null;
        try {
          show('Uploading');
          await uploadThrough(
            _mediaHttp,
            await UploadFile.fromFile(rewritten ?? file, media.contentType),
            presign: (request) async {
              try {
                return await _api.createUpload(feedId: feed.id, episodeId: episode.id, body: request);
              } on ApiStatusException catch (e) {
                // 409: another computer uploaded it first, and the episode is live.
                if (e.statusCode == HttpStatus.conflict) return null;
                throw PlanLimit.of(e) ?? e;
              }
            },
            complete: () => _api.completeEpisode(feedId: feed.id, episodeId: episode.id),
            progress: (d, t) => show('Uploading', d, t),
            token: token,
          );
        } finally {
          await rewritten?.delete();
        }
      }
      await journal.forget(key);
      status.added++;
      status.episodes++;
      onPublished?.call(feed.id);
    }, token);
  }

  /// Runs [action] up to five times while it fails in a way worth retrying.
  Future<T> _retry<T>(Future<T> Function() action, CancellationToken token) async {
    for (var attempt = 1; ; attempt++) {
      try {
        return await action();
      } catch (e) {
        if (attempt == _attempts || !_retryable(e) || token.isCancelled) rethrow;
        await Future<void>.delayed(Duration(seconds: 1 << (attempt - 1))).asCancellable(token);
      }
    }
  }
}

/// What the journal remembers of the episode of [feed] made from [sourceUrl].
String _key(Feed feed, String sourceUrl) => '${feed.id}/$sourceUrl';

String _clip(String text, int max) => text.length <= max ? text : text.substring(0, max);

bool _retryable(Object e) => switch (e) {
  SocketException() || HttpException() || TimeoutException() || http.ClientException() => true,
  TransferStatusException(:final statusCode) || ApiStatusException(:final statusCode) => statusCode >= 500,
  _ => false,
};
