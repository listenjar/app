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
  if (!_host.hasMatch(uri.host) && !_ipv4.hasMatch(uri.host) && uri.host != 'localhost') return null;
  return uri;
}

/// A name ending in a top-level domain: two letters or more, or an
/// internationalized one, so words like `f.e.a.r` or `1.5` stay a search.
final _host = RegExp(r'^[\w-]+(\.[\w-]+)*\.([a-z]{2,}|xn--[a-z0-9-]+)$', caseSensitive: false);
final _ipv4 = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$');

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

  /// Whether [podcast], a YouTube playlist or channel on this device, gets
  /// no new videos for want of a plan; what it has still plays.
  bool paused(Podcast podcast) => podcast.kind == PodcastKind.youtubeFeed && paid() == false;

  /// The plan is known, or came back: playlists and channels on this
  /// device catch up on what they missed while paused.
  void planChanged() {
    notifyListeners();
    switch (paid()) {
      case true:
        for (final show in library.podcasts.where((p) => p.kind == PodcastKind.youtubeFeed)) {
          unawaited(refresh(show));
        }
        unawaited(_forgetCloudArtwork());
      case false:
        unawaited(_keepCloudArtwork());
      case null:
    }
  }

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
    // The feed moved, or says it did: the show may be in the library under
    // its new address.
    for (final there in [at, ?feed.newFeedUrl]) {
      if (library.podcastByUrl(there) case final moved?) {
        if (follow) library.follow(moved.id);
        return library.podcast(moved.id)!;
      }
    }
    return library.subscribe(at, feed, etag: fetch.etag, lastModified: fetch.lastModified, follow: follow);
  }

  Future<Podcast> follow(Uri url, CancellationToken token) => open(url, token, follow: true);

  void followShow(Podcast podcast) => library.follow(podcast.id);

  /// Stops following [podcast]; its downloads and the artwork kept here go
  /// with it.
  Future<void> unfollow(Podcast podcast) async {
    await _deleteArtwork(podcast);
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
    // A playlist or channel here waits for a plan ([paused]), or for the
    // account to be known.
    if (podcast.kind == PodcastKind.youtubeFeed && paid() != true) return;
    if (!podcast.refreshes || !refreshing.add(podcast.id)) return;
    notifyListeners();
    try {
      final token = _life.merge(TimeoutCancellationToken(const Duration(minutes: 2)));
      if (podcast.kind == PodcastKind.youtubeFeed) {
        await _refreshYouTube(podcast.id, parseYouTubeLink(podcast.feedUrl)!, token, named: true);
        return;
      }
      final (etag, modified) = library.validators(podcast.id);
      final fetch = await fetchFeed(_http, Uri.parse(podcast.feedUrl), token, etag: etag, lastModified: modified);
      final added = library.refreshed(podcast.id, fetch);
      if (added.isNotEmpty) await _downloads.downloadNew(added);
      // A playlist or channel ListenJar hosts still lists here first: its
      // new videos stream from YouTube until their uploads reach the feed.
      if (podcast.cloudFeedId != null && paid() == true) {
        if (parseYouTubeLink(podcast.link ?? '') case final source? when source.kind != SourceKind.video) {
          await _refreshYouTube(podcast.id, source, token, named: false);
        }
      }
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
    String? description,
    DateTime? publishedAt,
    bool follow = false,
  }) => traced(
    _log,
    'add YouTube video ${link.id}',
    () => _youtubeVideo(
      link,
      token,
      title: title,
      channel: channel,
      artworkUrl: artworkUrl,
      duration: duration,
      description: description,
      publishedAt: publishedAt,
      follow: follow,
    ),
    describe: (e) => 'episode ${e.id} of show ${e.podcastId}',
  );

  Future<PodcastEpisode> _youtubeVideo(
    YouTubeLink link,
    CancellationToken token, {
    String? title,
    String? channel,
    String? artworkUrl,
    Duration? duration,
    String? description,
    DateTime? publishedAt,
    bool follow = false,
  }) async {
    var name = title;
    var art = artworkUrl;
    var notes = description;
    var published = publishedAt;
    if (name == null) {
      final merged = _life.merge(token);
      final resolved = await (await _youtube.session(merged)).resolve(SourceRef(SourceRefKind.video, link.id, link.url), merged);
      name = resolved.title;
      art ??= resolved.artworkUrl;
      notes ??= resolved.description;
      published ??= resolved.publishedAt;
    }
    final show = library.addYouTubeVideo(
      videoId: link.id,
      title: name,
      channel: channel ?? 'YouTube',
      artworkUrl: art,
      duration: duration,
      // Unknown for a video search listed: playing it fills them in.
      description: notes ?? '',
      publishedAt: published,
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
    await _deleteArtwork(own);
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

  /// Deletes the artwork kept here for [show], if any.
  Future<void> _deleteArtwork(Podcast show) async {
    if (show.artworkUrl case final url? when url.startsWith('file:')) {
      final file = File.fromUri(Uri.parse(url));
      if (file.path.startsWith(library.directory.path) && await file.exists()) await file.delete();
    }
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
      // Followed already, here or as the feed ListenJar hosts of it: that
      // show, not a second one.
      if (library.podcastBySource(link.url) case final known?) {
        _log.info('${link.url} is show ${known.id} already');
        library.follow(known.id);
        return library.podcast(known.id)!;
      }
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

  /// Lists the videos of [link], a followed playlist, again, or a
  /// channel's newest uploads, and keeps the new ones in [podcast]. A
  /// playlist [named] by YouTube takes its name and picture from there.
  Future<void> _refreshYouTube(int podcast, YouTubeLink link, CancellationToken token, {required bool named}) async {
    final snapshot = await (await _youtube.session(token)).snapshot(
      _sourceOf(link),
      token,
      pages: link.kind == SourceKind.channel ? 1 : null,
    );
    // A channel's listing is its uploads playlist, named for that: it keeps
    // the name and picture it was followed with.
    final playlist = named && link.kind == SourceKind.playlist;
    library.youtubeFeedRefreshed(
      podcast,
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
  /// RSS address, and lets go of ones they removed. A playlist, channel or
  /// podcast of their own here that the feed was made of ([CloudShows])
  /// becomes that RSS show in place ([Library.hostedAt]); one made on
  /// another device or the website is followed. Signed out, the shows
  /// stay: their addresses still work in any podcast app. Without a plan,
  /// a playlist, channel or podcast of their own the cleanup removed stays
  /// on this device ([keepOnDevice]); one they removed here ([removed])
  /// goes.
  Future<void> followCloud(List<Feed> feeds, {Set<String> removed = const {}}) async {
    final live = {for (final f in feeds) f.id};
    for (final show in library.podcasts.where((p) => p.cloudFeedId != null && !live.contains(p.cloudFeedId))) {
      if (paid() == false && !removed.contains(show.cloudFeedId)) {
        // Never hosted: it stays the show it is.
        if (show.kind != PodcastKind.rss) {
          library.setCloudFeed(show.id, null);
          continue;
        }
        if (await keepOnDevice(show)) continue;
      }
      await unfollow(show);
    }
    if (paid() == false) unawaited(_keepCloudArtwork());
    for (final feed in feeds) {
      final rss = feed.rssUrl;
      if (rss == null) continue;
      final source = library.podcasts.where((p) => p.cloudFeedId == feed.id && p.kind != PodcastKind.rss).firstOrNull;
      if (source != null && library.hostedAt(source.id, rss)) {
        _log.info('Show ${source.id} is ListenJar feed ${feed.id} now');
        await refresh(library.podcast(source.id)!);
        continue;
      }
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

  /// The account was deleted, and its feeds with it: lets go of every
  /// ListenJar Cloud show, its downloads and the artwork kept for it.
  Future<void> forgetCloud() async {
    for (final show in library.podcasts.where((p) => p.cloudFeedId != null).toList()) {
      await unfollow(show);
    }
    await _forgetCloudArtwork();
  }

  /// Keeps [show], a ListenJar Cloud playlist, channel or podcast of the
  /// listener's own whose feed is gone, on this device, with the artwork
  /// [_keepCloudArtwork] kept; false for a single video, which goes as on
  /// the free plan.
  Future<bool> keepOnDevice(Podcast show) async {
    final feedId = show.cloudFeedId!;
    final link = parseYouTubeLink(show.link ?? '');
    if (link?.kind == SourceKind.video) return false;
    // A playlist or channel, or with no YouTube link a podcast of their own.
    final source = link?.url;
    final kept = _cloudArtwork(feedId);
    String? artwork;
    if (await kept.exists()) {
      final dir = Directory('${library.directory.path}/artwork');
      final file = await kept.rename('${dir.path}/own-${show.id}-${DateTime.now().millisecondsSinceEpoch}.jpg');
      artwork = file.uri.toString();
    }
    if (library.keepOnDevice(show.id, source: source, artworkUrl: artwork)) {
      _log.info('Kept ListenJar feed $feedId on this device as show ${show.id}');
      return true;
    }
    if (artwork != null) await File.fromUri(Uri.parse(artwork)).delete();
    return false;
  }

  /// Where the artwork of the ListenJar feed [feedId] is kept while there's
  /// no plan: the cleanup deletes the feed's own with it.
  File _cloudArtwork(String feedId) => File('${library.directory.path}/artwork/cloud-$feedId.jpg');

  /// Keeps the artwork of each ListenJar playlist, channel and podcast of
  /// the listener's own here, for [keepOnDevice].
  Future<void> _keepCloudArtwork() async {
    for (final show in library.podcasts) {
      final feedId = show.cloudFeedId;
      if (feedId == null || show.artworkUrl == null) continue;
      if (parseYouTubeLink(show.link ?? '')?.kind == SourceKind.video) continue;
      final file = _cloudArtwork(feedId);
      if (await file.exists()) continue;
      final picture = await artworkBytes(show.artworkUrl);
      if (picture == null) continue;
      await file.parent.create(recursive: true);
      await file.writeAsBytes(picture, flush: true);
    }
  }

  /// On a plan again: the feeds stay, and so does their artwork.
  Future<void> _forgetCloudArtwork() async {
    final dir = Directory('${library.directory.path}/artwork');
    if (!await dir.exists()) return;
    await for (final f in dir.list()) {
      if (f is File && f.uri.pathSegments.last.startsWith('cloud-')) await f.delete();
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
