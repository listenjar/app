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

import 'package:cancellation_token/cancellation_token.dart';
import 'package:youtubei/youtubei.dart' as yt;

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
  const Resolved({required this.url, required this.title, required this.artworkUrl});
  final String url;
  final String title;
  final String? artworkUrl;
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
  });
  final SourceRefKind kind;
  final String id;
  final String url;
  final String title;

  /// Who made it and how big it is: `Cercle · 2:13:48 · 69M views`.
  final List<String> details;
  final String? thumbnailUrl;
}

/// A stream to download, with what to send YouTube's media servers.
final class MediaStream {
  const MediaStream({required this.url, required this.userAgent, required this.identity, required this.format});
  final Uri url;
  final String userAgent;

  /// Which rendition this is; a saved partial download resumes only into the
  /// same one.
  final String identity;
  final yt.Format format;
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
  yt.VideoInfo _playback;
  yt.Client _client;
  final List<yt.Client> _fallback;
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
const _unplayableAlternative = {yt.Client.embeddedWeb: yt.Client.creatorWeb, yt.Client.visionOS: yt.Client.tv};

/// YouTube for the app's whole life: one session, started on first use (or
/// by [warmUp] at launch) and shared by everything that asks YouTube. A
/// failed start is tried again on the next call; [restart] replaces a
/// rate-limited session.
final class YouTubeService {
  final _http = HttpClient()..userAgent = null;
  final _life = CancellationToken();
  YouTube? _session;
  Future<YouTube>? _starting;

  /// Starts the session now, so the first search doesn't wait for it.
  void warmUp() => unawaited(session(_life).then<void>((_) {}, onError: (_) {}));

  Future<YouTube> session(CancellationToken token) async {
    if (_session case final session?) return session;
    final starting = _starting ??= YouTube.start(_http, _life)
      .then((session) => _session = session)
      .whenComplete(() => _starting = null);
    return starting.asCancellable(token);
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
    await restart().catchError((_) {});
    _http.close(force: true);
  }
}

/// One YouTube session: one YouTube.js runtime, reused for every request.
final class YouTube {
  YouTube._(this._engine, this._session);

  final yt.YouTubei _engine;
  final yt.Session _session;

  /// Without a signed-in cookie, visionOS gives plain, unthrottled streams.
  final _playbackClient = yt.Client.visionOS;

  /// The first rate limit: after it, no more player requests this session.
  RateLimited? _limited;

  /// Starts YouTube.js and opens a session. [http] carries every request.
  static Future<YouTube> start(HttpClient http, CancellationToken token) async {
    final continuations = <String>{};
    final fetch = yt.httpClientFetch(http);
    final engine = await yt.startYouTubei((request, token) {
      final url = Uri.parse(request.url);
      if (!_allowedHost(url)) throw StateError('unexpected YouTube API host ${url.host}');
      final body = request.body;
      if (url.path.contains('/youtubei/v1/browse') && body != null) {
        final continuation = _jsonMap(body)['continuation'];
        // A repeated token would page forever.
        if (continuation is String && !continuations.add(continuation)) throw StateError('repeated YouTube continuation');
      }
      return fetch(request, token);
    }, token: token);
    try {
      final session = await yt.initialize(
        engine,
        const yt.SessionOptions(lang: 'en', location: 'US', timezone: 'UTC', failFast: true, retrievePlayer: true),
        token: token,
      );
      return YouTube._(engine, session);
    } catch (_) {
      await yt.closeYouTubei(engine);
      rethrow;
    }
  }

  Future<void> close() => yt.closeYouTubei(_engine);

  /// The title and artwork of what the listener added, and for a channel
  /// its `/channel/UC…` URL.
  Future<Resolved> resolve(SourceRef source, CancellationToken token) async {
    final id = source.id;
    switch (source.kind) {
      case SourceRefKind.video:
        final (info, reason) = await _playerInfo(id, yt.Client.web, token);
        if (reason != null) throw StateError(reason);
        final title = info.basicInfo.title.trim();
        return Resolved(url: source.url, title: title.isEmpty ? 'YouTube video $id' : title, artworkUrl: _thumbnail(info.basicInfo.thumbnail));
      case SourceRefKind.playlist:
        final page = await _playlistHead(id, token);
        unawaited(yt.release(_engine, [page.handle]));
        return Resolved(url: source.url, title: page.title, artworkUrl: _thumbnail(page.thumbnails));
      case SourceRefKind.channel:
        final channel = await yt.channel(_engine, source.url, token: token);
        if (!_channelId.hasMatch(channel.id)) throw StateError('YouTube returned no channel for ${source.url}');
        return Resolved(
          url: 'https://www.youtube.com/channel/${channel.id}',
          title: channel.title.trim().isEmpty ? channel.id : channel.title,
          artworkUrl: _thumbnail(channel.thumbnails),
        );
    }
  }

