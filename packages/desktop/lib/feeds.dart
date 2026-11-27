// The signed-in listener's feeds and their sync (sync.dart): fetched from
// the ListenJar API, added from YouTube links, removed, and kept in step with
// YouTube. Follows the Account (account.dart): syncs while someone is signed
// in, stops and forgets the feeds when they sign out. While signed in it
// watches the list (watchMyFeeds), so a feed added on the web dashboard
// syncs at once instead of on the next hourly pass. A podcast of the
// listener's own also takes artwork they pick (artwork.dart), uploaded like
// every file (uploads.dart). One per process; the
// window and the tray show it, the schedule (schedule.dart) syncs it. No
// widgets here.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cancellation_token/cancellation_token.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';

import 'account.dart';
import 'artwork.dart';
import 'backend/api.dart';
import 'net.dart';
import 'sync.dart';
import 'uploads.dart';
import 'youtube.dart';

final _log = Logger('feeds');

const _addTimeout = Duration(minutes: 2);

/// The server pings a quiet watch every 25 seconds; this long without a
/// byte, the connection is taken for dead and opened again.
const _watchIdle = Duration(seconds: 60);

/// Between attempts to watch, doubling from the first to the second.
const _watchRetry = (Duration(seconds: 2), Duration(minutes: 5));

/// watchMyFeeds' events (public.yaml, `text/event-stream`): each event's
/// `data` is a FeedList. Comments, the server's pings, carry none.
Stream<FeedList> _feedLists(Stream<List<int>> body) async* {
  final data = <String>[];
  await for (final line in body.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.isEmpty) {
      if (data.isNotEmpty) yield FeedList.fromJson(jsonDecode(data.join('\n')));
      data.clear();
    } else if (line.startsWith('data:')) {
      final value = line.substring(5);
      data.add(value.startsWith(' ') ? value.substring(1) : value);
    }
  }
}

final class Feeds extends ChangeNotifier {
  Feeds(this._account, this._youtube) {
    _account.addListener(_follow);
    _follow();
  }

  final Account _account;
  final YouTubeService _youtube;
  final _life = CancellationToken();

  /// Artwork uploads; audio goes through the sync's own.
  final _http = HttpClient()..connectionTimeout = const Duration(seconds: 30);

  List<Feed> feeds = const [];

  /// Feeds the listener removed here, rather than the cleanup.
  final removed = <String>{};
  Object? feedsError;
  Future<void>? _loading;
  bool get loading => _loading != null;

  /// Runs while someone is signed in.
  SyncEngine? _sync;

  /// What the sync is doing with [feed].
  FeedSync? statusOf(Feed feed) => _sync?.statusOf(feed.id);

  CancellationToken _timeout() => _life.merge(_account.timeout());

  /// The plan the feeds were last synced under.
  (Plan, int?)? _plan;
  static (Plan, int?) _planOf(User user) => (user.plan, user.storageLimitBytes);

  /// Starts syncing on sign-in, stops and forgets on sign-out.
  void _follow() {
    final signedIn = _account.user != null;
    if (signedIn && _sync == null) {
      _sync = SyncEngine(_account.api, _youtube, getApplicationSupportDirectory)
        ..addListener(notifyListeners)
        ..onPublished = _published;
      unawaited(load());
      unawaited(_watch(_sync!));
    } else if (signedIn && _plan != _planOf(_account.user!)) {
      // Bought, changed or lost a plan: free feeds stop expiring, and what
      // the old plan refused goes again.
      unawaited(load().then((_) => _sync?.syncNow()));
    } else if (!signedIn && _sync != null) {
      _closed = _sync!.close();
      _sync = null;
      feeds = const [];
      feedsError = null;
    }
    _plan = switch (_account.user) {
      final user? => _planOf(user),
      null => null,
    };
    // The summary reads the account too.
    notifyListeners();
  }

  /// The last sync's closing, since it stopped on sign-out.
  Future<void> _closed = Future.value();

  /// After the account is deleted: once its sync has stopped, forgets what
  /// it kept on this device, its journal and the partial downloads waiting
  /// to upload (sync.dart).
  Future<void> forgetDeleted() async {
    if (_account.user != null) return;
    await _closed;
    removed.clear();
    final support = await getApplicationSupportDirectory();
    for (final name in ['sync.sqlite', 'sync.sqlite-wal', 'sync.sqlite-shm', 'downloads']) {
      final entity = FileSystemEntity.typeSync('${support.path}/$name') == FileSystemEntityType.directory
        ? Directory('${support.path}/$name')
        : File('${support.path}/$name');
      try {
        if (await entity.exists()) await entity.delete(recursive: true);
      } on FileSystemException catch (e) {
        _log.warning('Couldn’t delete $name', e);
      }
    }
  }

