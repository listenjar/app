// The sync engine: keeps each of the listener's feeds in step with its
// YouTube source. Ported from the Listenbox client's Go sync engine
// (crates/sync-engine/sync.go), against the Listenjar API (public.yaml):
//
// 1. Read what the feed has (listEpisodes) and what the source holds now
//    (youtube.dart). A podcast of the listener's own has no source: its
//    episodes are what they added, and the engine only uploads their audio.
// 2. Remove episodes whose videos left a playlist or channel.
// 3. For every video the feed lacks: resolve it, add it (createEpisode).
//    Audio is stored once per video, so if anyone's feed has it already the
//    episode is live and that's all. Otherwise download it on this computer
//    (transfer.dart), rewrite YouTube's AAC as a regular M4A with the video's
//    chapters in it (faststart.dart), upload it (uploads.dart: createUpload, a PUT straight
//    to R2, completeEpisode), delete the file.
//
// Feeds take a Cloud plan; a plan that's full, or gone, stops the feed until
// there's room (PlanLimit).
//
// A source's audio is fetched and stored once, for every listener and feed
// that has it, and nothing is locked: devices race, and each step is
// compare-and-set on the server or in the bucket. The first call of anyone's
// to add a source asks for its audio, and the server tells each device when
// to start fetching it (Episode.fetchAfter): at once for the device that
// asked, a while later for every other, the listener's own and everyone
// else's. Until then this device leaves it be ([FeedSync.elsewhere]) and
// makes no YouTube call for it. The upload only creates (If-None-Match), so
// the first audio to land stays, and a device whose PUT gets 412 completes
// the episode all the same, which publishes what landed. A device still
// fetching a video stops once the feed list (watchMyFeeds) shows its upload
// live.
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
import 'package:logging/logging.dart';

import 'backend/api.dart';
import 'chapters.dart';
import 'faststart.dart';
import 'links.dart';
import 'net.dart';
import 'transfer.dart';
import 'uploads.dart';
import 'youtube.dart';

final _log = Logger('sync');

const _videoWorkers = 2;
const _attempts = 5;

/// A skipped video (private, removed, live) is asked about again after this.
const _skipMemory = Duration(hours: 24);

/// What the listener's plan doesn't allow: the feed waits until they change it.
final class PlanLimit implements Exception {
  const PlanLimit(this.message, {this.storageFull = false});
  final String message;

  /// 507: the plan's storage is full. Otherwise 402: the plan has no
  /// Listenjar Cloud (Free, Local YouTube), which this takes.
  final bool storageFull;

  static const pricing = 'listenjar.com/pricing';