  /// What YouTube's search finds for [query] that can become a feed, in
  /// YouTube's order: no Shorts shelves, live streams or mixes.
  Future<List<SearchResult>> search(String query, CancellationToken token) async {
    final items = await yt.search(_engine, query, token: token);
    final results = <SearchResult>[];
    final seen = <String>{};
    for (final item in items) {
      if (_searchResult(item) case final result? when seen.add(result.url)) results.add(result);
    }
    return results;
  }

  /// What the source holds: every video of a playlist or a channel's uploads,
  /// or the one video.
  Future<Snapshot> snapshot(SourceRef source, CancellationToken token) => switch (source.kind) {
    SourceRefKind.video => _videoSnapshot(source.id, token),
    SourceRefKind.playlist => _playlistSnapshot(source.id, token),
    // A channel's uploads are the playlist UU + the rest of its UC id.
    SourceRefKind.channel => _playlistSnapshot('UU${source.id.substring(2)}', token),
  };

  Future<Snapshot> _videoSnapshot(String id, CancellationToken token) async {
    final (info, _) = await _playerInfo(id, yt.Client.web, token);
    final title = info.basicInfo.title.trim();
    return Snapshot(
      title: title.isEmpty ? 'YouTube video $id' : title,
      artworkUrl: _thumbnail(info.basicInfo.thumbnail),
      videos: [Video(id: id, title: title.isEmpty ? 'YouTube video $id' : title, durationSeconds: _seconds(info.basicInfo.duration))],
      canRemove: false,
    );
  }

  Future<yt.Playlist> _playlistHead(String id, CancellationToken token) async {
    final page = await yt.playlistHead(_engine, id, token: token);
    _validPlaylist(page);
    if (page.title.trim().isEmpty) throw StateError('YouTube playlist missing title');
    return page;
  }

  Future<Snapshot> _playlistSnapshot(String id, CancellationToken token) async {
    var page = await _playlistHead(id, token);
    final title = page.title;
    final artwork = _thumbnail(page.thumbnails);
    final videos = <Video>[];
    final seen = <String>{};
    var canRemove = true;
    for (var pages = 1; ; pages++) {
      if (pages > _maximumPlaylistPages) throw StateError('YouTube playlist exceeds the scan limit');
      _validPlaylist(page);
      if (page.alerts.isNotEmpty) canRemove = false;
      for (final item in page.items) {
        final video = _playlistVideo(item);
        if (seen.add(video.id)) videos.add(video);
      }
      if (!page.hasContinuation) break;
      page = await yt.continuation(_engine, page, token: token);
    }
    return Snapshot(title: title, artworkUrl: artwork, videos: videos, canRemove: canRemove);
  }

  /// The video's metadata and audio stream, or the reason it can't be had
  /// (private, removed, live). Throws [RateLimited] once YouTube throttles.
  Future<(Media?, String?)> media(String id, {required bool channel, required CancellationToken token}) async {
    final (metadata, reason) = await _playerInfo(id, yt.Client.web, token);
    if (reason != null) return (null, reason);
    if (metadata.basicInfo.isLive || metadata.basicInfo.isUpcoming) return (null, _liveReason);

    var client = _playbackClient;
    var (playback, playbackReason) = await _playerInfo(id, client, token);
    final alternative = _unplayableAlternative[client];
    if (playbackReason != null && alternative != null) {
      client = alternative;
      (playback, playbackReason) = await _playerInfo(id, client, token);
    }
    if (playbackReason != null) throw StateError('YouTube playback failed for $id: $playbackReason');

    final audio = _preferredAudio(playback.formats);
    if (audio == null) throw StateError('YouTube returned no downloadable audio for $id');
    final contentType = _contentType(audio);
    final title = metadata.basicInfo.title.trim();
    return (
      Media._(
        id: id,
        title: title.isEmpty ? id : title,
        description: metadata.basicInfo.shortDescription,
        publishedAt: _publication(metadata, channel: channel),
        durationSeconds: _seconds(metadata.basicInfo.duration),
        contentType: contentType,
        audio: await _stream(audio, playback.cpn, client, token),
        playback: playback,
        client: client,
        fallback: [if (client == yt.Client.visionOS) yt.Client.tv],
      ),
      null,
    );
  }

