// What ListenJar asks of YouTube, through youtubei (YouTube.js in QuickJS):
// search, what a video, playlist or channel holds, and a downloadable audio
// stream for a video. [YouTubeService] keeps one runtime for the app's whole
// life; the link field's search, adding and the sync engine all share it.
// The sync side is ported from the Listenbox client's Go sync engine
// (crates/sync-engine/innertube.go): the same playability rules, the same
// client fallbacks, the same request budget, but audio only, since a
// ListenJar feed is a podcast.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cancellation_token/cancellation_token.dart';
import 'package:path_provider/path_provider.dart';
import 'package:youtubei/misc.dart' as Misc; // ignore: library_prefixes
import 'package:youtubei/youtubei.dart';
import 'package:youtubei/yt.dart' as YT; // ignore: library_prefixes
import 'package:youtubei/yt_nodes.dart' as YTNodes; // ignore: library_prefixes

import 'chapters.dart';
import 'log.dart';
import 'youtubejs_updates.dart';

final _log = Logger('youtube');
final _httpLog = Logger('youtube.http');
final _jsLog = Logger('youtube.js');

void _logJs(String level, String message) => _jsLog.log(switch (level) {
  'error' => Level.SEVERE,
  'warning' => Level.WARNING,
  'info' => Level.INFO,
  _ => Level.FINE,
}, message);

/// A video in a source, as the playlist listed it.
final class Video {
  const Video({required this.id, required this.title, this.durationSeconds});
  final String id;
  final String title;
  final int? durationSeconds;
}

/// Everything a source holds right now.
final class Snapshot {
  const Snapshot({required this.title, required this.artworkUrl, required this.videos, required this.canRemove});
  final String title;
  final String? artworkUrl;
  final List<Video> videos;

  /// Whether a video missing from [videos] is gone from the source. False
  /// when YouTube warned that it hid some (unavailable videos), and for a
  /// single video, which stays once it is in the feed.
  final bool canRemove;
}

/// What the listener added, resolved: its canonical URL and how it looks.
final class Resolved {
  const Resolved({required this.url, required this.title, required this.artworkUrl, this.description, this.publishedAt});
  final String url;
  final String title;
  final String? artworkUrl;

  /// A video's description and publication; null for a playlist or channel.
  final String? description;
  final DateTime? publishedAt;
}

/// Something search found that the listener can add: a video, a playlist or
/// a channel, with its canonical link and what to show for it.
final class SearchResult {
  const SearchResult({
    required this.kind,
    required this.id,
    required this.url,
    required this.title,
    required this.details,
    required this.thumbnailUrl,
    this.description,
    this.publishedAt,
  });
  final SourceRefKind kind;
  final String id;
  final String url;
  final String title;

  /// Who made it and how big it is: `Cercle · 2:13:48 · 69M views`.
  final List<String> details;
  final String? thumbnailUrl;

  /// A pasted video's description and publication, which its lookup reads;
  /// null for what search lists.
  final String? description;
  final DateTime? publishedAt;
}

/// A stream to download, with what to send YouTube's media servers.
final class MediaStream {
  const MediaStream({required this.url, required this.userAgent, required this.identity, required this.format});
  final Uri url;
  final String userAgent;

  /// Which rendition this is; a saved partial download resumes only into the
  /// same one.
  final String identity;
  final Misc.Format format;
}

/// A video ready to download: its metadata and its audio stream.
final class Media {
  Media._({
    required this.id,
    required this.title,
    required this.description,
    required this.publishedAt,
    required this.durationSeconds,
    required this.contentType,
    required this.audio,
    required this.chapters,
    required this._playback,
    required this._client,
    required this._fallback,
  });

  final String id;
  final String title;
  final String description;
  final DateTime publishedAt;
  final int? durationSeconds;

  /// `audio/mp4` (AAC, preferred) or `audio/webm` (Opus).
  final String contentType;
  MediaStream audio;

  /// The video's chapters, when [YouTube.media] was asked for them.
  final List<Chapter>? chapters;
  YT.VideoInfo _playback;
  InnerTubeClient _client;
  final List<InnerTubeClient> _fallback;
}

/// YouTube says this computer is asking too often; nothing more will work
/// until a later sync.
final class RateLimited implements Exception {
  const RateLimited(this.reason);
  final String reason;
  @override
  String toString() => 'YouTube is rate-limiting this computer: $reason';
}

/// YouTube's media server refused a stream (HTTP 403): try another.
final class MediaUnavailable implements Exception {
  const MediaUnavailable();
  @override
  String toString() => 'YouTube refused the media stream';
}

