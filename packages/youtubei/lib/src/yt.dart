// YouTube.js's YT (src/parser/youtube/): the pages Innertube returns. Only
// the properties ListenJar reads so far; add others by their upstream names.
// ignore_for_file: non_constant_identifier_names
import 'package:cancellation_token/cancellation_token.dart';
import 'package:meta/meta.dart';

import 'engine.dart';
import 'innertube.dart';
import 'json.dart';
import 'misc.dart';
import 'yt_nodes.dart' as YTNodes; // ignore: library_prefixes

/// `basic_info`: the player response's video details and microformat.
final class BasicInfo {
  BasicInfo._(Json m)
    : id = string(m['id']) ?? '',
      channel_id = string(m['channel_id']),
      title = string(m['title']),
      duration = number(m['duration']),
      short_description = string(m['short_description']),
      thumbnail = Thumbnail.listFromJson(m['thumbnail']),
      author = string(m['author']),
      view_count = integer(m['view_count']),
      is_live = boolean(m['is_live']),
      is_upcoming = boolean(m['is_upcoming']),
      is_private = boolean(m['is_private']);
  final String id;
  final String? channel_id;
  final String? title;
  final num? duration;
  final String? short_description;
  final List<Thumbnail> thumbnail;
  final String? author;
  final int? view_count;
  final bool? is_live;
  final bool? is_upcoming;
  final bool? is_private;
}

final class IPlayabilityStatus {
  IPlayabilityStatus._(Json m)
    : status = string(m['status']) ?? '',
      reason = string(m['reason']) ?? '',
      error_screen = YTNodes.YTNode.fromJson(m['error_screen']),
      embeddable = boolean(m['embeddable']) ?? false;

  /// The playability status an InnertubeError carries in its `info`.
  static IPlayabilityStatus? fromJson(Object? raw) => switch (mapOrNull(raw)) {
    final m? when m['status'] is String => IPlayabilityStatus._(m),
    _ => null,
  };

  /// `OK`, `ERROR`, `UNPLAYABLE`, `LOGIN_REQUIRED`, `LIVE_STREAM_OFFLINE`…
  final String status;
  final String reason;
  final YTNodes.YTNode? error_screen;
  final bool embeddable;
}

final class IStreamingData {
  IStreamingData._(YouTubei yt, Json m)
    : expires = date(m['expires']),
      formats = [for (final f in list(m['formats'])) Format.fromJson(yt, f)],
      adaptive_formats = [for (final f in list(m['adaptive_formats'])) Format.fromJson(yt, f)];
  final DateTime? expires;
  final List<Format> formats;
  final List<Format> adaptive_formats;
}

/// `page[0]`: the player response, of which bindings.js keeps the
/// microformat.
final class IPlayerResponse {
  IPlayerResponse._(Json m) : microformat = YTNodes.YTNode.fromJson(m['microformat']);
  final YTNodes.YTNode? microformat;
}

final class VideoInfo {
  VideoInfo._(YouTubei yt, Json m)
    : basic_info = BasicInfo._(map(m['basic_info'])),
      playability_status = switch (mapOrNull(m['playability_status'])) {
        final s? => IPlayabilityStatus._(s),
        null => null,
      },
      streaming_data = switch (mapOrNull(m['streaming_data'])) {
        final s? => IStreamingData._(yt, s),
        null => null,
      },
      page = [for (final p in list(m['page'])) IPlayerResponse._(map(p))],
      player_overlays = YTNodes.YTNode.fromJson(m['player_overlays']) as YTNodes.PlayerOverlay?,
      cpn = string(m['cpn']) ?? '';

  @internal
  static VideoInfo fromJson(YouTubei yt, Object? raw) => VideoInfo._(yt, map(raw));

  final BasicInfo basic_info;
  final IPlayabilityStatus? playability_status;
  final IStreamingData? streaming_data;
  final List<IPlayerResponse> page;

