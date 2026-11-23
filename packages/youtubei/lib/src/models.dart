// Owned snapshots of YouTube.js values, ported from the Go youtubei crate's
// bindings.go. They stay usable after their engine closes; only `handle`
// refers back to a live object inside it.
import 'dart:typed_data';

/// The YouTube.js client a video is requested as.
enum Client {
  web('WEB'),
  mobileWeb('MWEB'),
  embeddedWeb('WEB_EMBEDDED'),
  creatorWeb('WEB_CREATOR'),
  visionOS('VISIONOS'),
  tv('TV');

  const Client(this.value);
  final String value;
}

/// One HTTP request YouTube.js makes through its `fetch`.
final class FetchRequest {
  const FetchRequest({required this.url, required this.method, required this.headers, this.body});
  final String url;
  final String method;
  final List<(String, String)> headers;
  final Uint8List? body;
}

final class FetchResponse {
  const FetchResponse({required this.url, required this.status, required this.headers, required this.body});
  final String url;
  final int status;
  final List<(String, String)> headers;
  final Uint8List body;
}

final class Thumbnail {
  const Thumbnail({required this.url, required this.width, required this.height});
  final String url;
  final double width;
  final double height;
}

final class PlaylistItem {
  const PlaylistItem({
    required this.type,
    required this.id,
    required this.title,
    required this.sourceTitle,
    required this.durationSeconds,
    required this.isPlayable,
    required this.contentType,
    required this.durationBadges,
    required this.upcoming,
  });
  final String type;
  final String id;
  final String title;
  final String? sourceTitle;

  /// NaN when YouTube.js reported no duration.
  final double durationSeconds;
  final bool isPlayable;
  final String contentType;
  final List<String> durationBadges;
  final DateTime? upcoming;
}

final class PlaylistAlert {
  const PlaylistAlert({required this.type, required this.alertType});
  final String type;
  final String alertType;
}

/// One page of a playlist. [handle] is the live page its continuation reads;
/// [continuation] consumes it.
final class Playlist {
  const Playlist({
    required this.handle,
    required this.title,
    required this.thumbnails,
    required this.items,
    required this.alerts,
    required this.hasContinuation,
    required this.isComplete,
  });
  final int handle;
  final String title;
  final List<Thumbnail> thumbnails;
  final List<PlaylistItem> items;
  final List<PlaylistAlert> alerts;
  final bool hasContinuation;

  /// Whether every member YouTube.js read survived parsing: a fork extension
  /// that fails closed before reconciling episodes.
  final bool isComplete;
}

/// A channel: its `UC…` id, whose uploads are the playlist `UU…`.
final class Channel {
  const Channel({required this.id, required this.title, required this.thumbnails});
  final String id;
  final String title;
  final List<Thumbnail> thumbnails;
}

/// One search result as YouTube.js parsed it. [type] is the node's: `Video`,
/// `Channel` and `LockupView` (playlists, by [contentType]) carry the rest;
/// shelves and other nodes carry only their type.
final class SearchItem {
  const SearchItem({
    required this.type,
    required this.id,
    required this.title,
    required this.thumbnails,
    this.author = '',
    this.duration = '',
    this.viewCount = '',
    this.isLive = false,
    this.isUpcoming = false,
    this.subscriberCount = '',
    this.videoCount = '',
    this.contentType = '',
    this.metadataRows = const [],
    this.badges = const [],
  });
  final String type;
  final String id;
  final String title;
  final List<Thumbnail> thumbnails;

  /// A video's channel, its `1:02:03` length and short view count.
  final String author;
  final String duration;
  final String viewCount;
  final bool isLive;
  final bool isUpcoming;

  /// A channel's texts as YouTube labels them; it now puts the `@handle` in
  /// the first and the subscriber count in the second.
  final String subscriberCount;
  final String videoCount;

  /// A lockup's `PLAYLIST` or `VIDEO`, its metadata lines' parts and its
  /// thumbnail badges (`15 videos`).
  final String contentType;
  final List<List<String>> metadataRows;
  final List<String> badges;
}

final class BasicInfo {
  const BasicInfo({
    required this.id,
    required this.title,
    required this.duration,
    required this.shortDescription,
    required this.thumbnail,
    required this.isLive,
    required this.isUpcoming,
  });
  final String id;
  final String title;
  final double? duration;
  final String shortDescription;
  final List<Thumbnail> thumbnail;
  final bool isLive;
  final bool isUpcoming;
}

