// Following shows and keeping them fresh: opens a feed from search or a
// pasted link, follows and unfollows, refreshes every followed feed (four
// at a time, about hourly and at launch, see schedule.dart), downloads new
// episodes of shows set to, keeps YouTube videos as shows of one episode,
// imports and exports OPML, and follows the signed-in listener's own
// ListenJar feeds, so they play here like any podcast. The library
// (library.dart) holds the results. No widgets here.
import 'dart:async';
import 'dart:io';

import 'package:cancellation_token/cancellation_token.dart';
import 'package:flutter/foundation.dart';
import 'package:xml/xml.dart';

import 'backend/api.dart' show Feed;
import 'downloads.dart';
import 'library.dart';
import 'links.dart';
import 'log.dart';
import 'rss.dart';
import 'youtube.dart';

final _log = Logger('podcasts');

const _refreshWorkers = 4;

/// A refresh this recent is fresh enough for a launch or a resume.
const _fresh = Duration(minutes: 15);

/// Podcast apps' own link schemes for a feed, and a bare address, made into
/// the feed's URL the way AntennaPod's `UrlChecker.prepareUrl` does: the
/// address as given, `http://` when it names no scheme. Also Apple's
/// `podcast://`. Null when [input] isn't a link at all.
Uri? feedUrl(String input) {
  final text = _prepare(input.trim());
  if (text.contains(' ')) return null;
  final uri = Uri.tryParse(text);
  if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https') || uri.host.isEmpty) return null;
  if (!RegExp(r'^[\w-]+(\.[\w-]+)+$').hasMatch(uri.host) && uri.host != 'localhost') return null;
  return uri;
}

String _prepare(String url) {
  final lower = url.toLowerCase();
  for (final prefix in const ['feed://', 'pcast://', 'pcast:', 'itpc://', 'podcast://', 'antennapod-subscribe://']) {
    if (lower.startsWith(prefix)) return _prepare(url.substring(prefix.length));
  }
  // feed:https://… names the scheme after it.
  if (lower.startsWith('feed:')) return _prepare(url.substring('feed:'.length));
  if (lower.contains('antennapod.org/deeplink/subscribe')) {
    if (Uri.tryParse(url)?.queryParameters['url'] case final inner?) return _prepare(inner);
  }
  if (lower.contains('subscribeonandroid.com/')) return _prepare(url.replaceFirst(RegExp(r'(www\.)?subscribeonandroid\.com/', caseSensitive: false), ''));
  if (!(lower.startsWith('http://') || lower.startsWith('https://'))) return 'http://$url';
  return url;
}

final class Podcasts extends ChangeNotifier {
  Podcasts(this.library, this._downloads, this._youtube);