  /// Fetches the feeds and hands them to the sync, which syncs any new one;
  /// at most once at a time: a second call gets the first's.
  Future<void> load() {
    if (_sync == null) return Future.value();
    return _loading ??= _fetch();
  }

  Future<void> _fetch() async {
    notifyListeners();
    try {
      feeds = await _account.api.listMyFeeds().asCancellable(_timeout());
      feedsError = null;
      _sync?.updateFeeds(feeds);
    } on CancelledException catch (e) {
      if (!_life.isCancelled) feedsError = e;
    } catch (e) {
      feedsError = e;
    } finally {
      _loading = null;
      notifyListeners();
    }
  }

  /// Keeps [feeds] live while [sync] runs: watchMyFeeds sends the list on
  /// connecting and again whenever it changes, whoever changed it (the web
  /// dashboard, another device, a plan), and the sync takes a new feed at
  /// once. Signing out revokes the token, which ends the stream.
  Future<void> _watch(SyncEngine sync) async {
    final (first, most) = _watchRetry;
    var wait = first;
    bool watching() => _sync == sync && !_life.isCancelled;
    while (watching()) {
      try {
        final response = await _account.api.watchMyFeeds();
        await for (final list in _feedLists(response.stream.timeout(_watchIdle))) {
          if (!watching()) break;
          wait = first;
          feeds = list.feeds;
          feedsError = null;
          sync.updateFeeds(feeds);
          notifyListeners();
          // A change of plan comes this way too.
          unawaited(_account.refresh());
        }
      } on ApiStatusException catch (e) {
        // Signed out elsewhere: the account finds out on its next call.
        if (e.statusCode == 401) return;
      } catch (_) {
        // Offline, idle too long, or the server ended it: watch again.
      }
      await Future<void>.delayed(wait);
      wait = Duration(milliseconds: min(wait.inMilliseconds * 2, most.inMilliseconds));
    }
  }

  /// A feed's episode went live: storage grew, and a feed's first one is
  /// when its RSS URL is there to fetch.
  Future<void> _published(String feedId) async {
    unawaited(_account.refresh());
    if (feeds.any((f) => f.id == feedId && f.rssUrl != null)) return;
    try {
      feeds = await _account.api.listMyFeeds().asCancellable(_timeout());
      _sync?.updateFeeds(feeds);
      notifyListeners();
    } catch (_) {
      // The next load picks it up.
    }
  }

  /// Reloads the feeds and syncs them all now, completing when that pass is
  /// done: what the schedule runs.
  Future<void> sync() async {
    final sync = _sync;
    if (sync == null) return;
    await load();
    await sync.syncAndWait();
    unawaited(_account.refresh());
  }

  /// Syncs now, from the window or the tray.
  void syncNow() => unawaited(sync());

  /// The whole sync in a few words: the tray's first line.
  String get summary {
    final phases = [for (final f in feeds) statusOf(f)?.phase ?? FeedPhase.waiting];
    final busy = phases.where((p) => p == FeedPhase.scanning || p == FeedPhase.syncing).length;
    final failed = phases.where((p) => p == FeedPhase.failed).length;
    final offline = feeds.where((f) => switch (statusOf(f)) { FeedSync(phase: FeedPhase.failed, :final error) => unreachable(error), _ => false }).length;
    return switch ((_account, this)) {
      (Account(user: null, restoring: true), _) => 'Starting…',
      (Account(user: null), _) => 'Sign in to sync',
      (_, Feeds(loading: true, feeds: [])) => 'Loading your podcasts…',
      (_, Feeds(feeds: [])) => 'No podcasts yet',
      _ when busy > 0 => feeds.length == 1 ? 'Syncing…' : 'Syncing $busy of ${feeds.length} podcasts…',
      _ when offline > 0 && offline == failed => 'Offline · syncs when you’re back online',
      _ when failed > 0 => failed == 1 ? '1 podcast couldn’t sync' : '$failed podcasts couldn’t sync',
      _ when phases.every((p) => p == FeedPhase.upToDate) => 'Up to date',
      _ => 'Waiting to sync',
    };
  }

  /// Looks [link] up on YouTube and adds it; the sync takes it from there.
  Future<Feed> add(String link, CancellationToken token) async {
    final sync = _sync;
    if (sync == null) throw StateError('Sign in to add podcasts');
    final feed = await sync.add(link, _life.merge(token).merge(TimeoutCancellationToken(_addTimeout)));
    feeds = [feed, ...feeds.where((f) => f.id != feed.id)];
    notifyListeners();
    return feed;
  }

