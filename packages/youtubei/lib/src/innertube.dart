// YouTube.js's Innertube (src/Innertube.ts), Session, Actions and Player, by
// their upstream names. Each runs its own YouTube.js, in QuickJS in an
// isolate of its own: close it when done. Where YouTube.js takes an
// AbortSignal, these take a CancellationToken.
// ignore_for_file: non_constant_identifier_names, constant_identifier_names
import 'dart:io';
import 'dart:typed_data';

import 'package:cancellation_token/cancellation_token.dart';
import 'package:meta/meta.dart';

import 'engine.dart';
import 'fetch.dart';
import 'json.dart';
import 'utils.dart';
import 'yt.dart' as YT; // ignore: library_prefixes
import 'yt_nodes.dart' as YTNodes; // ignore: library_prefixes

/// The client a request is made as (`InnerTubeClient`).
enum InnerTubeClient {
  IOS,
  WEB,
  MWEB,
  ANDROID,
  ANDROID_VR,
  VISIONOS,
  YTMUSIC,
  YTMUSIC_ANDROID,
  YTSTUDIO_ANDROID,
  TV,
  TV_SIMPLY,
  TV_EMBEDDED,
  YTKIDS,
  WEB_EMBEDDED,
  WEB_CREATOR,
}

/// The session's client (`ClientType`).
enum ClientType {
  WEB('WEB'),
  MWEB('MWEB'),
  KIDS('WEB_KIDS'),
  MUSIC('WEB_REMIX'),
  IOS('iOS'),
  ANDROID('ANDROID'),
  ANDROID_VR('ANDROID_VR'),
  VISIONOS('VISIONOS'),
  ANDROID_MUSIC('ANDROID_MUSIC'),
  ANDROID_CREATOR('ANDROID_CREATOR'),
  TV('TVHTML5'),
  TV_SIMPLY('TVHTML5_SIMPLY'),
  TV_EMBEDDED('TVHTML5_SIMPLY_EMBEDDED_PLAYER'),
  WEB_EMBEDDED('WEB_EMBEDDED_PLAYER'),
  WEB_CREATOR('WEB_CREATOR');

  const ClientType(this.value);
  final String value;
}

/// YouTube.js's Constants, read from it once the first Innertube starts.
abstract final class Constants {
  /// Each client's NAME, VERSION and, for some, USER_AGENT, by its key
  /// (`VISIONOS`, `TV`…).
  static Map<String, Map<String, Object?>> get CLIENTS =>
    _clients ?? (throw StateError('Constants are read when the first Innertube starts'));
  static Map<String, Map<String, Object?>>? _clients;
}

/// The JavaScript player, live in YouTube.js until this object is collected.
final class Player {
  Player._(this._yt, Json m)
    : handle = m[r'$handle']! as int,
      player_id = string(m['player_id']) ?? '',
      signature_timestamp = integer(m['signature_timestamp']) ?? 0,
      po_token = string(m['po_token']),
      url = string(m['url']) ?? '' {
    retainHandle(_yt, this, handle);
  }

  final YouTubei _yt;
  @internal
  final int handle;

  final String player_id;
  final int signature_timestamp;
  final String? po_token;
  final String url;
}

final class Session {
  Session._(YouTubei yt, Json m)
    : user_agent = string(m['user_agent']),
      logged_in = boolean(m['logged_in']) ?? false,
      player = switch (mapOrNull(m['player'])) {
        final p? => Player._(yt, p),
        null => null,
      };

  /// The user agent InnerTube requests are made with.
  final String? user_agent;
  final bool logged_in;

  /// The player, when the session retrieved it (`retrieve_player`).
  final Player? player;
}

/// A raw InnerTube response, live in YouTube.js until this object is
/// collected.
final class ApiResponse {
  ApiResponse._(YouTubei yt, Json m)
    : handle = m[r'$handle']! as int,
      success = boolean(m['success']) ?? false,
      status_code = integer(m['status_code']) ?? 0 {
    retainHandle(yt, this, handle);
  }

  @internal
  final int handle;
  final bool success;
  final int status_code;
}

final class Actions {
  Actions._(this.yt);

  @internal
  final YouTubei yt;

  /// Calls InnerTube's [endpoint] (`/browse`, `/player`…) with [args].
  Future<ApiResponse> execute(String endpoint, Map<String, Object?> args, {CancellationToken? token}) async =>
    ApiResponse._(yt, map(await callYouTubei(yt, '__bridge.execute', {'endpoint': endpoint, 'args': args}, token: token)));
}

final class Innertube {
  Innertube._(this._yt, this.session, this._http) : actions = Actions._(_yt);

  final YouTubei _yt;
  final HttpClient? _http;
  final Session session;
  final Actions actions;