/// The video needs a signed-in YouTube account.
final class SignInRequired implements Exception {
  const SignInRequired(this.reason);
  final String reason;
  @override
  String toString() => 'YouTube wants a signed-in account: $reason';
}

const _liveReason = 'Live or upcoming video; sync after it has finished';
const _rateLimitNotice = "This content isn't available, try again later";
const _maximumPlaylistPages = 10000;

/// The client that replaces a playback client whose player response says
/// the video is unplayable.
const _unplayableAlternative = {InnerTubeClient.WEB_EMBEDDED: InnerTubeClient.WEB_CREATOR, InnerTubeClient.VISIONOS: InnerTubeClient.TV};

/// YouTube for the app's whole life: one session, started on first use (or
/// by [warmUp] at launch) and shared by everything that asks YouTube. A
/// failed start is tried again on the next call; [restart] replaces a
/// rate-limited session. Each session runs the newest YouTube.js the app has
/// (youtubejs_updates.dart); [watchReleases] moves to newer ones as the fork
/// releases them.
final class YouTubeService {
  final _http = HttpClient()..userAgent = null;
  final _life = CancellationToken();
  final bundles = YouTubeJsUpdates();
  YouTube? _session;
  Future<YouTube>? _starting;

  /// Starts the session now, so the first search doesn't wait for it.
  void warmUp() => unawaited(session(_life).then<void>((_) {}, onError: (_) {}));

  /// Checks for YouTube.js releases every few seconds; once one verifies,
  /// the next call starts a session with it.
  void watchReleases() => bundles.watch((_) async {
    // A session starting now runs the bundle before this one.
    await _starting?.then<void>((_) {}, onError: (_) {});
    await restart();
  });

  Future<YouTube> session(CancellationToken token) async {
    if (_session case final session?) return session;
    final starting = _starting ??= traced(_log, 'start session', _start)
      .then((session) => _session = session)
      .whenComplete(() => _starting = null);
    return starting.asCancellable(token);
  }

  /// A session with the newest bundle, else, should that one not evaluate,
  /// the built-in one.
  Future<YouTube> _start() async {
    final release = await bundles.bundle();
    if (release == null) return YouTube.start(_http, _life);
    try {
      return await YouTube.start(_http, _life, bundle: release.source);
    } on BundleError catch (e) {
      await bundles.reject(release, e);
      return YouTube.start(_http, _life);
    }
  }

  /// Ends the session; the next call starts afresh. Calls already accepted
  /// finish first.
  Future<void> restart() async {
    final session = _session;
    _session = null;
    await session?.close();
  }

  Future<void> close() async {
    _life.cancel();
    bundles.close();
    await restart().catchError((_) {});
    _http.close(force: true);
  }
}

/// One YouTube session: one YouTube.js runtime, reused for every request.
/// The continuation tokens browsed in the current playlist listing; each
/// listing starts it afresh, since a refresh pages through the same tokens.
final _continuations = <String>{};

final class YouTube {
  YouTube._(this._innertube);

  final Innertube _innertube;

  /// Without a signed-in cookie, visionOS gives plain, unthrottled streams.
  final _playbackClient = InnerTubeClient.VISIONOS;

  /// The first rate limit: after it, no more player requests this session.
  RateLimited? _limited;

  /// Starts YouTube.js and opens a session. [http] carries every request.
  static Future<YouTube> start(HttpClient http, CancellationToken token, {Uint8List? bundle}) async {
    final fetch = httpClientFetch(http);
    final innertube = await Innertube.create(
      bundle: bundle,
      lang: 'en',
      location: 'US',
      timezone: 'UTC',
      fail_fast: true,
      retrieve_player: true,
      // The session data and the parsed player, kept as YouTube.js keeps them.
      cache: UniversalCache(true, '${(await getApplicationCacheDirectory()).path}/youtube'),
      log: _logJs,
      fetch: (request, token) {
        final url = Uri.parse(request.url);
        if (!_allowedHost(url)) throw StateError('unexpected YouTube API host ${url.host}');
        final body = request.body;
        if (url.path.contains('/youtubei/v1/browse') && body != null) {
          final continuation = _jsonMap(body)['continuation'];
          // A repeated token would page forever.
          if (continuation is String && !_continuations.add(continuation)) throw StateError('repeated YouTube continuation');
        }
        return traced(
          _httpLog,
          '${request.method} ${url.host}${url.path}',
          () => fetch(request, token),
          describe: (r) => '${r.status}, ${r.body.length} bytes',
        );
      },
      token: token,
    );
    return YouTube._(innertube);
  }

  Future<void> close() => _innertube.close();

  /// The title and artwork of what the listener added, and for a channel
  /// its `/channel/UC…` URL.
  Future<Resolved> resolve(SourceRef source, CancellationToken token) =>
    traced(_log, 'resolve ${source.kind.name} ${source.id}', () => _resolve(source, token), describe: (r) => r.title);