  /// 402 and 507 from the API, as the listener reads them.
  static PlanLimit? of(Object e) => switch (e) {
    ApiStatusException(statusCode: 402) => const PlanLimit(
      'Feeds in Listenjar Cloud need a Cloud plan: $pricing',
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

/// One video on its way up from this device: what is happening to it and
/// how far along it is.
final class VideoSync {
  VideoSync(this.title);
  final String title;
  String stage = 'Looking up';
  double? fraction;
}

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

  /// The videos this device is bringing up now, by watch URL, in the order
  /// they started. Each keeps its own stage and progress, so two at once
  /// never take turns in one line.
  final videos = <String, VideoSync>{};

  /// Videos another device asked for first and is bringing up, by watch
  /// URL: this one leaves each to it until the time here (the episode's
  /// fetchAfter), then races for it too.
  final elsewhere = <String, DateTime>{};

  /// The video in flight that started first: the one a single line follows
  /// until it's done.
  VideoSync? get lead => videos.values.firstOrNull;
  String? get current => lead?.title;
  String? get stage => lead?.stage;
  double? get fraction => lead?.fraction;

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

  /// What the next pass syncs: every feed, and some by id.
  bool _all = false;
  final _some = <String>{};

  /// Each video in flight's own cancellation, by feed and watch URL: it
  /// stops when another device's upload of the video goes live first.
  final _flights = <(String, String), CancellationToken>{};

  /// Looks again once the first video left to another device is this
  /// device's to race for.
  Timer? _wake;

  /// Waiting for the pass running now, or the one after it, to end.
  final _passed = <Completer<void>>[];

  FeedSync? statusOf(String feedId) => _status[feedId];

  /// The listener's feeds, first or changed: syncs any new one now. The
  /// schedule (schedule.dart) asks for the regular passes; the engine's own
  /// clock only looks again at videos left to another device ([_wake]).
  ///
  /// The list changes whenever any device adds an episode or lands an
  /// upload. A podcast of the listener's own is looked at again then: it
  /// takes no YouTube call, so another device's additions show here at once.
  /// Videos in flight whose feed published more are checked, and dropped
  /// when another device's upload of them is live.
  void updateFeeds(List<Feed> feeds) {
    final before = {for (final f in _feeds) f.id: f};
    _feeds = feeds;
    _status.removeWhere((id, _) => !feeds.any((f) => f.id == id));
    if (feeds.any((f) => !before.containsKey(f.id))) syncNow();
    for (final feed in feeds) {
      final was = before[feed.id];
      if (was == null || identical(was, feed)) continue;
      if (was.episodeCount != feed.episodeCount) unawaited(_landedElsewhere(feed));
      if (feed.source == null) _syncFeeds([feed.id]);
    }
    _changed();
  }

  /// Stops bringing up the videos of [feed] another device's upload put
  /// live meanwhile, and stops waiting on them.
  Future<void> _landedElsewhere(Feed feed) async {
    final status = _status[feed.id];
    final flying = _flights.keys.any((k) => k.$1 == feed.id);
    if (!flying && (status?.elsewhere.isEmpty ?? true)) return;
    try {
      final inventory = await _api.listEpisodes(feedId: feed.id).asCancellable(_life);
      for (final episode in inventory) {
        if (episode.uploadedAt == null) continue;
        _flights[(feed.id, episode.sourceUrl)]?.cancel();
        status?.elsewhere.remove(episode.sourceUrl);
      }
      _changed();
    } catch (_) {
      // The next pass finds it live.
    }
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
    _all = true;
    _kick();
  }

  /// Syncs the feeds [ids] now, or right after the current pass.
  void _syncFeeds(Iterable<String> ids) {
    _some.addAll(ids);
    _kick();
  }

  void _kick() {
    if (_life.isCancelled || _running) return;
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
    final episode = await _addEpisode(
      feed,
      NewEpisode(
        sourceUrl: link.url,
        title: _clip(media.title, 500),
        description: _clip(media.description, 10000),
        publishedAt: media.publishedAt.toIso8601String(),
        durationSeconds: media.durationSeconds,
      ),
      merged,
    );
    if (episode.uploadedAt != null) onPublished?.call(feed.id);
    _syncFeeds([feed.id]);
    return episode;
  }

  Future<void> close() async {
    _life.cancel();
    _wake?.cancel();
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
    _wake?.cancel();
    try {
      while ((_all || _some.isNotEmpty) && !_life.isCancelled) {
        final only = _all ? null : {..._some};
        _all = false;
        _some.clear();
        for (final feed in [..._feeds]) {
          if (_life.isCancelled) return;
          if (only != null && !only.contains(feed.id)) continue;
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
      }
    } finally {
      _running = false;
      _wakeForElsewhere();
      for (final passed in _passed) {
        passed.complete();
      }
      _passed.clear();
    }
  }

  /// Looks again at the feeds with videos left to another device once the
  /// first of them is this device's to race for.
  void _wakeForElsewhere() {
    _wake?.cancel();
    if (_life.isCancelled) return;
    final waiting = {
      for (final MapEntry(key: id, value: s) in _status.entries)
        if (s.elsewhere.isNotEmpty) id: s.elsewhere.values.reduce((a, b) => a.isBefore(b) ? a : b),
    };
    if (waiting.isEmpty) return;
    final first = waiting.values.reduce((a, b) => a.isBefore(b) ? a : b);
    _wake = Timer(first.difference(DateTime.now()) + const Duration(seconds: 5), () => _syncFeeds(waiting.keys));
  }

  /// Until when [episode] is left to the device that asked for it first;
  /// null when it's this device's to fetch now.
  static DateTime? _leftUntil(Episode episode) {
    if (episode.uploadedAt != null) return null;
    final after = DateTime.tryParse(episode.fetchAfter ?? '');
    return after != null && after.isAfter(DateTime.now()) ? after : null;
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
    status.elsewhere.clear();
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

      // A playlist's episodes are numbered in its order, so its RSS, a
      // serial show, lists them as the playlist does; reordered, again.
      final numbers = <String, int>{
        if (source?.kind == SourceRefKind.playlist)
          for (final (i, v) in snapshot.videos.indexed) youTubeVideoUrl(v.id): i + 1,
      };
      if (inventory.any((e) => numbers.containsKey(e.sourceUrl) && numbers[e.sourceUrl] != e.number)) {
        await _retry(
          () => _api.numberEpisodes(feedId: feed.id, body: EpisodeNumbers(sourceUrls: [...numbers.keys])).asCancellable(token),
          token,
        );
      }

      final uploaded = {for (final e in inventory) if (e.uploadedAt != null) e.sourceUrl};
      status.episodes = uploaded.where(present.contains).length + (snapshot.canRemove ? 0 : uploaded.difference(present).length);
      final made = {for (final e in inventory) e.sourceUrl: e};
      final additions = <Video>[];
      for (final video in snapshot.videos) {
        final url = youTubeVideoUrl(video.id);
        if (uploaded.contains(url) || journal.skipped(_key(feed, url), _skipMemory) != null) continue;
        // Another device asked first: no YouTube call here while it has it.
        if (made[url] case final episode?) {
          if (_leftUntil(episode) case final until?) {
            status.elsewhere[url] = until;
            continue;
          }
        }
        additions.add(video);
      }
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
            await _transferVideo(
              feed,
              source?.kind == SourceRefKind.channel,
              video,
              numbers[youTubeVideoUrl(video.id)],
              youtube,
              journal,
              status,
              token,
            );
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
        ..checkedAt = DateTime.now();
      status.videos.clear();
      // listenjar.com's dashboard shows when the app last checked YouTube.
      // Only a pass that left the feed up to date counts; a failed report
      // fails nothing, and the next pass sends it again.
      if (source != null && status.phase == FeedPhase.upToDate) {
        unawaited(_api.markFeedSynced(feedId: feed.id).asCancellable(token).then((_) {}, onError: (_) {}));
      }
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
    int? number,
    YouTube youtube,
    Journal journal,
    FeedSync status,
    CancellationToken pass,
  ) async {
    final url = youTubeVideoUrl(video.id);
    final key = _key(feed, url);
    final flight = CancellationToken();
    _flights[(feed.id, url)] = flight;
    final token = pass.merge(flight);
    final progress = status.videos[url] = VideoSync(video.title);
    void show(String stage, [int done = 0, int total = 0]) {
      progress
        ..stage = stage
        ..fraction = total > 0 ? done / total : null;
      _changed();
    }

    try {
      await _retry(() async {
        show('Looking up');
        final (media, reason) = await youtube.media(video.id, channel: channel, token: token);
        if (media == null) {
          journal.skip(key, reason!);
          status.skipped++;
          return;
        }

        final episode = await _addEpisode(
          feed,
          NewEpisode(
            sourceUrl: url,
            title: _clip(media.title, 500),
            description: _clip(media.description, 10000),
            publishedAt: media.publishedAt.toIso8601String(),
            durationSeconds: media.durationSeconds,
            number: number,
          ),
          token,
        );
        // Another device, anyone's, asked for it first: it's that one's
        // for a while.
        if (_leftUntil(episode) case final until?) {
          status.elsewhere[url] = until;
          return;
        }

        // Someone's feed has this video's audio already: live with nothing to download.
        if (episode.uploadedAt == null) {
          // Only an M4A gets them: WebM is uploaded as it is.
          final chapters = media.contentType == 'audio/mp4' ? await _chapters(youtube, video.id, token) : const <Chapter>[];
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
          // so Apple Podcasts) plays at twice the length, with the video's
          // chapters baked in for every podcast app (faststart.dart).
          show('Preparing');
          final rewritten = media.contentType == 'audio/mp4' ? await faststart(file, token, chapters: chapters) : null;
          try {
            show('Uploading');
            await uploadThrough(
              _mediaHttp,
              await UploadFile.fromFile(rewritten ?? file, media.contentType),
              presign: (request) async {
                try {
                  return await _api.createUpload(feedId: feed.id, episodeId: episode.id, body: request);
                } on ApiStatusException catch (e) {
                  // 409: another device's upload landed first, and the episode is live.
                  if (e.statusCode == HttpStatus.conflict) return null;
                  throw PlanLimit.of(e) ?? e;
                }
              },
              complete: () async {
                try {
                  return await _api.completeEpisode(feedId: feed.id, episodeId: episode.id);
                } on ApiStatusException catch (e) {
                  throw PlanLimit.of(e) ?? e;
                }
              },
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
    } on CancelledException {
      if (pass.isCancelled || !flight.isCancelled) rethrow;
      // Another device's upload went live first: this copy isn't needed.
      await journal.forget(key);
      status.episodes++;
      onPublished?.call(feed.id);
    } finally {
      _flights.remove((feed.id, url));
      status.videos.remove(url);
      _changed();
    }
  }

  /// The chapters of the video [id], for its upload: asked of YouTube only
  /// for audio no one has uploaded, since the upload carries them from then
  /// on. None when YouTube doesn't answer for them; a network failure is
  /// tried again with the rest of the video.
  Future<List<Chapter>> _chapters(YouTube youtube, String id, CancellationToken token) async {
    try {
      return await youtube.chapters(id, token) ?? const [];
    } on CancelledException {
      rethrow;
    } catch (e) {
      if (_retryable(e)) rethrow;
      _log.warning('Uploading $id without chapters', e);
      return const [];
    }
  }

  /// Adds the episode [body] to [feed], or refreshes the one it has.
  Future<Episode> _addEpisode(Feed feed, NewEpisode body, CancellationToken token) async {
    try {
      return await _api.createEpisode(feedId: feed.id, body: body).asCancellable(token);
    } on ApiStatusException catch (e) {
      throw PlanLimit.of(e) ?? e;
    }
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
  _ when unreachable(e) => true,
  TransferStatusException(:final statusCode) || ApiStatusException(:final statusCode) => statusCode >= 500,
  _ => false,
};