  /// Starts YouTube.js and creates a session, with YouTube.js's options and
  /// defaults. Without [fetch], requests go through a dart:io HttpClient.
  /// [timezone] is an IANA zone (`Europe/Berlin`): QuickJS has no Intl to
  /// read the system's from. [log] receives YouTube.js's log lines.
  /// [bundle] is the source of a YouTube.js release for [Bundle.abi] to run
  /// instead of the built-in bundle; one that fails to evaluate throws a
  /// [BundleError].
  static Future<Innertube> create({
    String? lang,
    String? location,
    String? user_agent,
    int? account_index,
    String? on_behalf_of_user,
    bool? retrieve_player,
    bool? enable_safety_mode,
    bool? retrieve_innertube_config,
    bool? generate_session_locally,
    bool? fail_fast,
    bool? enable_session_cache,
    String? device_category,
    ClientType? client_type,
    String? timezone,
    UniversalCache? cache,
    String? cookie,
    String? visitor_data,
    Fetch? fetch,
    String? po_token,
    YouTubeiLog? log,
    Uint8List? bundle,
    CancellationToken? token,
  }) async {
    final http = fetch == null ? (HttpClient()..userAgent = null) : null;
    final YouTubei yt;
    try {
      yt = await startYouTubei(fetch ?? httpClientFetch(http!), bundle: bundle, token: token, log: log);
    } catch (_) {
      http?.close(force: true);
      rethrow;
    }
    try {
      final created = map(await callYouTubei(yt, '__bridge.create', {
        'lang': ?lang,
        'location': ?location,
        'user_agent': ?user_agent,
        'account_index': ?account_index,
        'on_behalf_of_user': ?on_behalf_of_user,
        'retrieve_player': ?retrieve_player,
        'enable_safety_mode': ?enable_safety_mode,
        'retrieve_innertube_config': ?retrieve_innertube_config,
        'generate_session_locally': ?generate_session_locally,
        'fail_fast': ?fail_fast,
        'enable_session_cache': ?enable_session_cache,
        'device_category': ?device_category,
        'client_type': ?client_type?.value,
        'timezone': ?timezone,
        if (cache != null)
          'cache': {'persistent': cache.persistent, 'persistent_directory': cache.persistent_directory, 'cache_dir': cache.cache_dir},
        'cookie': ?cookie,
        'visitor_data': ?visitor_data,
        'po_token': ?po_token,
      }, token: token));
      Constants._clients ??= {
        for (final MapEntry(:key, :value) in map(map(created['constants'])['CLIENTS']).entries) key: map(value),
      };
      return Innertube._(yt, Session._(yt, map(created['session'])), http);
    } catch (_) {
      await closeYouTubei(yt);
      http?.close(force: true);
      rethrow;
    }
  }

  /// Stops this YouTube.js once calls already made finish. Not in
  /// YouTube.js, which a JavaScript runtime collects.
  Future<void> close() async {
    await closeYouTubei(_yt);
    _http?.close(force: true);
  }

  /// A video's player response alone, as [client].
  Future<YT.VideoInfo> getBasicInfo(String video_id, {InnerTubeClient? client, String? po_token, CancellationToken? token}) async =>
    YT.VideoInfo.fromJson(_yt, await callYouTubei(_yt, '__bridge.getBasicInfo', {
      'video_id': video_id,
      'options': {'client': ?client?.name, 'po_token': ?po_token},
    }, token: token));

  /// A video's player and next responses, as [client] for the player's.
  Future<YT.VideoInfo> getInfo(String target, {InnerTubeClient? client, String? po_token, CancellationToken? token}) async =>
    YT.VideoInfo.fromJson(_yt, await callYouTubei(_yt, '__bridge.getInfo', {
      'target': target,
      'options': {'client': ?client?.name, 'po_token': ?po_token},
    }, token: token));

  Future<YT.Search> search(String query, {CancellationToken? token}) async =>
    YT.Search.fromJson(await callYouTubei(_yt, '__bridge.search', {'query': query, 'filters': const <String, Object?>{}}, token: token));

  Future<YT.Playlist> getPlaylist(String id, {CancellationToken? token}) async =>
    YT.Playlist.fromJson(_yt, await callYouTubei(_yt, '__bridge.getPlaylist', {'id': id}, token: token));

  Future<YT.Channel> getChannel(String id, {CancellationToken? token}) async =>
    YT.Channel.fromJson(await callYouTubei(_yt, '__bridge.getChannel', {'id': id}, token: token));

  /// Where a youtube.com link leads: its endpoint, whose payload names a
  /// channel's `browseId` or a video's `videoId`.
  Future<YTNodes.NavigationEndpoint> resolveURL(String url, {CancellationToken? token}) async =>
    YTNodes.YTNode.fromJson(await callYouTubei(_yt, '__bridge.resolveURL', {'url': url}, token: token))!
      as YTNodes.NavigationEndpoint;
}