  Future<Resolved> _resolve(SourceRef source, CancellationToken token) async {
    final id = source.id;
    switch (source.kind) {
      case SourceRefKind.video:
        final (info, reason) = await _playerInfo(id, InnerTubeClient.WEB, token);
        if (reason != null) throw StateError(reason);
        final title = info!.basic_info.title?.trim() ?? '';
        return Resolved(
          url: source.url,
          title: title.isEmpty ? 'YouTube video $id' : title,
          artworkUrl: _thumbnail(info.basic_info.thumbnail),
          description: info.basic_info.short_description ?? '',
          publishedAt: _publication(info, channel: false),
        );
      case SourceRefKind.playlist:
        final page = await _playlistHead(id, token);
        return Resolved(url: source.url, title: page.info.title ?? '', artworkUrl: _thumbnail(page.info.thumbnails));
      case SourceRefKind.channel:
        // A handle, /c/ or /user/ link resolves to the channel's id first.
        var channelId = _channelUrl.firstMatch(source.url)?[1];
        if (channelId == null) {
          final endpoint = await _innertube.resolveURL(source.url, token: token);
          channelId = switch (endpoint.payload) {
            {'browseId': final String id} when id.startsWith('UC') => id,
            _ => throw StateError('Not a YouTube channel: ${source.url}'),
          };
        }
        final metadata = (await _innertube.getChannel(channelId, token: token)).metadata;
        final resolved = (metadata.external_id ?? '').isNotEmpty ? metadata.external_id! : channelId;
        if (!_channelId.hasMatch(resolved)) throw StateError('YouTube returned no channel for ${source.url}');
        final title = metadata.title?.trim() ?? '';
        return Resolved(
          url: 'https://www.youtube.com/channel/$resolved',
          title: title.isEmpty ? resolved : title,
          artworkUrl: _thumbnail(metadata.avatar.isNotEmpty ? metadata.avatar : metadata.thumbnail),
        );
    }
  }

  /// A pasted link as search would list it: its title, thumbnail and, for a
  /// video, the channel, length and views.
  Future<SearchResult> lookup(SourceRef source, CancellationToken token) async {
    if (source.kind != SourceRefKind.video) {
      final resolved = await resolve(source, token);
      final id = source.kind == SourceRefKind.channel ? Uri.parse(resolved.url).pathSegments.last : source.id;
      return SearchResult(kind: source.kind, id: id, url: resolved.url, title: resolved.title, details: const [], thumbnailUrl: resolved.artworkUrl);
    }
    final (info, reason) = await traced(_log, 'lookup video ${source.id}', () => _playerInfo(source.id, InnerTubeClient.WEB, token));
    if (info == null) throw StateError(reason ?? 'YouTube returned nothing for ${source.id}');
    final basic = info.basic_info;
    final title = basic.title?.trim() ?? '';
    final author = basic.author?.trim() ?? '';
    final seconds = _seconds(basic.duration);
    return SearchResult(
      kind: SourceRefKind.video,
      id: source.id,
      url: 'https://www.youtube.com/watch?v=${source.id}',
      title: title.isEmpty ? 'YouTube video ${source.id}' : title,
      details: [
        if (author.isNotEmpty) author,
        if (seconds != null && seconds > 0) _clock(seconds),
        if (basic.view_count case final views?) '${_compact(views)} views',
        ?reason,
      ],
      thumbnailUrl: _thumbnail(basic.thumbnail),
      description: basic.short_description ?? '',
      publishedAt: _publication(info, channel: false),
    );
  }

  /// What YouTube's search finds for [query] that can become a feed, in
  /// YouTube's order: no Shorts shelves, live streams or mixes.
  Future<List<SearchResult>> search(String query, CancellationToken token) async {
    final search = await traced(_log, 'search “$query”', () => _innertube.search(query, token: token), describe: (s) => '${s.results.length} items');
    final results = <SearchResult>[];
    final seen = <String>{};
    for (final item in search.results) {
      if (_searchResult(item) case final result? when seen.add(result.url)) results.add(result);
    }
    return results;
  }

  /// What the source holds: every video of a playlist or a channel's uploads,
  /// or the one video. [pages] stops after that many pages of a playlist:
  /// enough for a channel's newest uploads, which list first.
  Future<Snapshot> snapshot(SourceRef source, CancellationToken token, {int? pages}) => switch (source.kind) {
    SourceRefKind.video => _videoSnapshot(source.id, token),
    SourceRefKind.playlist => _playlistSnapshot(source.id, token, pages: pages),
    // A channel's uploads are the playlist UU + the rest of its UC id.
    SourceRefKind.channel => _playlistSnapshot('UU${source.id.substring(2)}', token, pages: pages),
  };