  /// After the media server refused [media]'s stream: another copy of the
  /// same rendition, else the same video from the next fallback client.
  /// False when there is nothing left to try.
  Future<bool> fallback(Media media, CancellationToken token) async {
    final refused = media.audio.format;
    final others = media._playback.formats.where((f) => f.handle != refused.handle && _sameRendition(refused, f) && _usable(f));
    if (others.firstOrNull case final format?) {
      media.audio = await _stream(format, media._playback.cpn, media._client, token);
      return true;
    }
    while (media._fallback.isNotEmpty) {
      final client = media._fallback.removeAt(0);
      final yt.VideoInfo info;
      final String? reason;
      try {
        (info, reason) = await _playerInfo(media.id, client, token);
      } on SignInRequired {
        continue;
      }
      if (reason != null) continue;
      final audio = _preferredAudio(info.formats);
      if (audio == null || _contentType(audio) != media.contentType) continue;
      media
        .._playback = info
        .._client = client
        ..audio = await _stream(audio, info.cpn, client, token);
      return true;
    }
    return false;
  }

  /// A player response, or the reason the video is unavailable.
  Future<(yt.VideoInfo, String?)> _playerInfo(String id, yt.Client client, CancellationToken token) async {
    if (_limited case final limited?) throw limited;
    final yt.VideoInfo info;
    try {
      info = await yt.videoInfo(_engine, id, client, token: token);
    } on yt.YouTubeiException catch (e) {
      if (e.playabilityStatus case final status? when status.status == 'ERROR') {
        return (_emptyInfo, _unavailable(status));
      }
      rethrow;
    }
    final status = info.playabilityStatus;
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
    if (info.basicInfo.id != id) throw StateError('YouTube metadata video ID differs from the requested video');
    return (info, null);
  }

  /// A skip reason, except a rate limit, which says nothing about the video
  /// and stops the whole session.
  String _unavailable(yt.PlayabilityStatus status) {
    final reason = _reasonText(status);
    if (!reason.replaceAll('’', "'").contains(_rateLimitNotice)) return reason;
    throw _limited ??= RateLimited(reason);
  }

