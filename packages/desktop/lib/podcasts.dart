// Following shows and keeping them fresh: opens a feed from search or a
// pasted link, follows and unfollows, refreshes every followed feed (four
// at a time, about hourly and at launch, see schedule.dart), downloads new
// episodes of shows set to, keeps YouTube videos as shows of one episode,
// imports and exports OPML, and follows the signed-in listener's own
// ListenJar feeds, so they play here like any podcast. The library
// (library.dart) holds the results. No widgets here.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cancellation_token/cancellation_token.dart';
import 'package:flutter/foundation.dart';
import 'package:xml/xml.dart';

import 'backend/api.dart' show Feed, SourceKind;
import 'artwork.dart';
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

  /// Whether the listener has a paid plan, which following YouTube
  /// playlists and channels takes, on this device as in the Cloud; null
  /// while the account isn't known yet. Set where the account is.
  bool? Function() paid = () => null;
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
    final shows = library.podcasts.where((p) => p.refreshes).toList();
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
    if (!podcast.refreshes || !refreshing.add(podcast.id)) return;
    notifyListeners();
    try {
      if (podcast.kind == PodcastKind.youtubeFeed) {
        switch (paid()) {
          case null:
            return;
          case false:
            library.refreshFailed(podcast.id, 'Following YouTube playlists and channels takes a plan');
            return;
          case true:
        }
        await _refreshYouTube(podcast, _life.merge(TimeoutCancellationToken(const Duration(minutes: 2))));
        return;
      }
      final (etag, modified) = library.validators(podcast.id);
      final token = _life.merge(TimeoutCancellationToken(const Duration(minutes: 2)));
      final fetch = await fetchFeed(_http, Uri.parse(podcast.feedUrl), token, etag: etag, lastModified: modified);
      final added = library.refreshed(podcast.id, fetch);
      if (podcast.cloudFeedId case final feed?) library.applyCarried(podcast.id, feed);
      if (added.isNotEmpty) await _downloads.downloadNew(added);
    } on CancelledException {
      if (!_life.isCancelled) {
        library.refreshFailed(podcast.id, podcast.kind == PodcastKind.rss ? 'The feed took too long to answer' : 'YouTube took too long to answer');
      }
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

  // Podcasts of the listener's own, on this device.

  /// Adds the YouTube video [link] to [own], a podcast of the listener's
  /// own on this device, looking its title up unless given. Null when it's
  /// already there.
  Future<PodcastEpisode?> addToOwn(Podcast own, YouTubeLink link, CancellationToken token, {String? title, Duration? duration}) async {
    if (paid() != true) throw StateError('Podcasts of your own take a plan');
    var name = title;
    if (name == null) {
      final merged = _life.merge(token);
      name = (await (await _youtube.session(merged)).resolve(SourceRef(SourceRefKind.video, link.id, link.url), merged)).title;
    }
    _log.info('Adding video ${link.id} to own podcast ${own.id}');
    return library.addOwnVideo(own.id, videoId: link.id, title: name, duration: duration);
  }

  /// Makes [picture] the artwork of [own], a podcast of the listener's own
  /// on this device: squared, as for podcast apps, and kept beside the
  /// library.
  Future<void> setOwnArtwork(Podcast own, Uint8List picture) async {
    final dir = Directory('${library.directory.path}/artwork');
    await dir.create(recursive: true);
    // A new name each time, so the old picture isn't shown from cache.
    final file = File('${dir.path}/own-${own.id}-${DateTime.now().millisecondsSinceEpoch}.jpg');
    await file.writeAsBytes(await podcastArtwork(picture));
    await _deleteOwnArtwork(own);
    library.setArtwork(own.id, file.uri.toString());
  }

  /// The artwork at [url], a picture on the web or one kept here.
  Future<Uint8List?> artworkBytes(String? url) async {
    final uri = url == null ? null : Uri.tryParse(url);
    if (uri == null) return null;
    try {
      if (uri.isScheme('file')) return await File.fromUri(uri).readAsBytes();
      final request = await _http.getUrl(uri);
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return null;
      }
      final builder = BytesBuilder(copy: false);
      await response.forEach(builder.add);
      return builder.takeBytes();
    } catch (e) {
      _log.warning('Couldn’t read artwork $url', e);
      return null;
    }
  }

  Future<void> _deleteOwnArtwork(Podcast own) async {
    if (own.artworkUrl case final url? when url.startsWith('file:')) {
      final file = File.fromUri(Uri.parse(url));
      if (file.path.startsWith(library.directory.path) && await file.exists()) await file.delete();
    }
  }

  /// Deletes [own], a podcast of the listener's own on this device.
  Future<void> deleteOwn(Podcast own) async {
    await _deleteOwnArtwork(own);
    await unfollow(own);
  }

  // YouTube playlists and channels, on this device.

  /// Follows the YouTube playlist or channel [link] on this device: its
  /// videos list as episodes and stream from YouTube, with no upload and no
  /// ListenJar feed. The whole listing comes now; refreshes add new videos.
  Future<Podcast> followYouTube(YouTubeLink link, CancellationToken token) => traced<Podcast>(
    _log,
    'follow YouTube ${link.kind.name} ${link.id}',
    () async {
      if (paid() != true) throw StateError('Following YouTube playlists and channels takes a plan');
      final merged = _life.merge(token);
      final youtube = await _youtube.session(merged);
      // A channel lists by its UC… id, not a @handle, and is named for
      // itself, not its uploads playlist.
      final channel = link.kind == SourceKind.channel ? await youtube.resolve(_sourceOf(link), merged) : null;
      if (channel != null) link = parseYouTubeLink(channel.url) ?? (throw StateError('YouTube gave no channel for ${link.url}'));
      final snapshot = await youtube.snapshot(_sourceOf(link), merged);
      final title = channel?.title ?? snapshot.title;
      final artwork = channel?.artworkUrl ?? snapshot.artworkUrl;
      final show = library.followYouTubeFeed(
        url: link.url,
        title: title,
        author: channel?.title ?? kindLabel(link.kind),
        artworkUrl: artwork,
      );
      library.youtubeFeedRefreshed(show.id, title: title, artworkUrl: artwork, videos: _videos(snapshot), dated: false);
      return library.podcast(show.id)!;
    },
    describe: (p) => 'show ${p.id}',
  );

  /// Lists a followed playlist's videos again, or a channel's newest
  /// uploads, and keeps the new ones.
  Future<void> _refreshYouTube(Podcast podcast, CancellationToken token) async {
    final link = parseYouTubeLink(podcast.feedUrl) ?? (throw StateError('Not a YouTube link: ${podcast.feedUrl}'));
    final snapshot = await (await _youtube.session(token)).snapshot(
      _sourceOf(link),
      token,
      pages: link.kind == SourceKind.channel ? 1 : null,
    );
    // A channel's listing is its uploads playlist, named for that: it keeps
    // the name and picture it was followed with.
    final playlist = link.kind == SourceKind.playlist;
    library.youtubeFeedRefreshed(
      podcast.id,
      title: playlist ? snapshot.title : null,
      artworkUrl: playlist ? snapshot.artworkUrl : null,
      videos: _videos(snapshot),
      dated: true,
    );
  }

  static SourceRef _sourceOf(YouTubeLink link) => SourceRef(switch (link.kind) {
    SourceKind.video => SourceRefKind.video,
    SourceKind.playlist => SourceRefKind.playlist,
    SourceKind.channel => SourceRefKind.channel,
  }, link.id, link.url);

  static List<YouTubeVideo> _videos(Snapshot snapshot) => [
    for (final v in snapshot.videos) (id: v.id, title: v.title, seconds: v.durationSeconds),
  ];

  // The listener's ListenJar feeds.

  /// Follows each of the signed-in listener's ListenJar feeds once it has an
  /// RSS address, and lets go of ones they removed. Signed out, the shows
  /// stay: their addresses still work in any podcast app.
  Future<void> followCloud(List<Feed> feeds) async {
    final live = {for (final f in feeds) f.id};
    library.forgetCarried(live);
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
        final show = library.subscribe(rss, fetch.feed!, etag: fetch.etag, lastModified: fetch.lastModified, cloudFeedId: feed.id);
        library.applyCarried(show.id, feed.id);
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