  Future<Snapshot> _videoSnapshot(String id, CancellationToken token) async {
    final (info, _) = await _playerInfo(id, InnerTubeClient.WEB, token);
    final title = info?.basic_info.title?.trim() ?? '';
    return Snapshot(
      title: title.isEmpty ? 'YouTube video $id' : title,
      artworkUrl: _thumbnail(info?.basic_info.thumbnail ?? const []),
      videos: [Video(id: id, title: title.isEmpty ? 'YouTube video $id' : title, durationSeconds: _seconds(info?.basic_info.duration))],
      canRemove: false,
    );
  }

  /// The first page, with the videos YouTube marks unavailable listed
  /// rather than hidden (`wgYCCAA=`): a video missing from the listing is
  /// gone from the playlist.
  Future<YT.Playlist> _playlistHead(String id, CancellationToken token) async {
    final response = await _innertube.actions.execute('/browse', {'browseId': 'VL$id', 'params': 'wgYCCAA='}, token: token);
    final page = await YT.Playlist.create(_innertube.actions, response, token: token);
    _validPlaylist(page);
    if ((page.info.title ?? '').trim().isEmpty) throw StateError('YouTube playlist missing title');
    return page;
  }

  Future<Snapshot> _playlistSnapshot(String id, CancellationToken token, {int? pages}) async {
    _continuations.clear();
    var page = await _playlistHead(id, token);
    final title = page.info.title ?? '';
    final artwork = _thumbnail(page.info.thumbnails);
    final videos = <Video>[];
    final seen = <String>{};
    var canRemove = true;
    for (var read = 1; ; read++) {
      if (read > _maximumPlaylistPages) throw StateError('YouTube playlist exceeds the scan limit');
      _validPlaylist(page);
      if (page.page.alerts.isNotEmpty) canRemove = false;
      for (final item in page.items) {
        final video = _playlistVideo(item);
        if (seen.add(video.id)) videos.add(video);
      }
      if (!page.has_continuation) break;
      if (pages != null && read >= pages) {
        // Not the whole listing: nothing missing from it is gone.
        canRemove = false;
        break;
      }
      page = await page.getContinuation(token: token);
    }
    return Snapshot(title: title, artworkUrl: artwork, videos: videos, canRemove: canRemove);
  }

  /// The video's metadata and audio stream, or the reason it can't be had
  /// (private, removed, live). Throws [RateLimited] once YouTube throttles.
  /// With [chapters], the metadata comes with the video's next response, in
  /// parallel, for its [Media.chapters].
  Future<(Media?, String?)> media(String id, {required bool channel, bool chapters = false, required CancellationToken token}) async {
    final (info, reason) = await _playerInfo(id, InnerTubeClient.WEB, token, next: chapters);
    if (reason != null) return (null, reason);
    final metadata = info!;
    if (metadata.basic_info.is_live == true || metadata.basic_info.is_upcoming == true) return (null, _liveReason);

    var client = _playbackClient;
    var (playback, playbackReason) = await _playerInfo(id, client, token);
    final alternative = _unplayableAlternative[client];
    if (playbackReason != null && alternative != null) {
      client = alternative;
      (playback, playbackReason) = await _playerInfo(id, client, token);
    }
    if (playbackReason != null) throw StateError('YouTube playback failed for $id: $playbackReason');

    final audio = _preferredAudio(_formats(playback!));
    if (audio == null) throw StateError('YouTube returned no downloadable audio for $id');
    final contentType = _contentType(audio);
    final title = metadata.basic_info.title?.trim() ?? '';
    return (
      Media._(
        id: id,
        title: title.isEmpty ? id : title,
        description: metadata.basic_info.short_description ?? '',
        publishedAt: _publication(metadata, channel: channel),
        durationSeconds: _seconds(metadata.basic_info.duration),
        contentType: contentType,
        audio: await _stream(audio, playback.cpn, client, token),
        chapters: chapters ? _chapters(metadata) : null,
        playback: playback,
        client: client,
        fallback: [if (client == InnerTubeClient.VISIONOS) InnerTubeClient.TV],
      ),
      null,
    );
  }