  final Library library;
  final Downloads _downloads;
  final YouTubeService _youtube;
  final _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 30)
    ..userAgent = userAgent;
  final _life = CancellationToken();

  /// Shows being refreshed now.
  final refreshing = <int>{};
  bool get refreshingAll => _all != null;
  Future<void>? _all;
  DateTime? _lastAll;

  /// Opens the feed at [url] to look at: the show in the library, or added
  /// to it unfollowed, with its episodes.
  Future<Podcast> open(Uri url, CancellationToken token, {bool follow = false}) async {
    final known = library.podcastByUrl(url.toString());
    if (known != null) {
      if (follow) library.follow(known.id);
      return library.podcast(known.id)!;
    }
    final fetch = await fetchFeed(_http, url, _life.merge(token));
    final feed = fetch.feed!;
    final at = fetch.url.toString();
    // The feed moved: the show may be in the library under its new address.
    if (library.podcastByUrl(at) case final moved?) {
      if (follow) library.follow(moved.id);
      return library.podcast(moved.id)!;
    }
    return library.subscribe(at, feed, etag: fetch.etag, lastModified: fetch.lastModified, follow: follow);
  }

  Future<Podcast> follow(Uri url, CancellationToken token) => open(url, token, follow: true);

  void followShow(Podcast podcast) => library.follow(podcast.id);

  /// Stops following [podcast]; its downloads go with it.
  Future<void> unfollow(Podcast podcast) async {
    for (final e in library.episodes(podcast.id, filter: EpisodeFilter.downloaded)) {
      await _downloads.delete(e);
    }
    await _downloads.deleteFiles(library.unsubscribe(podcast.id));
  }

  /// Refreshes every followed feed, unless they were refreshed in the last
  /// few minutes and [force] isn't set; one pass at a time.
  Future<void> refreshAll({bool force = false}) {
    if (_all case final running?) return running;
    if (!force && _lastAll != null && DateTime.now().difference(_lastAll!) < _fresh) return Future.value();
    final pass = _refreshAll().whenComplete(() {
      _all = null;
      _lastAll = DateTime.now();
      notifyListeners();
    });
    _all = pass;
    notifyListeners();
    return pass;
  }

  Future<void> _refreshAll() async {
    final shows = library.podcasts.where((p) => p.kind == PodcastKind.rss).toList();
    var next = 0;
    Future<void> worker() async {
      while (next < shows.length && !_life.isCancelled) {
        await refresh(shows[next++]);
      }
    }

    await Future.wait([for (var i = 0; i < _refreshWorkers; i++) worker()]);
    library.forgetUnfollowed();
  }

  /// Refreshes [podcast]'s feed and downloads its new episodes if it's set
  /// to. Failures are kept on the show, not thrown.
  Future<void> refresh(Podcast podcast) async {
    if (podcast.kind != PodcastKind.rss || !refreshing.add(podcast.id)) return;
    notifyListeners();
    try {
      final (etag, modified) = library.validators(podcast.id);
      final token = _life.merge(TimeoutCancellationToken(const Duration(minutes: 2)));
      final fetch = await fetchFeed(_http, Uri.parse(podcast.feedUrl), token, etag: etag, lastModified: modified);
      final added = library.refreshed(podcast.id, fetch);
      if (added.isNotEmpty) await _downloads.downloadNew(added);
    } on CancelledException {
      if (!_life.isCancelled) library.refreshFailed(podcast.id, 'The feed took too long to answer');
    } catch (e) {
      library.refreshFailed(podcast.id, e);
    } finally {
      refreshing.remove(podcast.id);
      notifyListeners();
    }
  }

  // YouTube videos.

  /// The YouTube video [link] as a show of one episode, in the library if
  /// [follow]; looks its title up when [title] isn't known.
  Future<PodcastEpisode> youtubeVideo(
    YouTubeLink link,
    CancellationToken token, {
    String? title,
    String? channel,
    String? artworkUrl,
    Duration? duration,
    bool follow = false,
  }) => traced(
    _log,
    'add YouTube video ${link.id}',
    () => _youtubeVideo(link, token, title: title, channel: channel, artworkUrl: artworkUrl, duration: duration, follow: follow),
    describe: (e) => 'episode ${e.id} of show ${e.podcastId}',
  );

  Future<PodcastEpisode> _youtubeVideo(
    YouTubeLink link,
    CancellationToken token, {
    String? title,
    String? channel,
    String? artworkUrl,
    Duration? duration,
    bool follow = false,
  }) async {
    var name = title;
    var art = artworkUrl;
    if (name == null) {
      final merged = _life.merge(token);
      final resolved = await (await _youtube.session(merged)).resolve(SourceRef(SourceRefKind.video, link.id, link.url), merged);
      name = resolved.title;
      art ??= resolved.artworkUrl;
    }
    final show = library.addYouTubeVideo(
      videoId: link.id,
      title: name,
      channel: channel ?? 'YouTube',
      artworkUrl: art,
      duration: duration,
      description: '',
      publishedAt: null,
      follow: follow,
    );
    return library.episodes(show.id).first;
  }

  // The listener's ListenJar feeds.

  /// Follows each of the signed-in listener's ListenJar feeds once it has an
  /// RSS address, and lets go of ones they removed. Signed out, the shows
  /// stay: their addresses still work in any podcast app.
  Future<void> followCloud(List<Feed> feeds) async {
    final live = {for (final f in feeds) f.id};
    for (final show in library.podcasts.where((p) => p.cloudFeedId != null && !live.contains(p.cloudFeedId))) {
      await unfollow(show);
    }
    for (final feed in feeds) {
      final rss = feed.rssUrl;
      if (rss == null) continue;
      final known = library.podcastByUrl(rss);
      if (known != null) {
        if (known.cloudFeedId != feed.id) library.setCloudFeed(known.id, feed.id);
        if (!known.followed) library.follow(known.id);
        continue;
      }
      try {
        final fetch = await fetchFeed(_http, Uri.parse(rss), _life);
        library.subscribe(rss, fetch.feed!, etag: fetch.etag, lastModified: fetch.lastModified, cloudFeedId: feed.id);
      } catch (e) {
        _log.warning('Couldn’t follow ListenJar feed ${feed.id}', e);
      }
    }
  }

  /// A ListenJar feed published new episodes: refresh its show now rather
  /// than on the next pass.
  Future<void> cloudPublished(String feedId) async {
    final show = library.podcasts.where((p) => p.cloudFeedId == feedId).firstOrNull;
    if (show != null) await refresh(show);
  }

  // OPML.

  /// Every followed feed as OPML, the format every podcast app imports.
  String exportOpml() {
    final builder = XmlBuilder()..processing('xml', 'version="1.0" encoding="UTF-8"');
    builder.element('opml', attributes: {'version': '2.0'}, nest: () {
      builder.element('head', nest: () {
        builder.element('title', nest: 'ListenJar subscriptions');
        builder.element('dateCreated', nest: HttpDate.format(DateTime.now()));
      });
      builder.element('body', nest: () {
        for (final p in library.podcasts.where((p) => p.kind == PodcastKind.rss)) {
          builder.element('outline', attributes: {
            'type': 'rss',
            'text': p.title,
            'title': p.title,
            'xmlUrl': p.feedUrl,
            if (p.link != null) 'htmlUrl': p.link!,
          });
        }
      });
    });
    return builder.buildDocument().toXmlString(pretty: true);
  }

  /// Follows every feed in [opml]; returns how many it followed and how
  /// many failed.
  Future<(int, int)> importOpml(String opml) async {
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(opml);
    } on XmlException {
      throw const NotAFeed('That isn’t an OPML file');
    }
    final urls = {
      for (final outline in doc.findAllElements('outline'))
        if (outline.getAttribute('xmlUrl') case final url? when feedUrl(url) != null) feedUrl(url)!,
    }.toList();
    var followed = 0;
    var failed = 0;
    var next = 0;
    Future<void> worker() async {
      while (next < urls.length && !_life.isCancelled) {
        final url = urls[next++];
        try {
          await follow(url, TimeoutCancellationToken(const Duration(minutes: 1)));
          followed++;
        } catch (_) {
          failed++;
        }
      }
    }

    await Future.wait([for (var i = 0; i < _refreshWorkers; i++) worker()]);
    return (followed, failed);
  }

  @override
  void dispose() {
    _life.cancel();
    _http.close(force: true);
    super.dispose();
  }
}