  /// From the next response, which only `getInfo` asks for: of the overlay,
  /// its player bar.
  final YTNodes.PlayerOverlay? player_overlays;

  /// The client playback nonce this info's streams are requested with.
  final String cpn;
}

final class Search {
  Search._(Json m)
    : results = YTNodes.YTNode.listFromJson(m['results']),
      estimated_results = integer(m['estimated_results']) ?? 0,
      has_continuation = boolean(m['has_continuation']) ?? false;

  @internal
  static Search fromJson(Object? raw) => Search._(map(raw));

  final List<YTNodes.YTNode> results;
  final int estimated_results;
  final bool has_continuation;
}

/// A playlist's `info`.
final class PlaylistInfo {
  PlaylistInfo._(Json m)
    : title = string(m['title']),
      description = string(m['description']),
      author = Author.fromJson(m['author']),
      thumbnails = Thumbnail.listFromJson(m['thumbnails']),
      total_items = string(m['total_items']);
  final String? title;
  final String? description;
  final Author? author;
  final List<Thumbnail> thumbnails;
  final String? total_items;
}

/// A playlist's `page`: of the browse response, its alerts.
final class IBrowseResponse {
  IBrowseResponse._(Json m) : alerts = YTNodes.YTNode.listFromJson(m['alerts']);
  final List<YTNodes.YTNode> alerts;
}

/// One page of a playlist, live in YouTube.js until this object is collected.
final class Playlist {
  Playlist._(this._yt, Json m)
    : _handle = m[r'$handle']! as int,
      info = PlaylistInfo._(map(m['info'])),
      items = YTNodes.YTNode.listFromJson(m['items']),
      has_continuation = boolean(m['has_continuation']) ?? false,
      is_complete = boolean(m['is_complete']) ?? false,
      page = IBrowseResponse._(map(m['page'])) {
    retainHandle(_yt, this, _handle);
  }

  @internal
  static Playlist fromJson(YouTubei yt, Object? raw) => Playlist._(yt, map(raw));

  /// `new YT.Playlist(actions, data, already_parsed)`: a playlist from a
  /// browse response, such as one [Actions.execute] got with parameters of
  /// its own.
  static Future<Playlist> create(Actions actions, ApiResponse data, {bool already_parsed = false, CancellationToken? token}) async =>
    Playlist._(actions.yt, map(await callYouTubei(actions.yt, '__bridge.newPlaylist', {'data': data.handle, 'already_parsed': already_parsed}, token: token)));

  final YouTubei _yt;
  final int _handle;

  final PlaylistInfo info;

  /// The listing in source order: PlaylistVideo and LockupView nodes, and
  /// any other node as YouTube.js parsed it.
  final List<YTNodes.YTNode> items;
  final bool has_continuation;

  /// Whether every member YouTube.js read survived parsing (a fork
  /// extension).
  final bool is_complete;
  final IBrowseResponse page;

  Future<Playlist> getContinuation({CancellationToken? token}) async =>
    Playlist._(_yt, map(await callYouTubei(_yt, '__bridge.getContinuation', {'playlist': _handle}, token: token)));
}

/// A channel's `metadata`: its ChannelMetadata with its microformat.
final class ChannelMetadata {
  ChannelMetadata._(Json m)
    : title = string(m['title']),
      description = string(m['description']),
      url = string(m['url']),
      external_id = string(m['external_id']),
      vanity_channel_url = string(m['vanity_channel_url']),
      avatar = Thumbnail.listFromJson(m['avatar']),
      thumbnail = Thumbnail.listFromJson(m['thumbnail']);
  final String? title;
  final String? description;
  final String? url;
  final String? external_id;
  final String? vanity_channel_url;
  final List<Thumbnail> avatar;
  final List<Thumbnail> thumbnail;
}

final class Channel {
  Channel._(Json m) : metadata = ChannelMetadata._(map(m['metadata']));

  @internal
  static Channel fromJson(Object? raw) => Channel._(map(raw));

  final ChannelMetadata metadata;
}