  /// After the media server refused [media]'s stream: another copy of the
  /// same rendition, else the same video from the next fallback client.
  /// False when there is nothing left to try.
  Future<bool> fallback(Media media, CancellationToken token) async {
    final refused = media.audio.format;
    final others = _formats(media._playback).where((f) => !identical(f, refused) && _sameRendition(refused, f) && _usable(f));
    if (others.firstOrNull case final format?) {
      media.audio = await _stream(format, media._playback.cpn, media._client, token);
      return true;
    }
    while (media._fallback.isNotEmpty) {
      final client = media._fallback.removeAt(0);
      final YT.VideoInfo? info;
      final String? reason;
      try {
        (info, reason) = await _playerInfo(media.id, client, token);
      } on SignInRequired {
        continue;
      }
      if (reason != null || info == null) continue;
      final audio = _preferredAudio(_formats(info));
      if (audio == null || _contentType(audio) != media.contentType) continue;
      media
        .._playback = info
        .._client = client
        ..audio = await _stream(audio, info.cpn, client, token);
      return true;
    }
    return false;
  }

  /// The video's chapters, for one that streams from elsewhere (a
  /// ListenJar Cloud episode) or played from its download; empty when it
  /// has none, null when YouTube won't say (the video is unavailable).
  Future<List<Chapter>?> chapters(String id, CancellationToken token) async {
    final (info, reason) = await _playerInfo(id, InnerTubeClient.WEB, token, next: true);
    return reason == null ? _chapters(info!) : null;
  }

  /// The chapters on the player bar: the creator's, from the description,
  /// else the ones YouTube made.
  static List<Chapter> _chapters(YT.VideoInfo info) {
    final markers = info.player_overlays?.decorated_player_bar?.player_bar?.markers_map ?? const <YTNodes.Marker>[];
    final marker = markers.where((m) => m.marker_key == 'DESCRIPTION_CHAPTERS' && m.value.chapters.isNotEmpty).firstOrNull ??
      markers.where((m) => m.value.chapters.isNotEmpty).firstOrNull;
    return [
      for (final (i, c) in (marker?.value.chapters ?? const <YTNodes.Chapter>[]).indexed)
        (
          start: Duration(milliseconds: c.time_range_start_millis.round()),
          title: switch (c.title.text?.trim()) {
            final t? when t.isNotEmpty => t,
            _ => 'Chapter ${i + 1}',
          },
        ),
    ];
  }

  /// A player response, or the reason the video is unavailable (and, when
  /// YouTube answered with an error, no response). With [next], YouTube.js's
  /// `getInfo`: the next response too, in parallel, for the chapters.
  Future<(YT.VideoInfo?, String?)> _playerInfo(String id, InnerTubeClient client, CancellationToken token, {bool next = false}) async {
    if (_limited case final limited?) throw limited;
    final YT.VideoInfo info;
    try {
      info = await traced(
        _log,
        '${next ? 'player and next' : 'player'} $id as ${client.name}',
        () => next ? _innertube.getInfo(id, client: client, token: token) : _innertube.getBasicInfo(id, client: client, token: token),
        describe: (info) => info.playability_status?.status ?? 'no status',
      );
    } on InnertubeError catch (e) {
      final status = YT.IPlayabilityStatus.fromJson(e.info) ?? YT.IPlayabilityStatus.fromJson((e.info as Map?)?['playability_status']);
      if (status != null && status.status == 'ERROR') return (null, _unavailable(status));
      rethrow;
    }
    final status = info.playability_status;
    if (status == null) throw StateError('YouTube player response missing playability status');
    if (status.status != 'OK') {
      return switch (status.status) {
        'UNPLAYABLE' => (info, _unavailable(status)),
        'LIVE_STREAM_OFFLINE' => (info, _liveReason),
        'LOGIN_REQUIRED' when status.reason == 'Private video' => (info, _reasonText(status)),
        'LOGIN_REQUIRED' => throw SignInRequired('${status.reason} ($id)'),
        _ => throw StateError('YouTube could not resolve $id (${status.status}): ${status.reason}'),
      };
    }
    if (info.basic_info.id != id) throw StateError('YouTube metadata video ID differs from the requested video');
    return (info, null);
  }

  /// A skip reason, except a rate limit, which says nothing about the video
  /// and stops the whole session.
  String _unavailable(YT.IPlayabilityStatus status) {
    final reason = _reasonText(status);
    if (!reason.replaceAll('’', "'").contains(_rateLimitNotice)) return reason;
    throw _limited ??= RateLimited(reason);
  }

  Future<MediaStream> _stream(Misc.Format format, String cpn, InnerTubeClient client, CancellationToken token) async {
    final player = _innertube.session.player;
    final resolved = Uri.parse(await traced(_log, 'decipher itag ${format.itag}', () => format.decipher(player, token: token)));
    final url = resolved.replace(queryParameters: {...resolved.queryParametersAll, 'cpn': cpn});
    // The media servers expect the user agent of the client that asked.
    final agent = switch (client) {
      InnerTubeClient.VISIONOS || InnerTubeClient.TV => Constants.CLIENTS[client.name]!['USER_AGENT']! as String,
      _ => _innertube.session.user_agent ?? '',
    };
    final length = format.content_length;
    final identity = [
      format.itag,
      format.mime_type,
      length?.toString() ?? 'None',
      ?url.queryParameters['xtags'],
    ].join(':');
    return MediaStream(url: url, userAgent: agent, identity: identity, format: format);
  }
}