  /// Podcasts of the listener's own: no source, they fill them.
  List<Feed> get own => [for (final f in feeds) if (f.source == null) f];

  /// The plan's storage is full: some feed stopped on it (507).
  bool get storageFull => feeds.any((f) => switch (statusOf(f)?.error) {
    PlanLimit(storageFull: true) => true,
    _ => false,
  });

  /// Videos waiting for room in the plan's storage.
  int get waitingForRoom => feeds.fold(0, (n, f) => switch (statusOf(f)) {
    FeedSync(error: PlanLimit(storageFull: true), :final waiting) => n + waiting,
    _ => n,
  });

  /// Makes a podcast of the listener's own, empty until they add videos.
  Future<Feed> create(String title) async {
    final Feed feed;
    try {
      feed = await _account.api.addFeed(body: NewFeed(title: title)).asCancellable(_timeout());
    } on ApiStatusException catch (e) {
      throw PlanLimit.of(e) ?? e;
    }
    feeds = [feed, ...feeds.where((f) => f.id != feed.id)];
    _sync?.updateFeeds(feeds);
    notifyListeners();
    return feed;
  }

  /// Adds the video at [link] to [feed], a podcast of the listener's own;
  /// the sync uploads its audio.
  Future<void> addVideo(Feed feed, String link, CancellationToken token) async {
    final sync = _sync;
    if (sync == null) throw StateError('Sign in to add podcasts');
    await sync.addVideo(feed, link, _life.merge(token).merge(TimeoutCancellationToken(_addTimeout)));
  }

  /// Every episode of [feed], for making room.
  Future<List<Episode>> episodes(Feed feed) => _account.api.listEpisodes(feedId: feed.id).asCancellable(_timeout());

  /// Removes one episode of a podcast of the listener's own, and its audio
  /// when no other feed has the video.
  Future<void> removeEpisode(Feed feed, Episode episode) async {
    await _account.api.deleteEpisode(feedId: feed.id, episodeId: episode.id).asCancellable(_timeout());
    _madeRoom();
  }

  /// Storage went down: show it, and retry what was waiting for room.
  void _madeRoom() {
    unawaited(_account.refresh(force: true));
    if (storageFull) _sync?.syncNow();
  }

  /// Makes [picture] the artwork of [feed], a podcast of the listener's
  /// own: squared and sized for podcast apps, uploaded, and in its RSS.
  /// [progress] counts the upload's bytes.
  Future<Feed> setArtwork(Feed feed, Uint8List picture, {void Function(double)? progress}) async {
    final artwork = await podcastArtwork(picture);
    final Feed updated;
    try {
      updated = (await uploadThrough(
        _http,
        UploadFile.bytes(artwork, 'image/jpeg'),
        presign: (request) => _account.api.createImageUpload(feedId: feed.id, body: request),
        complete: () => _account.api.completeImage(feedId: feed.id),
        progress: (done, total) => progress?.call(done / total),
        token: _life.merge(TimeoutCancellationToken(_addTimeout)),
      ))!;
    } on ApiStatusException catch (e) {
      throw PlanLimit.of(e) ?? e;
    }
    feeds = [for (final f in feeds) f.id == updated.id ? updated : f];
    notifyListeners();
    return updated;
  }

  /// Makes [feed], a podcast of the listener's own, public (a page on
  /// listenjar.com, at its `pageUrl`) or private again; throws when it
  /// couldn't, and it stays as it was.
  Future<Feed> setVisibility(Feed feed, FeedVisibility visibility) async {
    final updated = await _account.api
      .setFeedVisibility(feedId: feed.id, body: VisibilityChange(visibility: visibility))
      .asCancellable(_timeout());
    feeds = [for (final f in feeds) f.id == updated.id ? updated : f];
    notifyListeners();
    return updated;
  }

  /// Removes the feed and everything uploaded to it; throws when it
  /// couldn't, and the feed stays.
  Future<void> remove(Feed feed) async {
    await _account.api.deleteFeed(feedId: feed.id).asCancellable(_timeout());
    removed.add(feed.id);
    feeds = feeds.where((f) => f.id != feed.id).toList();
    _sync?.updateFeeds(feeds);
    _madeRoom();
    notifyListeners();
  }

  /// Quiet once disposed: calls in flight then finish into nothing.
  @override
  void notifyListeners() {
    if (!_life.isCancelled) super.notifyListeners();
  }

  @override
  void dispose() {
    _life.cancel();
    _http.close(force: true);
    _account.removeListener(_follow);
    unawaited(_sync?.close());
    super.dispose();
  }
}