final class PlayabilityStatus {
  const PlayabilityStatus({required this.status, required this.reason, required this.subreason});
  final String status;
  final String reason;
  final String subreason;
}

final class AudioTrack {
  const AudioTrack({required this.audioIsDefault, required this.id});
  final bool audioIsDefault;
  final String id;
}

/// A stream format. [handle] is the live format [decipher] reads; release it
/// with [release] once done.
final class Format {
  const Format({
    required this.handle,
    required this.itag,
    required this.mimeType,
    required this.bitrate,
    required this.width,
    required this.height,
    required this.fps,
    required this.contentLength,
    required this.hasAudio,
    required this.hasVideo,
    required this.isTypeOTF,
    required this.drmFamilies,
    required this.audioTrack,
    required this.url,
    required this.cipher,
    required this.signatureCipher,
  });
  final int handle;
  final int itag;
  final String mimeType;
  final double bitrate;
  final double? width;
  final double? height;
  final double? fps;

  /// NaN when YouTube.js reported it as null, null when absent.
  final double? contentLength;
  final bool hasAudio;
  final bool hasVideo;
  final bool isTypeOTF;
  final List<String> drmFamilies;
  final AudioTrack? audioTrack;
  final String url;
  final String cipher;
  final String signatureCipher;
}

final class VideoInfo {
  const VideoInfo({
    required this.basicInfo,
    required this.playabilityStatus,
    required this.publishDate,
    required this.uploadDate,
    required this.cpn,
    required this.formats,
  });
  final BasicInfo basicInfo;
  final PlayabilityStatus? playabilityStatus;
  final String publishDate;
  final String uploadDate;
  final String cpn;
  final List<Format> formats;
}

final class Session {
  const Session({required this.userAgent, required this.visionOSUserAgent, required this.tvUserAgent});
  final String userAgent;
  final String visionOSUserAgent;
  final String tvUserAgent;
}

final class SessionOptions {
  const SessionOptions({
    required this.timezone,
    this.lang,
    this.location,
    this.cookie,
    this.generateSessionLocally = false,
    this.failFast = false,
    this.retrievePlayer = false,
    this.retrieveInnertubeConfig = false,
  });
  final String? lang;
  final String? location;

  /// An IANA time zone, such as `Europe/Berlin`. Required: QuickJS has no
  /// `Intl` for YouTube.js to read the system's from.
  final String timezone;
  final String? cookie;
  final bool generateSessionLocally;
  final bool failFast;
  final bool retrievePlayer;
  final bool retrieveInnertubeConfig;
}

/// A YouTube.js exception, with the host error that caused it when there was
/// one (a failed fetch).
final class YouTubeiException implements Exception {
  const YouTubeiException(this.message, {this.stack, this.info, this.playabilityStatus, this.cause});
  final String message;
  final String? stack;
  final Object? info;
  final PlayabilityStatus? playabilityStatus;
  final Object? cause;

  @override
  String toString() => 'YouTubeiException: $message';
}

Map<String, Object?> sessionOptionsJson(SessionOptions o) => {
  if (o.lang case final v? when v.isNotEmpty) 'lang': v,
  if (o.location case final v? when v.isNotEmpty) 'location': v,
  'timezone': o.timezone,
  if (o.cookie case final v? when v.isNotEmpty) 'cookie': v,
  'generate_session_locally': o.generateSessionLocally,
  'fail_fast': o.failFast,
  'retrieve_player': o.retrievePlayer,
  'retrieve_innertube_config': o.retrieveInnertubeConfig,
};

Map<String, Object?> _map(Object? v) => (v as Map?)?.cast<String, Object?>() ?? const {};
List<Object?> _list(Object? v) => (v as List?) ?? const [];
String _string(Object? v) => v is String ? v : '';
bool _bool(Object? v) => v == true;
double? _double(Object? v) => v is num ? v.toDouble() : null;

Thumbnail _thumbnail(Object? raw) {
  final m = _map(raw);
  return Thumbnail(url: _string(m['url']), width: _double(m['width']) ?? 0, height: _double(m['height']) ?? 0);
}

Session sessionFromJson(Object? raw) {
  final m = _map(raw);
  return Session(
    userAgent: _string(m['user_agent']),
    visionOSUserAgent: _string(m['visionos_user_agent']),
    tvUserAgent: _string(m['tv_user_agent']),
  );
}