/// A source as the engine reads it: a video id, a playlist id, or a channel's
/// `UC…` id (or, before it is resolved, its link).
enum SourceRefKind { video, playlist, channel }

final class SourceRef {
  const SourceRef(this.kind, this.id, this.url);
  final SourceRefKind kind;
  final String id;
  final String url;

  /// A feed's canonical source URL (public.yaml `Source.url`), or null.
  static SourceRef? parse(String kind, String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    return switch (kind) {
      'video' when _videoId.hasMatch(uri.queryParameters['v'] ?? '') =>
        SourceRef(SourceRefKind.video, uri.queryParameters['v']!, url),
      'playlist' when (uri.queryParameters['list'] ?? '').isNotEmpty =>
        SourceRef(SourceRefKind.playlist, uri.queryParameters['list']!, url),
      'channel' => SourceRef(SourceRefKind.channel, uri.pathSegments.lastOrNull ?? '', url),
      _ => null,
    };
  }
}

final _videoId = RegExp(r'^[\w-]{11}$');
final _views = RegExp(r'^\d[\d.,]*\s?[KMB]?( views?)?$');
final _length = RegExp(r'^\d+(:\d\d){1,2}$');
final _liveBadge = RegExp(r'^(LIVE|UPCOMING|PREMIERE)', caseSensitive: false);
final _channelId = RegExp(r'^UC[\w-]{22}$');
final _channelUrl = RegExp(r'^https://www\.youtube\.com/channel/(UC[\w-]{22})$');

/// What a lockup's or video's thumbnail badges say (`1:02:03`, `15 videos`,
/// `LIVE`).
List<String> _badges(YTNodes.YTNode? image) => [
  if (image case YTNodes.ThumbnailView(:final overlays))
    for (final overlay in overlays)
      ...switch (overlay) {
        YTNodes.ThumbnailOverlayBadgeView(:final badges) || YTNodes.ThumbnailBottomOverlayView(:final badges) =>
          badges.map((b) => b.text).where((t) => t.isNotEmpty),
        _ => const <String>[],
      },
];

/// The parts of a lockup's metadata rows; a video's byline can sit on an
/// avatar stack instead of in the text.
List<List<String>> _metadataRows(YTNodes.LockupView lockup) => [
  for (final row in lockup.metadata?.metadata?.metadata_rows ?? const <YTNodes.MetadataRow>[])
    [
      for (final part in row.metadata_parts ?? const <YTNodes.MetadataPart>[])
        switch ((part.text?.toString(), part.avatar_stack?.text?.toString())) {
          (final text?, _) when text.isNotEmpty => text,
          (_, final stack?) when stack.isNotEmpty => stack,
          _ => '',
        },
    ],
];