  Future<MediaStream> _stream(yt.Format format, String cpn, yt.Client client, CancellationToken token) async {
    final resolved = Uri.parse(await yt.decipher(_engine, format, token: token));
    final url = resolved.replace(queryParameters: {...resolved.queryParametersAll, 'cpn': cpn});
    final agent = switch (client) {
      yt.Client.visionOS => _session.visionOSUserAgent,
      yt.Client.tv => _session.tvUserAgent,
      _ => _session.userAgent,
    };
    final length = format.contentLength;
    final identity = [
      format.itag,
      format.mimeType,
      length == null || length.isNaN ? 'None' : length.toStringAsFixed(0),
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
final _channelId = RegExp(r'^UC[\w-]{22}$');

/// An empty player response, for a video YouTube answered with an error.
final _emptyInfo = yt.VideoInfo(
  basicInfo: const yt.BasicInfo(id: '', title: '', duration: null, shortDescription: '', thumbnail: [], isLive: false, isUpcoming: false),
  playabilityStatus: null,
  publishDate: '',
  uploadDate: '',
  cpn: '',
  formats: const [],
);

SearchResult? _searchResult(yt.SearchItem item) {
  final title = item.title.trim();
  if (title.isEmpty) return null;
  String? clean(String text) => text.trim().isEmpty ? null : text.trim();
  switch (item.type) {
    case 'Video' when _videoId.hasMatch(item.id) && !item.isLive && !item.isUpcoming:
      return SearchResult(
        kind: SourceRefKind.video,
        id: item.id,
        url: 'https://www.youtube.com/watch?v=${item.id}',
        title: title,
        details: [?clean(item.author), ?clean(item.duration), if (clean(item.viewCount) case final v?) v.endsWith('views') ? v : '$v views'],
        thumbnailUrl: _thumbnail(item.thumbnails),
      );
    case 'Channel' when _channelId.hasMatch(item.id):
      final texts = [item.subscriberCount, item.videoCount].map((t) => t.trim());
      return SearchResult(
        kind: SourceRefKind.channel,
        id: item.id,
        url: 'https://www.youtube.com/channel/${item.id}',
        title: title,
        details: [
          ...texts.where((t) => t.startsWith('@')),
          ...texts.where((t) => t.contains('subscriber')),
        ],
        thumbnailUrl: _thumbnail(item.thumbnails),
      );
    // Mixes (RD…) are made up per listener and never end.
    case 'LockupView' when item.contentType == 'PLAYLIST' && item.id.isNotEmpty && !item.id.startsWith('RD'):
      return SearchResult(
        kind: SourceRefKind.playlist,
        id: item.id,
        url: 'https://www.youtube.com/playlist?list=${item.id}',
        title: title,
        details: [
          ?clean(item.metadataRows.firstOrNull?.firstOrNull ?? ''),
          ...item.badges.where((b) => b.contains(RegExp(r'\d'))),
        ],
        thumbnailUrl: _thumbnail(item.thumbnails),
      );
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

void _validPlaylist(yt.Playlist page) {
  if (!page.isComplete) throw StateError('YouTube playlist could not be parsed completely; no changes were made');
  for (final alert in page.alerts) {
    if (!const {'Alert', 'AlertWithButton'}.contains(alert.type) || !const {'INFO', 'WARNING'}.contains(alert.alertType)) {
      throw StateError('YouTube could not list this playlist');
    }
  }
}

Video _playlistVideo(yt.PlaylistItem item) {
  if (!_videoId.hasMatch(item.id)) throw StateError('Playlist contains an unidentified unavailable item');
  var seconds = _seconds(item.durationSeconds);
  switch (item.type) {
    case 'PlaylistVideo':
      break;
    case 'LockupView' when item.contentType == 'VIDEO' || item.contentType == 'SHORT':
      for (final badge in item.durationBadges) {
        if (_badgeSeconds(badge) case final value?) {
          seconds = value;
          break;
        }
      }
    default:
      throw StateError('Unsupported playlist item; listing is incomplete');
  }
  final title = item.title.trim();
  return Video(id: item.id, title: title.isEmpty ? 'YouTube video ${item.id}' : title, durationSeconds: seconds);
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

int? _seconds(double? value) {
  if (value == null || value.isNaN || value.isInfinite || value <= 0) return null;
  return value.ceil();
}

String _reasonText(yt.PlayabilityStatus status) {
  final reason = status.reason.trim();
  final detail = status.subreason.trim();
  if (detail.isNotEmpty && detail != reason) return reason.isEmpty ? detail : '$reason: $detail';
  return reason.isEmpty ? 'YouTube playback unavailable' : reason;
}

/// The largest thumbnail, as an https URL.
String? _thumbnail(List<yt.Thumbnail> thumbnails) {
  yt.Thumbnail? best;
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
DateTime _publication(yt.VideoInfo info, {required bool channel}) {
  final (first, second) = channel ? (info.uploadDate, info.publishDate) : (info.publishDate, info.uploadDate);
  final date = first.isNotEmpty ? first : second;
  return DateTime.tryParse(date)?.toUtc() ?? DateTime.now().toUtc();
}

bool _usable(yt.Format f) =>
  f.drmFamilies.isEmpty && !f.isTypeOTF && (f.url.isNotEmpty || f.cipher.isNotEmpty || f.signatureCipher.isNotEmpty);

bool _isAAC(yt.Format f) => f.mimeType.contains('mp4a.40.');

/// The default audio track's best audio-only format, AAC before Opus.
yt.Format? _preferredAudio(List<yt.Format> formats) {
  yt.Format? audio;
  for (final f in formats) {
    if (!_usable(f) || !f.hasAudio || f.hasVideo || (f.audioTrack != null && !f.audioTrack!.audioIsDefault)) continue;
    if (!_isAAC(f) && !f.mimeType.startsWith('audio/webm')) continue;
    if (audio == null ||
      (_isAAC(f) && !_isAAC(audio)) ||
      (_isAAC(f) == _isAAC(audio) && f.bitrate > audio.bitrate)) {
      audio = f;
    }
  }
  return audio;
}

String _contentType(yt.Format f) => _isAAC(f) ? 'audio/mp4' : 'audio/webm';

bool _sameRendition(yt.Format a, yt.Format b) {
  if (a.itag != b.itag || a.mimeType != b.mimeType) return false;
  if (a.audioTrack == null || b.audioTrack == null) return a.audioTrack == null && b.audioTrack == null;
  return a.audioTrack!.id == b.audioTrack!.id;
}
