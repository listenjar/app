// The library and the signed-in listener's ListenJar feeds (feeds.dart), in
// step. Every show starts on this device: a YouTube playlist or channel
// lists its videos here and streams them, a podcast of the listener's own
// takes the videos they add (podcasts.dart). On a plan with ListenJar
// Cloud, each also gets a ListenJar feed ([CloudShows._host]): this device
// fetches its videos from YouTube and uploads their audio (sync.dart), and
// once the feed has an RSS address the show becomes that RSS show in place
// ([Podcasts.followCloud]), a classic podcast that syncs between the
// listener's devices like any other (library_sync.dart). Shows and feeds
// match by source URL ([canonicalSourceUrl]), whatever the source.
import 'dart:async';
import 'dart:io';

import 'package:cancellation_token/cancellation_token.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import 'account.dart';
import 'backend/api.dart';
import 'feeds.dart';
import 'library.dart';
import 'links.dart' show canonicalSourceUrl;
import 'podcasts.dart';

final _log = Logger('cloud shows');

/// A show that couldn't get a feed is tried again after this.
const _retryHost = Duration(minutes: 30);

/// How long the library settles before shows new to it get feeds.
const _settle = Duration(seconds: 2);

final class CloudShows {
  CloudShows(this._account, this._feeds, this._podcasts) {
    _feeds.addListener(_changed);
    _podcasts.library.addListener(_hostSoon);
    _account.addListener(_hostSoon);
  }

  final Account _account;
  final Feeds _feeds;
  final Podcasts _podcasts;
  Library get _library => _podcasts.library;

  /// Each feed's RSS address and episode count as last seen.
  Map<String, (String?, int?)> _seen = const {};
  bool _wasLoading = false;
  bool _loaded = false;

  void _changed() {
    if (_account.user == null) {
      _seen = const {};
      _loaded = false;
      return;
    }
    if (_wasLoading && !_feeds.loading && _feeds.feedsError == null) _loaded = true;
    _wasLoading = _feeds.loading;
    // Until the list has loaded, an empty one says nothing.
    if (!_loaded && _feeds.feeds.isEmpty) return;
    _hostSoon();
    final now = {for (final f in _feeds.feeds) f.id: (f.rssUrl, f.episodeCount)};
    if (mapEquals(now, _seen)) return;
    final before = _seen;
    _seen = now;
    unawaited(_podcasts.followCloud(_feeds.feeds, removed: _feeds.removed).then((_) async {
      for (final MapEntry(key: id, value: (_, count)) in now.entries) {
        final was = before[id];
        if (was != null && was.$2 != count) await _podcasts.cloudPublished(id);
      }
    }));
  }

  // Hosting.

  Timer? _soon;
  Future<void>? _hosting;
  final _failed = <int, DateTime>{};

  void _hostSoon() {
    _soon?.cancel();
    _soon = Timer(_settle, () => unawaited(_host()));
  }

  /// Whether the plan uploads: signed in, on ListenJar Cloud, with the
  /// feeds loaded so a show isn't given a second one.
  bool get _uploads => _account.user?.storageLimitBytes != null && _account.user?.plan == Plan.paid && _loaded;

  /// Gives each YouTube playlist, channel and podcast of the listener's own
  /// followed here, but not hosted yet, its ListenJar feed.
  Future<void> _host() async {
    if (_hosting != null || !_uploads) return;
    final pass = () async {
      for (final show in [..._library.podcasts]) {
        if (!_uploads) return;
        if (show.cloudFeedId != null || !show.followed) continue;
        if (show.kind != PodcastKind.youtubeFeed && show.kind != PodcastKind.own) continue;
        if (_failed[show.id] case final at? when DateTime.now().difference(at) < _retryHost) continue;
        try {
          await _feedFor(show);
          _failed.remove(show.id);
        } catch (e) {
          _log.warning('Couldn’t make a ListenJar feed of show ${show.id}', e);
          _failed[show.id] = DateTime.now();
        }
      }
    }();
    _hosting = pass;
    try {
      await pass;
    } finally {
      _hosting = null;
    }
  }

  /// Makes [show]'s ListenJar feed, or finds the listener's feed of the
  /// same source, and links the two.
  Future<void> _feedFor(Podcast show) async {
    final token = CancellationToken();
    if (show.kind == PodcastKind.youtubeFeed) {
      final source = canonicalSourceUrl(show.feedUrl);
      final feed = _feeds.feeds.where((f) => f.source != null && canonicalSourceUrl(f.source!.url) == source).firstOrNull
        ?? await _feeds.add(show.feedUrl, token);
      _library.setCloudFeed(show.id, feed.id);
      _log.info('Show ${show.id} is ListenJar feed ${feed.id}');
      return;
    }
    // A podcast of the listener's own: its name, its picture and its
    // videos, oldest first so they list in the same order.
    final feed = await _feeds.create(show.title);
    _library.setCloudFeed(show.id, feed.id);
    _log.info('Show ${show.id} is ListenJar feed ${feed.id}');
    if (show.artworkUrl case final url? when url.startsWith('file:')) {
      try {
        await _feeds.setArtwork(feed, await File.fromUri(Uri.parse(url)).readAsBytes());
      } catch (e) {
        _log.warning('Couldn’t upload the artwork of show ${show.id}', e);
      }
    }
    for (final e in _library.episodes(show.id, oldestFirst: true)) {
      if (e.link case final link?) await _feeds.addVideo(feed, link, token);
    }
  }
}