SearchResult? _searchResult(YTNodes.YTNode node) {
  String? clean(String? text) => text == null || text.trim().isEmpty ? null : text.trim();
  switch (node) {
    case YTNodes.Video(:final video_id, :final is_live, :final is_upcoming) when _videoId.hasMatch(video_id) && !is_live && is_upcoming != true:
      final title = node.title.toString().trim();
      if (title.isEmpty) return null;
      final views = clean(node.short_view_count?.toString());
      return SearchResult(
        kind: SourceRefKind.video,
        id: video_id,
        url: 'https://www.youtube.com/watch?v=$video_id',
        title: title,
        details: [?clean(node.author?.name), ?clean(node.duration?.text), if (views != null) views.endsWith('views') ? views : '$views views'],
        thumbnailUrl: _thumbnail(node.thumbnails),
      );
    case YTNodes.Channel(:final id) when _channelId.hasMatch(id):
      final title = node.author?.name.trim() ?? '';
      if (title.isEmpty) return null;
      final texts = [node.subscriber_count?.toString() ?? '', node.video_count?.toString() ?? ''].map((t) => t.trim());
      return SearchResult(
        kind: SourceRefKind.channel,
        id: id,
        url: 'https://www.youtube.com/channel/$id',
        title: title,
        details: [
          ...texts.where((t) => t.startsWith('@')),
          ...texts.where((t) => t.contains('subscriber')),
        ],
        thumbnailUrl: _thumbnail(node.author?.thumbnails ?? const []),
      );
    // YouTube now lists most videos and channels as lockups: the details
    // sit in rows of parts and the length in a thumbnail badge.
    case YTNodes.LockupView(:final content_type, content_id: final id?, :final content_image):
      final title = node.metadata?.title?.toString().trim() ?? '';
      if (title.isEmpty) return null;
      // A channel's lockup shows an avatar where others show a thumbnail.
      final image = switch (content_image) {
        YTNodes.CollectionThumbnailView(:final primary_thumbnail) => primary_thumbnail,
        _ => content_image,
      };
      final thumbnails = switch ((image, content_image)) {
        (YTNodes.ThumbnailView(image: final thumbnails), _) => thumbnails,
        (_, YTNodes.DecoratedAvatarView(:final avatar?)) => avatar.image,
        _ => const <Misc.Thumbnail>[],
      };
      final badges = _badges(image);
      final rows = _metadataRows(node);
      final parts = [for (final part in rows.firstOrNull ?? const <String>[]) ?clean(part)];
      switch (content_type) {
        case 'VIDEO' when _videoId.hasMatch(id) && !badges.any(_liveBadge.hasMatch):
          final views = parts.where(_views.hasMatch).firstOrNull;
          return SearchResult(
            kind: SourceRefKind.video,
            id: id,
            url: 'https://www.youtube.com/watch?v=$id',
            title: title,
            details: [
              ?parts.where((p) => !_views.hasMatch(p) && !p.contains('ago')).firstOrNull,
              ?badges.where(_length.hasMatch).firstOrNull,
              if (views != null) views.endsWith('views') ? views : '$views views',
            ],
            thumbnailUrl: _thumbnail(thumbnails),
          );
        case 'CHANNEL' when _channelId.hasMatch(id):
          return SearchResult(
            kind: SourceRefKind.channel,
            id: id,
            url: 'https://www.youtube.com/channel/$id',
            title: title,
            details: [...parts.where((p) => p.startsWith('@')), ...parts.where((p) => p.contains('subscriber'))],
            thumbnailUrl: _thumbnail(thumbnails),
          );
        // Mixes (RD…) are made up per listener and never end.
        case 'PLAYLIST' when id.isNotEmpty && !id.startsWith('RD'):
          return SearchResult(
            kind: SourceRefKind.playlist,
            id: id,
            url: 'https://www.youtube.com/playlist?list=$id',
            title: title,
            details: [
              ?clean(rows.firstOrNull?.firstOrNull),
              ...badges.where((b) => b.contains(RegExp(r'\d'))),
            ],
            thumbnailUrl: _thumbnail(thumbnails),
          );
      }
      return null;
    default:
      return null;
  }
}

bool _allowedHost(Uri url) {
  if (url.scheme != 'https') return false;
  return const ['youtube.com', 'google.com', 'googleapis.com', 'googlevideo.com', 'ytimg.com']
    .any((base) => url.host == base || url.host.endsWith('.$base'));
}

Map<String, Object?> _jsonMap(List<int> body) {
  try {
    final value = jsonDecode(utf8.decode(body));
    return value is Map<String, Object?> ? value : const {};
  } catch (_) {
    return const {};
  }
}

void _validPlaylist(YT.Playlist page) {
  if (!page.is_complete) throw StateError('YouTube playlist could not be parsed completely; no changes were made');
  for (final alert in page.page.alerts) {
    final type = switch (alert) {
      YTNodes.Alert(:final alert_type) || YTNodes.AlertWithButton(:final alert_type) => alert_type,
      _ => null,
    };
    if (type != 'INFO' && type != 'WARNING') throw StateError('YouTube could not list this playlist');
  }
}

Video _playlistVideo(YTNodes.YTNode item) {
  final (id, title, seconds) = switch (item) {
    YTNodes.PlaylistVideo(:final id, :final title, :final duration) => (id, title.toString(), _seconds(duration.seconds)),
    YTNodes.LockupView(:final content_id, :final metadata, :final content_image) => (
      content_id ?? '',
      metadata?.title?.toString() ?? '',
      _badges(content_image).map(_badgeSeconds).nonNulls.firstOrNull,
    ),
    _ => ('', '', null),
  };
  if (!_videoId.hasMatch(id)) throw StateError('Playlist contains an unidentified unavailable item');
  switch (item) {
    case YTNodes.PlaylistVideo():
      break;
    case YTNodes.LockupView(:final content_type) when content_type == 'VIDEO' || content_type == 'SHORT':
      break;
    default:
      throw StateError('Unsupported playlist item; listing is incomplete');
  }
  final trimmed = title.trim();
  return Video(id: id, title: trimmed.isEmpty ? 'YouTube video $id' : trimmed, durationSeconds: seconds);
}