Playlist playlistFromJson(Object? raw) {
  final m = _map(raw);
  return Playlist(
    handle: m['handle'] as int,
    title: _string(m['title']),
    thumbnails: _list(m['thumbnails']).map(_thumbnail).toList(),
    items: _list(m['items']).map((raw) {
      final i = _map(raw);
      return PlaylistItem(
        type: _string(i['type']),
        id: _string(i['id']),
        title: _string(i['title']),
        sourceTitle: i['source_title'] as String?,
        durationSeconds: i.containsKey('duration_seconds') && i['duration_seconds'] == null
          ? double.nan
          : _double(i['duration_seconds']) ?? 0,
        isPlayable: _bool(i['is_playable']),
        contentType: _string(i['content_type']),
        durationBadges: _list(i['duration_badges']).whereType<String>().toList(),
        upcoming: switch (i['upcoming_ms']) {
          final num ms => DateTime.fromMillisecondsSinceEpoch(ms.toInt(), isUtc: true),
          _ => null,
        },
      );
    }).toList(),
    alerts: _list(m['alerts']).map((raw) {
      final a = _map(raw);
      return PlaylistAlert(type: _string(a['type']), alertType: _string(a['alert_type']));
    }).toList(),
    hasContinuation: _bool(m['has_continuation']),
    isComplete: _bool(m['is_complete']),
  );
}

Channel channelFromJson(Object? raw) {
  final m = _map(raw);
  return Channel(
    id: _string(m['id']),
    title: _string(m['title']),
    thumbnails: _list(m['thumbnails']).map(_thumbnail).toList(),
  );
}

List<SearchItem> searchFromJson(Object? raw) => _list(raw).map((raw) {
  final m = _map(raw);
  return SearchItem(
    type: _string(m['type']),
    id: _string(m['id']),
    title: _string(m['title']),
    thumbnails: _list(m['thumbnails']).map(_thumbnail).toList(),
    author: _string(m['author']),
    duration: _string(m['duration']),
    viewCount: _string(m['view_count']),
    isLive: _bool(m['is_live']),
    isUpcoming: _bool(m['is_upcoming']),
    subscriberCount: _string(m['subscriber_count']),
    videoCount: _string(m['video_count']),
    contentType: _string(m['content_type']),
    metadataRows: _list(m['metadata_rows']).map((r) => _list(r).map(_string).toList()).toList(),
    badges: _list(m['badges']).whereType<String>().toList(),
  );
}).toList();

PlayabilityStatus? playabilityFromJson(Object? raw) {
  if (raw == null) return null;
  final m = _map(raw);
  return PlayabilityStatus(status: _string(m['status']), reason: _string(m['reason']), subreason: _string(m['subreason']));
}

VideoInfo videoInfoFromJson(Object? raw) {
  final m = _map(raw);
  final basic = _map(m['basic_info']);
  return VideoInfo(
    basicInfo: BasicInfo(
      id: _string(basic['id']),
      title: _string(basic['title']),
      duration: _double(basic['duration']),
      shortDescription: _string(basic['short_description']),
      thumbnail: _list(basic['thumbnail']).map(_thumbnail).toList(),
      isLive: _bool(basic['is_live']),
      isUpcoming: _bool(basic['is_upcoming']),
    ),
    playabilityStatus: playabilityFromJson(m['playability_status']),
    publishDate: _string(m['publish_date']),
    uploadDate: _string(m['upload_date']),
    cpn: _string(m['cpn']),
    formats: _list(m['formats']).map((raw) {
      final f = _map(raw);
      final track = f['audio_track'];
      return Format(
        handle: f['handle'] as int,
        itag: (f['itag'] as num?)?.toInt() ?? 0,
        mimeType: _string(f['mime_type']),
        bitrate: _double(f['bitrate']) ?? 0,
        width: _double(f['width']),
        height: _double(f['height']),
        fps: _double(f['fps']),
        contentLength: f.containsKey('content_length') && f['content_length'] == null
          ? double.nan
          : _double(f['content_length']),
        hasAudio: _bool(f['has_audio']),
        hasVideo: _bool(f['has_video']),
        isTypeOTF: _bool(f['is_type_otf']),
        drmFamilies: _list(f['drm_families']).whereType<String>().toList(),
        audioTrack: track == null
          ? null
          : AudioTrack(audioIsDefault: _bool(_map(track)['audio_is_default']), id: _string(_map(track)['id'])),
        url: _string(f['url']),
        cipher: _string(f['cipher']),
        signatureCipher: _string(f['signature_cipher']),
      );
    }).toList(),
  );
}