/// `1:02:03` or `4:05` as seconds.
int? _badgeSeconds(String value) {
  final parts = value.split(':');
  if (parts.length < 2 || parts.length > 3) return null;
  var total = 0;
  for (final part in parts) {
    final n = int.tryParse(part);
    if (n == null || n < 0) return null;
    total = total * 60 + n;
  }
  return total > 0 ? total : null;
}

int? _seconds(num? value) {
  if (value == null || value.isNaN || value.isInfinite || value <= 0) return null;
  return value.ceil();
}

/// The reason YouTube gave, with the detail its error screen adds.
String _reasonText(YT.IPlayabilityStatus status) {
  final reason = status.reason.trim();
  final detail = switch (status.error_screen) {
    YTNodes.PlayerErrorMessage(:final subreason, :final reason) => (subreason.text ?? reason.text ?? '').trim(),
    _ => '',
  };
  if (detail.isNotEmpty && detail != reason) return reason.isEmpty ? detail : '$reason: $detail';
  return reason.isEmpty ? 'YouTube playback unavailable' : reason;
}

/// `1:02:03`, `4:05`, as search shows a video's length.
String _clock(int seconds) {
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = (seconds % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
}

/// `950`, `12K`, `1.2M`, `3B`, as search shows a count of views.
String _compact(int n) {
  for (final (size, suffix) in const [(1000000000, 'B'), (1000000, 'M'), (1000, 'K')]) {
    if (n >= size) {
      final v = n / size;
      return '${v >= 10 ? v.floor() : (v * 10).floor() / 10}$suffix'.replaceFirst('.0$suffix', suffix);
    }
  }
  return '$n';
}

/// The largest thumbnail, as an https URL.
String? _thumbnail(List<Misc.Thumbnail> thumbnails) {
  Misc.Thumbnail? best;
  for (final t in thumbnails) {
    if (best == null || t.width * t.height >= best.width * best.height) best = t;
  }
  final url = best?.url;
  if (url == null || url.isEmpty) return null;
  final absolute = url.startsWith('//') ? 'https:$url' : url;
  // Podcast apps take JPEG or PNG artwork, not WebP; YouTube serves every
  // video thumbnail as JPEG too.
  if (_webpThumbnail.firstMatch(absolute) case final m?) return 'https://i.ytimg.com/vi/${m[1]}/${m[2]}.jpg';
  return absolute;
}

final _webpThumbnail = RegExp(r'^https://i\.ytimg\.com/vi_webp/([A-Za-z0-9_-]{11})/(\w+)\.webp(?:\?.*)?$');

/// When the video came out: its upload date for a channel, its publish date
/// otherwise, whichever there is.
DateTime _publication(YT.VideoInfo info, {required bool channel}) {
  final microformat = info.page.firstOrNull?.microformat;
  final (publish, upload) = microformat is YTNodes.PlayerMicroformat ? (microformat.publish_date, microformat.upload_date) : ('', '');
  final (first, second) = channel ? (upload, publish) : (publish, upload);
  final date = first.isNotEmpty ? first : second;
  return DateTime.tryParse(date)?.toUtc() ?? DateTime.now().toUtc();
}

/// Every stream the player response lists.
List<Misc.Format> _formats(YT.VideoInfo info) => [...?info.streaming_data?.formats, ...?info.streaming_data?.adaptive_formats];

bool _usable(Misc.Format f) =>
  f.drm_families.isEmpty && !f.is_type_otf && [f.url, f.cipher, f.signature_cipher].any((s) => s != null && s.isNotEmpty);

bool _isAAC(Misc.Format f) => f.mime_type.contains('mp4a.40.');

/// The default audio track's best audio-only format, AAC before Opus.
Misc.Format? _preferredAudio(List<Misc.Format> formats) {
  Misc.Format? audio;
  for (final f in formats) {
    if (!_usable(f) || !f.has_audio || f.has_video || (f.audio_track != null && !f.audio_track!.audio_is_default)) continue;
    if (!_isAAC(f) && !f.mime_type.startsWith('audio/webm')) continue;
    if (audio == null ||
      (_isAAC(f) && !_isAAC(audio)) ||
      (_isAAC(f) == _isAAC(audio) && f.bitrate > audio.bitrate)) {
      audio = f;
    }
  }
  return audio;
}

String _contentType(Misc.Format f) => _isAAC(f) ? 'audio/mp4' : 'audio/webm';

bool _sameRendition(Misc.Format a, Misc.Format b) {
  if (a.itag != b.itag || a.mime_type != b.mime_type) return false;
  if (a.audio_track == null || b.audio_track == null) return a.audio_track == null && b.audio_track == null;
  return a.audio_track!.id == b.audio_track!.id;
}
