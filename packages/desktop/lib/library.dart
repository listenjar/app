// The listener's podcast library on this device: the shows they follow,
// every episode their feeds list, where they stopped in each, what is
// downloaded, the Up Next queue and the player's settings. One SQLite file
// (library.sqlite) in the app's support directory; no account needed, and
// nothing in it leaves the device. Queries are synchronous (package:sqlite3
// over FFI) and small, so widgets read straight from it on build; every
// change notifies once. No widgets here.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import 'backend/api.dart' show SourceKind;
import 'chapters.dart';
import 'directory.dart' show AppleEpisodeArt;
import 'links.dart';
import 'migrations.dart';

import 'rss.dart';

/// What a show in the library is.
enum PodcastKind {
  /// A podcast's RSS feed, a Listenjar feed among them.
  rss,

  /// A single YouTube video kept as a show of one episode, on this device
  /// only.
  youtube,

  /// A YouTube playlist or channel followed on this device only: its videos
  /// stream from YouTube, and refreshing lists the new ones. In Listenjar
  /// Cloud instead, it is an [rss] show.
  youtubeFeed,

  /// A podcast of the listener's own on this device only: YouTube videos
  /// they gathered, which stream from YouTube as they play. In Listenjar
  /// Cloud instead, it is an [rss] show.
  own,
}

/// A video a YouTube playlist or channel lists, as the library keeps it.
typedef YouTubeVideo = ({String id, String title, int? seconds});

/// A show the listener follows.
final class Podcast {
  const Podcast({
    required this.id,
    required this.feedUrl,
    required this.kind,
    required this.title,
    required this.author,
    required this.description,
    required this.artworkUrl,
    required this.link,
    required this.subscribedAt,
    required this.refreshedAt,
    required this.refreshError,
    required this.cloudFeedId,
    required this.autoDownload,
    required this.followed,
    required this.unplayed,
    required this.latestAt,
    required this.serial,
    required this.appleId,
    required this.appleCheckedAt,
  });

  final int id;
  final String feedUrl;
  final PodcastKind kind;
  final String title;
  final String author;
  final String description;
  final String? artworkUrl;
  final String? link;
  final DateTime subscribedAt;
  final DateTime? refreshedAt;

  /// Why the last refresh failed, until one succeeds.
  final String? refreshError;

  /// The listener's Listenjar feed this is, while they are signed in.
  final String? cloudFeedId;
  final bool autoDownload;

  /// False for a show looked at from search, or a YouTube video played from
  /// it, that the listener hasn't followed: kept while something of it is
  /// playing, queued or downloaded.
  final bool followed;
  final int unplayed;
  final DateTime? latestAt;

  /// Its episodes go in order of their numbers, not their dates: a YouTube
  /// playlist's, in the playlist's order.
  final bool serial;

  /// The show's id in Apple's podcast directory, whose copies of its
  /// episodes' artwork the rows show ([PodcastEpisode.appleArtworkUrl]):
  /// null until looked for, 0 when Apple lists no show at its feed.
  final int? appleId;

  /// When Apple was last asked about the show.
  final DateTime? appleCheckedAt;

  /// A single YouTube video kept as a show of its own.
  bool get isYouTube => kind == PodcastKind.youtube;

  /// Straight from YouTube, not a podcast feed: a video or a followed
  /// playlist or channel.
  bool get fromYouTube => kind != PodcastKind.rss;

  /// A podcast of the listener's own on this device.
  bool get isOwn => kind == PodcastKind.own;

  /// Gets new episodes by refreshing: a feed, a playlist or a channel.
  bool get refreshes => kind == PodcastKind.rss || kind == PodcastKind.youtubeFeed;
}

enum DownloadState { none, queued, downloading, done, failed }

/// An episode of a show in the library, with the listener's place in it.
final class PodcastEpisode {
  const PodcastEpisode({
    required this.id,
    required this.podcastId,
    required this.guid,
    required this.title,
    required this.publishedAt,
    required this.duration,
    required this.audioUrl,
    required this.audioType,
    required this.audioBytes,
    required this.artworkUrl,
    required this.appleArtworkUrl,
    required this.link,
    required this.youtubeId,
    required this.season,
    required this.number,
    required this.position,
    required this.played,
    required this.downloadPath,
    required this.downloadState,
    required this.downloadProgress,
    required this.downloadError,
    required this.podcastTitle,
    required this.podcastAuthor,
    required this.podcastArtworkUrl,
  });

  final int id;
  final int podcastId;
  final String guid;
  final String title;
  final DateTime? publishedAt;
  final Duration? duration;

  /// Null for a YouTube video, whose stream is looked up when it plays.
  final String? audioUrl;
  final String? audioType;
  final int? audioBytes;
  final String? artworkUrl;

  /// Apple's copy of the episode's artwork, which loads where the feed's
  /// image host may not, at 600 px rather than the feed's original.
  final String? appleArtworkUrl;
  final String? link;
  final String? youtubeId;
  final int? season;
  final int? number;

  /// Where the listener stopped; zero when they haven't started or finished.
  final Duration position;
  final bool played;
  final String? downloadPath;
  final DownloadState downloadState;
  final double downloadProgress;
  final String? downloadError;
  final String podcastTitle;
  final String podcastAuthor;
  final String? podcastArtworkUrl;

  /// Where the episode comes from, as a line under its title: its show, or
  /// for a YouTube video that is a show of its own, the channel.
  String get from => podcastTitle == title && podcastAuthor.isNotEmpty ? podcastAuthor : podcastTitle;

  bool get downloaded => downloadState == DownloadState.done && downloadPath != null;
  bool get started => position > Duration.zero && !played;

  /// The YouTube video the episode is: a video added on its own, or a feed
  /// episode whose link is one (a podcast of the listener's own).
  String? get videoId => youtubeId ?? switch (link) {
    final link? => switch (parseYouTubeLink(link)) {
      YouTubeLink(kind: SourceKind.video, :final id) => id,
      _ => null,
    },
    null => null,
  };

  /// Small square art: a video's thumbnail, as the episode rows show it,
  /// else Apple's copy of the episode's picture, else the feed's, else the
  /// show's.
  String? get artwork => switch (videoId) {
    final id? => videoThumbnail(id),
    null => appleArtworkUrl ?? artworkUrl ?? podcastArtworkUrl,
  };

  /// Whether the cover is a video's 16:9 frame.
  bool get widescreen => videoId != null;

  /// The big cover: a video's sharpest frame, else [artwork].
  String? get cover => switch (videoId) {
    final id? => 'https://i.ytimg.com/vi/$id/maxresdefault.jpg',
    // Apple's image servers draw any size up to the original: the name's
    // last part says which.
    null => appleArtworkUrl?.replaceFirstMapped(RegExp(r'/\d+x\d+bb\.(\w+)$'), (m) => '/1200x1200bb.${m[1]}') ?? artwork,
  };

  /// What [cover] falls back to when a video has no 1280×720 frame:
  /// hqdefault, there for every video, whose 4:3 letterbox bars the 16:9
  /// frame crops away.
  String? get coverFallback => switch (videoId) {
    final id? => 'https://i.ytimg.com/vi/$id/hqdefault.jpg',
    null => null,
  };

  /// What's left to hear, when the length is known.
  Duration? get remaining => switch (duration) {
    final d? when started => d - position,
    final d => d,
  };
}

/// The player's settings, kept with the library.
final class PlayerSettings {
  const PlayerSettings({
    this.speed = 1.0,
    this.skipBack = const Duration(seconds: 15),
    this.skipForward = const Duration(seconds: 30),
    this.remoteSkips = true,
    this.autoDownload = false,
    this.wifiOnly = true,
    this.removePlayedAfter = Duration.zero,
    this.removeUnplayedAfter,
    this.storageLimit,
  });

  /// Playback speed, 0.5 to 3.
  final double speed;
  final Duration skipBack;
  final Duration skipForward;

  /// Headphone and keyboard next/previous skip within the episode, like
  /// most podcast players, instead of changing episodes.
  final bool remoteSkips;

  /// New episodes of every show download as they arrive.
  final bool autoDownload;

  /// Automatic downloads wait for Wi-Fi (Android and iOS).
  final bool wifiOnly;

  /// How long a played episode's download stays: zero deletes it once the
  /// episode ends, null keeps it.
  final Duration? removePlayedAfter;

  /// Downloads not played, or since downloaded, for this long are deleted;
  /// null keeps them.
  final Duration? removeUnplayedAfter;

  /// Bytes downloads may take before the least recently used go; null for
  /// no limit.
  final int? storageLimit;

  PlayerSettings copyWith({
    double? speed,
    Duration? skipBack,
    Duration? skipForward,
    bool? remoteSkips,
    bool? autoDownload,
    bool? wifiOnly,
    Object? removePlayedAfter = _same,
    Object? removeUnplayedAfter = _same,
    Object? storageLimit = _same,
  }) => PlayerSettings(
    speed: speed ?? this.speed,
    skipBack: skipBack ?? this.skipBack,
    skipForward: skipForward ?? this.skipForward,
    remoteSkips: remoteSkips ?? this.remoteSkips,
    autoDownload: autoDownload ?? this.autoDownload,
    wifiOnly: wifiOnly ?? this.wifiOnly,
    removePlayedAfter: identical(removePlayedAfter, _same) ? this.removePlayedAfter : removePlayedAfter as Duration?,
    removeUnplayedAfter: identical(removeUnplayedAfter, _same) ? this.removeUnplayedAfter : removeUnplayedAfter as Duration?,
    storageLimit: identical(storageLimit, _same) ? this.storageLimit : storageLimit as int?,
  );
}

/// What [PlayerSettings.copyWith] takes for a nullable setting left as is.
const _same = Object();

/// A finished download, with when it was last used: played, or else
/// downloaded.
typedef StoredDownload = ({PodcastEpisode episode, DateTime? playedAt, DateTime lastUsed});

/// How a show's episodes are listed.
enum EpisodeFilter { all, unplayed, downloaded }


final class Library extends ChangeNotifier {
  Library._(this._db, this.directory) {
    _load();
  }

  final Database _db;

  /// The app's support directory; downloads live in `episodes/` under it.
  final Directory directory;

  static Future<Library> open() async {
    final support = await getApplicationSupportDirectory();
    await support.create(recursive: true);
    final db = sqlite3.open('${support.path}/library.sqlite')
      ..execute('pragma journal_mode = wal')
      ..execute('pragma foreign_keys = on');
    await migrate(db, 'library', support);
    return Library._(db, support);
  }

  /// The source of an episode with [youtubeId] or [link], in a show made of
  /// sources: its canonical URL ([canonicalSourceUrl]).
  static String? _sourceOf({String? youtubeId, String? link}) => switch ((youtubeId, link)) {
    (final id?, _) => _watchUrl(id),
    (null, final link?) => canonicalSourceUrl(link),
    _ => null,
  };

  /// Keys [podcast]'s episodes by source, a show made of sources from now
  /// on: of several made from one source, one stays, the copy its Listenjar
  /// feed has, else the one listened to, with where the listener was, Up
  /// Next and Now Playing moved to it. Returns the download paths of those
  /// that went, to delete. Run inside a transaction.
  static List<String> _keySources(Database db, int podcast) {
    final rows = db.select('''
      select e.id, e.youtube_id, e.link, e.audio_url, e.download_state, e.download_path, e.played, e.position_ms,
        e.played_at, e.id in (select episode_id from queue) as queued,
        e.id in (select episode_id from now_playing where episode_id is not null) as playing
      from episodes e where e.podcast_id = ?
    ''', [podcast]);
    final bySource = <String, List<Row>>{};
    for (final r in rows) {
      if (_sourceOf(youtubeId: r['youtube_id'] as String?, link: r['link'] as String?) case final source?) {
        (bySource[source] ??= []).add(r);
      }
    }
    final dropped = <String>[];
    int rank(Row r) =>
      (r['audio_url'] != null ? 16 : 0) + (r['download_state'] == 'done' ? 8 : 0) + (r['playing'] == 1 ? 4 : 0) +
      (r['queued'] == 1 ? 2 : 0) + (r['position_ms'] as int > 0 || r['played'] == 1 ? 1 : 0);
    for (final MapEntry(key: source, value: same) in bySource.entries) {
      same.sort((a, b) => switch (rank(b).compareTo(rank(a))) {
        0 => (a['id'] as int).compareTo(b['id'] as int),
        final c => c,
      });
      final keep = same.first['id'] as int;
      final others = same.skip(1).toList();
      if (others.isNotEmpty) {
        final last = [...same]..sort((a, b) => ((b['played_at'] as int?) ?? 0).compareTo((a['played_at'] as int?) ?? 0));
        final played = same.any((r) => r['played'] == 1);
        db.execute(
          'update episodes set played = ?, position_ms = ?, played_at = ? where id = ?',
          [played ? 1 : 0, played ? 0 : last.first['position_ms'], last.first['played_at'], keep],
        );
        for (final r in others) {
          final id = r['id'] as int;
          if (r['queued'] == 1) db.execute('update or ignore queue set episode_id = ? where episode_id = ?', [keep, id]);
          if (r['playing'] == 1) db.execute('update now_playing set episode_id = ? where id = 1', [keep]);
          if (r['download_path'] case final String path when path != same.first['download_path']) dropped.add(path);
          db.execute('delete from episodes where id = ?', [id]);
        }
      }
      db.execute('update episodes set source_url = ? where id = ?', [source, keep]);
    }
    return dropped;
  }

  List<Podcast> _podcasts = const [];
  List<Podcast> _followed = const [];
  late PlayerSettings _settings;

  /// The shows the listener follows, most recently updated first.
  List<Podcast> get podcasts => _followed;
  PlayerSettings get settings => _settings;

  void _load() {
    _podcasts = _db.select('''
      select p.*,
        (select count(*) from episodes e where e.podcast_id = p.id and e.played = 0) as unplayed,
        (select max(published_at) from episodes e where e.podcast_id = p.id) as latest_at
      from podcasts p
      order by coalesce(latest_at, p.subscribed_at) desc
    ''').map(_podcast).toList();
    _followed = _podcasts.where((p) => p.followed).toList();
    final kv = {for (final row in _db.select('select key, value from settings')) row['key'] as String: row['value'] as String};
    const d = PlayerSettings();
    _settings = PlayerSettings(
      speed: double.tryParse(kv['speed'] ?? '') ?? d.speed,
      skipBack: Duration(seconds: int.tryParse(kv['skip_back'] ?? '') ?? d.skipBack.inSeconds),
      skipForward: Duration(seconds: int.tryParse(kv['skip_forward'] ?? '') ?? d.skipForward.inSeconds),
      remoteSkips: (kv['remote_skips'] ?? '${d.remoteSkips}') == 'true',
      autoDownload: (kv['auto_download'] ?? '${d.autoDownload}') == 'true',
      wifiOnly: (kv['wifi_only'] ?? '${d.wifiOnly}') == 'true',
      // Before remove_played_after, a switch: delete played downloads or not.
      removePlayedAfter: switch (kv['remove_played_after']) {
        final v? => _seconds(v),
        null => kv['delete_played'] == 'false' ? null : d.removePlayedAfter,
      },
      removeUnplayedAfter: switch (kv['remove_unplayed_after']) {
        final v? => _seconds(v),
        null => d.removeUnplayedAfter,
      },
      storageLimit: switch (int.tryParse(kv['storage_limit_bytes'] ?? '')) {
        final b? when b > 0 => b,
        _ => d.storageLimit,
      },
    );
  }

  void _changed() {
    _load();
    notifyListeners();
  }

  /// The library's database, for keeping it in step with Listenjar Cloud
  /// (library_sync.dart), which calls [reload] after changing it.
  Database get database => _db;
  void reload() => _changed();

  static Podcast _podcast(Row r) => Podcast(
    id: r['id'] as int,
    feedUrl: r['feed_url'] as String,
    kind: PodcastKind.values.byName(r['kind'] as String),
    title: r['title'] as String,
    author: r['author'] as String,
    description: r['description'] as String,
    artworkUrl: r['artwork_url'] as String?,
    link: r['link'] as String?,
    subscribedAt: DateTime.fromMillisecondsSinceEpoch(r['subscribed_at'] as int),
    refreshedAt: _time(r['refreshed_at']),
    refreshError: r['refresh_error'] as String?,
    cloudFeedId: r['cloud_feed_id'] as String?,
    autoDownload: r['auto_download'] == 1,
    followed: r['followed'] == 1,
    unplayed: r['unplayed'] as int? ?? 0,
    latestAt: _time(r['latest_at']),
    serial: r['serial'] == 1,
    appleId: r['apple_id'] as int?,
    appleCheckedAt: _time(r['apple_checked_at']),
  );

  /// A stored duration: whole seconds, negative for none.
  static Duration? _seconds(String value) => switch (int.tryParse(value)) {
    final s? when s >= 0 => Duration(seconds: s),
    _ => null,
  };

  static DateTime? _time(Object? ms) => ms is int ? DateTime.fromMillisecondsSinceEpoch(ms) : null;

  static const _episodeColumns = '''
    e.id, e.podcast_id, e.guid, e.title, e.published_at, e.duration_ms, e.audio_url, e.audio_type,
    e.audio_bytes, e.artwork_url, e.apple_artwork_url, e.link, e.youtube_id, e.season, e.number, e.position_ms, e.played,
    e.download_path, e.download_state, e.download_progress, e.download_error,
    p.title as podcast_title, p.author as podcast_author, p.artwork_url as podcast_artwork_url
  ''';

  static PodcastEpisode _episode(Row r) => PodcastEpisode(
    id: r['id'] as int,
    podcastId: r['podcast_id'] as int,
    guid: r['guid'] as String,
    title: r['title'] as String,
    publishedAt: _time(r['published_at']),
    duration: switch (r['duration_ms']) {
      final int ms when ms > 0 => Duration(milliseconds: ms),
      _ => null,
    },
    audioUrl: r['audio_url'] as String?,
    audioType: r['audio_type'] as String?,
    audioBytes: r['audio_bytes'] as int?,
    artworkUrl: r['artwork_url'] as String?,
    appleArtworkUrl: r['apple_artwork_url'] as String?,
    link: r['link'] as String?,
    youtubeId: r['youtube_id'] as String?,
    season: r['season'] as int?,
    number: r['number'] as int?,
    position: Duration(milliseconds: r['position_ms'] as int),
    played: r['played'] == 1,
    downloadPath: r['download_path'] as String?,
    downloadState: DownloadState.values.byName(r['download_state'] as String),
    downloadProgress: (r['download_progress'] as num).toDouble(),
    downloadError: r['download_error'] as String?,
    podcastTitle: r['podcast_title'] as String,
    podcastAuthor: r['podcast_author'] as String? ?? '',
    podcastArtworkUrl: r['podcast_artwork_url'] as String?,
  );

  List<PodcastEpisode> _episodes(String where, [List<Object?> args = const [], String order = 'e.published_at desc, e.id desc', int? limit]) =>
    _db.select(
      'select $_episodeColumns from episodes e join podcasts p on p.id = e.podcast_id '
      'where $where order by $order${limit == null ? '' : ' limit $limit'}',
      args,
    ).map(_episode).toList();

  /// Any show in the library, followed or not.
  Podcast? podcast(int id) => _podcasts.where((p) => p.id == id).firstOrNull;

  /// The show at [feedUrl], however it's spelled: `http` or `https`, the
  /// host's case, a trailing slash, YouTube's other links to the same
  /// playlist or channel ([canonicalSourceUrl]). One show per feed.
  Podcast? podcastByUrl(String feedUrl) {
    final url = canonicalSourceUrl(feedUrl);
    return _podcasts.where((p) => p.feedUrl == feedUrl).firstOrNull
      ?? _podcasts.where((p) => canonicalSourceUrl(p.feedUrl) == url).firstOrNull;
  }

  /// The show of the YouTube playlist or channel at [url]: followed here
  /// as it is, or the RSS show Listenjar hosts of it, whose `<link>` is
  /// its source (apps/backend/src/rss.ts). One show per source.
  Podcast? podcastBySource(String url) {
    final source = canonicalSourceUrl(url);
    return podcastByUrl(source)
      ?? _podcasts.where((p) => p.cloudFeedId != null && p.link != null && canonicalSourceUrl(p.link!) == source).firstOrNull;
  }

  /// Follows a show the listener was only looking at.
  void follow(int podcast) {
    _db.execute(
      'update podcasts set followed = 1, subscribed_at = ? where id = ? and followed = 0',
      [DateTime.now().millisecondsSinceEpoch, podcast],
    );
    _changed();
  }

  /// Forgets shows looked at but never followed, once nothing of theirs is
  /// playing, queued, downloaded or started.
  void forgetUnfollowed() {
    _db.execute('''
      delete from podcasts where followed = 0 and subscribed_at < ? and not exists (
        select 1 from episodes e where e.podcast_id = podcasts.id and (
          e.download_state != 'none' or e.position_ms > 0
          or e.id in (select episode_id from queue)
          or e.id in (select episode_id from now_playing where episode_id is not null)
        )
      )
    ''', [DateTime.now().subtract(const Duration(days: 1)).millisecondsSinceEpoch]);
    _changed();
  }

  /// [podcast]'s episodes, newest first unless [oldestFirst], or a serial
  /// show's last first unless [oldestFirst]; with a [query],
  /// only those whose title or show notes hold every one of its words.
  List<PodcastEpisode> episodes(int podcast, {EpisodeFilter filter = EpisodeFilter.all, bool oldestFirst = false, String query = ''}) {
    final words = query.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final where = [
      switch (filter) {
        EpisodeFilter.all => 'e.podcast_id = ?',
        EpisodeFilter.unplayed => 'e.podcast_id = ? and e.played = 0',
        EpisodeFilter.downloaded => "e.podcast_id = ? and e.download_state != 'none'",
      },
      for (final _ in words) r"(e.title like ? escape '\' or e.description like ? escape '\')",
    ].join(' and ');
    final args = <Object?>[
      podcast,
      for (final w in words) ...List.filled(2, '%${w.replaceAllMapped(RegExp(r'[\\%_]'), (m) => '\\${m[0]}')}%'),
    ];
    // A serial show's by number, those without one last.
    const number = 'case when p.serial = 1 then coalesce(e.number, 9223372036854775807) end';
    return _episodes(where, args, oldestFirst ? '$number asc, e.published_at asc, e.id asc' : '$number desc, e.published_at desc, e.id desc');
  }

  PodcastEpisode? episode(int id) => _episodes('e.id = ?', [id]).firstOrNull;

  /// The YouTube video [videoId] as an episode of its own, once it was
  /// played or kept from search ([addYouTubeVideo]).
  PodcastEpisode? youtubeVideo(String videoId) => _episodes('p.feed_url = ?', [_watchUrl(videoId)]).firstOrNull;

  /// The show notes of [id], HTML or text.
  String description(int id) =>
    _db.select('select description from episodes where id = ?', [id]).firstOrNull?['description'] as String? ?? '';

  /// Unplayed episodes of every show, newest first: what's new.
  List<PodcastEpisode> latest({int limit = 100}) => _episodes('e.played = 0', const [], 'e.published_at desc, e.id desc', limit);

  /// Episodes the listener stopped partway through, most recent first.
  List<PodcastEpisode> inProgress({int limit = 20}) =>
    _episodes('e.played = 0 and e.position_ms > 0', const [], 'e.played_at desc, e.id desc', limit);

  /// Every download, finished or not, newest first.
  List<PodcastEpisode> downloads() => _episodes("e.download_state != 'none'", const [], 'e.added_at desc, e.id desc');

  /// The episodes in Up Next, in order.
  List<PodcastEpisode> get queue {
    return _db.select(
      'select $_episodeColumns from queue q join episodes e on e.id = q.episode_id '
      'join podcasts p on p.id = e.podcast_id order by q.position',
    ).map(_episode).toList();
  }

  bool queued(int episode) => _db.select('select 1 from queue where episode_id = ?', [episode]).isNotEmpty;

  // Following.

  /// Stores the feed at [feedUrl] and its episodes, followed if [follow]
  /// (a show already followed stays followed). Returns the show.
  Podcast subscribe(String feedUrl, ParsedFeed feed, {String? etag, String? lastModified, String? cloudFeedId, bool follow = true}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.execute('''
      insert into podcasts (feed_url, title, author, description, artwork_url, link, subscribed_at, refreshed_at, etag, last_modified, cloud_feed_id, followed, serial)
      values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      on conflict (feed_url) do update set
        title = excluded.title, author = excluded.author, description = excluded.description, serial = excluded.serial,
        artwork_url = excluded.artwork_url, link = excluded.link, refreshed_at = excluded.refreshed_at,
        etag = excluded.etag, last_modified = excluded.last_modified, refresh_error = null,
        cloud_feed_id = coalesce(excluded.cloud_feed_id, podcasts.cloud_feed_id),
        followed = max(podcasts.followed, excluded.followed),
        subscribed_at = case when podcasts.followed = 0 and excluded.followed = 1 then excluded.subscribed_at else podcasts.subscribed_at end
    ''', [feedUrl, feed.title, feed.author, feed.description, feed.artworkUrl, feed.link, now, now, etag, lastModified, cloudFeedId, follow ? 1 : 0, feed.serial ? 1 : 0]);
    final id = _db.select('select id from podcasts where feed_url = ?', [feedUrl]).first['id'] as int;
    final fresh = _db.select('select count(*) as n from episodes where podcast_id = ?', [id]).first['n'] == 0;
    _store(id, feed.episodes, playedBefore: fresh ? _newestCount : null);
    _changed();
    return podcast(id)!;
  }

  /// A new show's episodes beyond this many, counted from the newest, start
  /// played, so following a show with years of back catalogue doesn't fill
  /// what's new.
  static const _newestCount = 3;

  /// Stores [episodes] of [podcast] and updates the ones it has; returns the
  /// ids of the new ones. In a show Listenjar hosts, an episode still
  /// streaming from its source becomes the feed's once its upload is in
  /// it, matched by source URL ([canonicalSourceUrl]): the same row, so
  /// where the listener is, its download and its place in Up Next stay.
  List<int> _store(int podcast, List<ParsedEpisode> episodes, {int? playedBefore}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final sorted = [...episodes]..sort((a, b) => (b.publishedAt ?? DateTime(0)).compareTo(a.publishedAt ?? DateTime(0)));
    final known = {
      for (final row in _db.select('select guid from episodes where podcast_id = ?', [podcast])) row['guid'] as String,
    };
    // A Listenjar feed is made of sources, one episode each: the feed's
    // episode of a source here already, streaming or under a guid the feed
    // had for it before, is that row. Once the feed has its audio it plays
    // that, no longer the video ([PodcastEpisode.audioUrl]).
    final keyed = _db.select('select 1 from podcasts where id = ? and cloud_feed_id is not null', [podcast]).isNotEmpty;
    final bySource = <String, String>{
      if (keyed)
        for (final row in _db.select('select guid, source_url from episodes where podcast_id = ? and source_url is not null', [podcast]))
          row['source_url'] as String: row['guid'] as String,
    };
    final handOver = _db.prepare('update episodes set guid = ? where podcast_id = ? and guid = ?');
    final added = <int>[];
    // Of two the feed lists from one source, the first stays.
    final insert = _db.prepare('''
      insert into episodes (podcast_id, guid, title, description, published_at, duration_ms, audio_url, audio_type,
        audio_bytes, artwork_url, link, season, number, played, added_at, source_url)
      values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      on conflict do nothing
      returning id
    ''');
    final update = _db.prepare('''
      update or ignore episodes set title = ?, description = ?, published_at = ?, duration_ms = coalesce(?, duration_ms),
        audio_url = ?, audio_type = ?, audio_bytes = ?, artwork_url = ?, link = ?, season = ?, number = ?,
        source_url = ?, youtube_id = iif(? is null, youtube_id, null)
      where podcast_id = ? and guid = ?
    ''');
    _db.execute('begin');
    try {
      for (final (i, e) in sorted.indexed) {
        final source = keyed ? _sourceOf(link: e.link) : null;
        if (!known.contains(e.guid)) {
          if (bySource[source] case final was?) {
            handOver.execute([e.guid, podcast, was]);
            known
              ..remove(was)
              ..add(e.guid);
            bySource[source!] = e.guid;
          }
        }
        if (known.contains(e.guid)) {
          update.execute([
            e.title, e.description, e.publishedAt?.millisecondsSinceEpoch, e.duration?.inMilliseconds, e.audioUrl,
            e.audioType, e.audioBytes, e.artworkUrl, e.link, e.season, e.number, source, e.audioUrl, podcast, e.guid,
          ]);
          continue;
        }
        final rows = insert.select([
          podcast, e.guid, e.title, e.description, e.publishedAt?.millisecondsSinceEpoch, e.duration?.inMilliseconds,
          e.audioUrl, e.audioType, e.audioBytes, e.artworkUrl, e.link, e.season, e.number,
          playedBefore != null && i >= playedBefore ? 1 : 0, now, source,
        ]);
        if (rows.firstOrNull case final row?) {
          added.add(row['id'] as int);
          known.add(e.guid);
          if (source != null) bySource[source] = e.guid;
        }
      }
      _db.execute('commit');
    } catch (_) {
      _db.execute('rollback');
      rethrow;
    } finally {
      insert.close();
      update.close();
      handOver.close();
    }
    return added;
  }

  /// Whether any of [podcast]'s latest 200 episodes, as many as Apple's
  /// directory lists, lacks Apple's copy of its artwork.
  bool missesAppleArtwork(int podcast) => _db.select('''
    select 1 from (select apple_artwork_url from episodes where podcast_id = ? order by published_at desc limit 200)
    where apple_artwork_url is null limit 1
  ''', [podcast]).isNotEmpty;

  /// What Apple's directory answered for [podcast]: its id there (0 for
  /// none) and its copies of the episodes' artwork, matched by guid, else by
  /// audio URL.
  void appleAnswered(int podcast, int appleId, List<AppleEpisodeArt> art) {
    final byGuid = _db.prepare('update episodes set apple_artwork_url = ? where podcast_id = ? and guid = ?');
    final byAudio = _db.prepare('update episodes set apple_artwork_url = ? where podcast_id = ? and audio_url = ?');
    _db.execute('begin');
    try {
      for (final a in art) {
        if (a.guid case final guid?) byGuid.execute([a.artworkUrl, podcast, guid]);
        if ((a.guid == null || _db.updatedRows == 0) && a.audioUrl != null) byAudio.execute([a.artworkUrl, podcast, a.audioUrl]);
      }
      _db.execute(
        'update podcasts set apple_id = ?, apple_checked_at = ? where id = ?',
        [appleId, DateTime.now().millisecondsSinceEpoch, podcast],
      );
      _db.execute('commit');
    } catch (_) {
      _db.execute('rollback');
      rethrow;
    } finally {
      byGuid.close();
      byAudio.close();
    }
    _changed();
  }

  /// What a refresh found: the feed, unless it hadn't changed. Returns the
  /// new episodes.
  List<PodcastEpisode> refreshed(int podcast, FeedFetch fetch) {
    final now = DateTime.now().millisecondsSinceEpoch;
    var added = const <int>[];
    if (fetch.feed case final feed?) {
      _db.execute('''
        update podcasts set title = ?, author = ?, description = ?, artwork_url = coalesce(?, artwork_url), link = ?, serial = ?
        where id = ?
      ''', [feed.title, feed.author, feed.description, feed.artworkUrl, feed.link, feed.serial ? 1 : 0, podcast]);
      added = _store(podcast, feed.episodes);
    }
    final moved = fetch.feed?.newFeedUrl ?? fetch.url.toString();
    _db.execute(
      'update podcasts set refreshed_at = ?, refresh_error = null, etag = ?, last_modified = ? where id = ?',
      [now, fetch.etag, fetch.lastModified, podcast],
    );
    if (moved != podcastFeedUrl(podcast) && podcastByUrl(moved) == null) {
      _db.execute('update podcasts set feed_url = ? where id = ?', [moved, podcast]);
    }
    _changed();
    return [for (final id in added) ?episode(id)];
  }

  String? podcastFeedUrl(int podcast) =>
    _db.select('select feed_url from podcasts where id = ?', [podcast]).firstOrNull?['feed_url'] as String?;

  /// The validators of [podcast]'s last fetch.
  (String?, String?) validators(int podcast) {
    final row = _db.select('select etag, last_modified from podcasts where id = ?', [podcast]).firstOrNull;
    return (row?['etag'] as String?, row?['last_modified'] as String?);
  }

  void refreshFailed(int podcast, Object error) {
    _db.execute('update podcasts set refresh_error = ? where id = ?', ['$error', podcast]);
    _changed();
  }

  /// Keeps a YouTube video as a show of one episode, in the library if
  /// [follow].
  Podcast addYouTubeVideo({
    bool follow = true,
    required String videoId,
    required String title,
    required String channel,
    required String? artworkUrl,
    required Duration? duration,
    required String description,
    required DateTime? publishedAt,
  }) {
    final url = _watchUrl(videoId);
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.execute('''
      insert into podcasts (feed_url, kind, title, author, description, artwork_url, link, subscribed_at, refreshed_at, followed)
      values (?, 'youtube', ?, ?, ?, ?, ?, ?, ?, ?)
      on conflict (feed_url) do update set followed = max(podcasts.followed, excluded.followed)
    ''', [url, title, channel, description, artworkUrl, url, now, now, follow ? 1 : 0]);
    final id = _db.select('select id from podcasts where feed_url = ?', [url]).first['id'] as int;
    _db.execute('''
      insert into episodes (podcast_id, guid, title, description, published_at, duration_ms, artwork_url, link, youtube_id, added_at, source_url)
      values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      on conflict (podcast_id, guid) do update set
        description = case when episodes.description = '' then excluded.description else episodes.description end,
        published_at = coalesce(episodes.published_at, excluded.published_at)
    ''', [id, 'yt:$videoId', title, description, publishedAt?.millisecondsSinceEpoch, duration?.inMilliseconds, artworkUrl, url, videoId, now, url]);
    _changed();
    return podcast(id)!;
  }

  /// What YouTube says of [episode]'s video, once played or downloaded:
  /// its description and date where the episode has none, as for a video
  /// search or a playlist listed, which say neither.
  void fillVideoDetails(int episode, {required String description, required DateTime publishedAt}) {
    if (description.isEmpty) return;
    final changed = _db.select('''
      update episodes set description = ?, published_at = coalesce(published_at, ?)
      where id = ? and description = ''
      returning podcast_id
    ''', [description, publishedAt.millisecondsSinceEpoch, episode]);
    if (changed.isEmpty) return;
    // A video kept on its own is a show of one: its description is the show's.
    _db.execute(
      "update podcasts set description = ? where id = ? and kind = 'youtube' and description = ''",
      [description, changed.first['podcast_id']],
    );
    _changed();
  }

  /// The YouTube video [videoId]'s chapters as kept on this device, or null
  /// when YouTube hasn't answered for it yet.
  List<Chapter>? youtubeChapters(String videoId) {
    final row = _db.select('select chapters from youtube_chapters where video_id = ?', [videoId]).firstOrNull;
    if (row == null) return null;
    return [
      for (final c in jsonDecode(row['chapters'] as String) as List)
        if (c case [final int ms, final String title]) (start: Duration(milliseconds: ms), title: title),
    ];
  }

  /// Keeps what YouTube answered for [videoId]'s chapters, none among
  /// them. A video's chapters are kept once: the first answer stays.
  void keepYouTubeChapters(String videoId, List<Chapter> chapters) => _db.execute(
    'insert into youtube_chapters (video_id, chapters) values (?, ?) on conflict (video_id) do nothing',
    [videoId, jsonEncode([for (final c in chapters) [c.start.inMilliseconds, c.title]])],
  );

  /// Follows the YouTube playlist or channel at [url] on this device; a
  /// show already there is followed again.
  Podcast followYouTubeFeed({required String url, required String title, required String author, required String? artworkUrl}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.execute('''
      insert into podcasts (feed_url, kind, title, author, artwork_url, link, subscribed_at, followed)
      values (?, 'youtubeFeed', ?, ?, ?, ?, ?, 1)
      on conflict (feed_url) do update set followed = 1
    ''', [url, title, author, artworkUrl, url, now]);
    final id = _db.select('select id from podcasts where feed_url = ?', [url]).first['id'] as int;
    _changed();
    return podcast(id)!;
  }

  /// Stores the videos a YouTube playlist or channel lists now, as
  /// [YouTubeVideo]s in its order, and returns the episodes new to it. The
  /// first listing ([dated] false) is the back catalogue, undated, and all
  /// but its first few count as played, as a feed's do; videos found later
  /// are dated when they turned up, so they count as new. A playlist's
  /// ([numbered]) are numbered in its order, from 1, every time, and the
  /// show is serial: it lists them as the playlist does.
  List<PodcastEpisode> youtubeFeedRefreshed(int podcast, {required String? title, required String? artworkUrl, required List<YouTubeVideo> videos, required bool dated, required bool numbered}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final added = <int>[];
    _db.execute('begin');
    try {
      _db.execute(
        'update podcasts set title = coalesce(?, title), artwork_url = coalesce(?, artwork_url), refreshed_at = ?, refresh_error = null, serial = ? where id = ?',
        [title, artworkUrl, now, numbered ? 1 : 0, podcast],
      );
      // Oldest first, so the newest gets the highest id and lists first.
      for (final (i, v) in videos.indexed.toList().reversed) {
        final url = _watchUrl(v.id);
        // A video the show has already, uploaded to its Listenjar feed
        // under the feed's guid, is the same episode: one per source.
        final rows = _db.select('''
          insert into episodes (podcast_id, guid, title, published_at, duration_ms, link, youtube_id, played, added_at, source_url, number)
          values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          on conflict do nothing
          returning id
        ''', [
          podcast, 'yt:${v.id}', v.title, dated ? now : null, v.seconds == null ? null : v.seconds! * 1000, url, v.id,
          !dated && i >= _newestCount ? 1 : 0, now, url, numbered ? i + 1 : null,
        ]);
        if (rows.isNotEmpty) {
          added.add(rows.first['id'] as int);
        } else if (numbered) {
          // Moved in the playlist.
          _db.execute('update episodes set number = ? where podcast_id = ? and source_url = ? and number is not ?', [i + 1, podcast, url, i + 1]);
        }
      }
      _db.execute('commit');
    } catch (_) {
      _db.execute('rollback');
      rethrow;
    }
    _changed();
    return [for (final id in added) ?episode(id)];
  }

  // Podcasts of the listener's own on this device.

  /// Makes a podcast of the listener's own, empty until they add videos. On
  /// a plan with Listenjar Cloud it becomes a feed Listenjar hosts
  /// ([hostedAt]).
  Podcast createOwn(String title) {
    final now = DateTime.now();
    final rows = _db.select('''
      insert into podcasts (feed_url, kind, title, author, subscribed_at, refreshed_at, followed)
      values (?, 'own', ?, 'Podcast of your own', ?, ?, 1)
      returning id
    ''', ['listenjar:own:${now.microsecondsSinceEpoch}', title, now.millisecondsSinceEpoch, now.millisecondsSinceEpoch]);
    _changed();
    return podcast(rows.first['id'] as int)!;
  }

  /// Adds the YouTube video [videoId] to [podcast], a podcast of the
  /// listener's own, dated [addedAt] (now by default), as Listenjar Cloud
  /// dates what is added to one there. Null when it's already there,
  /// streaming or uploaded to its Listenjar feed: one episode per source.
  PodcastEpisode? addOwnVideo(int podcast, {required String videoId, required String title, Duration? duration, DateTime? addedAt}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final url = _watchUrl(videoId);
    final rows = _db.select('''
      insert into episodes (podcast_id, guid, title, published_at, duration_ms, link, youtube_id, added_at, source_url)
      values (?, ?, ?, ?, ?, ?, ?, ?, ?)
      on conflict do nothing
      returning id
    ''', [podcast, 'yt:$videoId', title, addedAt?.millisecondsSinceEpoch ?? now, duration?.inMilliseconds, url, videoId, now, url]);
    _changed();
    return rows.isEmpty ? null : episode(rows.first['id'] as int);
  }

  /// Takes [episode] out of a podcast of the listener's own.
  void removeEpisode(int episode) {
    _db.execute('delete from episodes where id = ?', [episode]);
    _changed();
  }

  void setArtwork(int podcast, String? artworkUrl) {
    _db.execute('update podcasts set artwork_url = ? where id = ?', [artworkUrl, podcast]);
    _changed();
  }

  /// [podcast], a YouTube playlist or channel or a podcast of the
  /// listener's own, now that Listenjar hosts it at [rssUrl]: a classic
  /// podcast of that feed from here on, which syncs between the listener's
  /// devices like any other (library_sync.dart). Its episodes stay as they
  /// are, streaming from their source, until the feed's refresh hands each
  /// its upload ([_store]). False, and nothing changes, when the feed is
  /// followed here already, as another show.
  bool hostedAt(int podcast, String rssUrl) {
    final there = podcastByUrl(rssUrl);
    if (there != null && there.id != podcast && there.followed) return false;
    _db.execute('begin');
    try {
      if (there != null && there.id != podcast) _db.execute('delete from podcasts where id = ?', [there.id]);
      _db.execute(
        "update podcasts set kind = 'rss', feed_url = ?, etag = null, last_modified = null, refresh_error = null where id = ?",
        [rssUrl, podcast],
      );
      _db.execute('commit');
    } catch (_) {
      _db.execute('rollback');
      rethrow;
    }
    _changed();
    return true;
  }

  /// Keeps [podcast], a Listenjar Cloud show whose feed is gone, on this
  /// device instead: the YouTube playlist or channel at [source], or with
  /// none a podcast of the listener's own. Its episodes become the YouTube
  /// videos they are, streaming from there; where the listener was, Up
  /// Next and downloads stay. [artworkUrl], when given, replaces the
  /// Cloud's, which went with the feed. False, and nothing changes, when
  /// [source] is followed here already.
  bool keepOnDevice(int podcast, {required String? source, String? artworkUrl}) {
    final there = source == null ? null : podcastByUrl(source);
    if (there != null && there.followed) return false;
    final now = DateTime.now();
    _db.execute('begin');
    try {
      // Once followed here and let go: this takes its place.
      if (there != null) _db.execute('delete from podcasts where id = ?', [there.id]);
      _db.execute('''
        update podcasts set kind = ?, feed_url = ?, link = ?, author = coalesce(?, author),
          artwork_url = coalesce(?, artwork_url), cloud_feed_id = null, etag = null, last_modified = null,
          refresh_error = null, refreshed_at = ?
        where id = ?
      ''', [
        source == null ? 'own' : 'youtubeFeed', source ?? 'listenjar:own:${now.microsecondsSinceEpoch}', source,
        source == null ? 'Podcast of your own' : null, artworkUrl, now.millisecondsSinceEpoch, podcast,
      ]);
      for (final e in episodes(podcast)) {
        final id = e.videoId;
        if (id == null) {
          _db.execute('delete from episodes where id = ?', [e.id]);
          continue;
        }
        // As a playlist's refresh and an own podcast's videos have them, so
        // neither adds it again.
        _db.execute(
          'update episodes set guid = ?, youtube_id = ?, link = ?, source_url = ?, audio_url = null, audio_type = null, audio_bytes = null where id = ?',
          ['yt:$id', id, _watchUrl(id), _watchUrl(id), e.id],
        );
      }
      _db.execute('commit');
    } catch (_) {
      _db.execute('rollback');
      rethrow;
    }
    _changed();
    return true;
  }

  static String _watchUrl(String videoId) => 'https://www.youtube.com/watch?v=$videoId';

  /// Stops following [podcast]; returns its downloads' files to delete.
  List<String> unsubscribe(int podcast) {
    final files = [
      for (final row in _db.select('select download_path from episodes where podcast_id = ? and download_path is not null', [podcast]))
        row['download_path'] as String,
    ];
    _db.execute('delete from podcasts where id = ?', [podcast]);
    _changed();
    return files;
  }

  void setAutoDownload(int podcast, bool on) {
    _db.execute('update podcasts set auto_download = ? where id = ?', [on ? 1 : 0, podcast]);
    _changed();
  }

  /// Links [podcast] to the listener's Listenjar feed, or unlinks it.
  /// A show linked to a feed is made of sources from then on, its episodes
  /// keyed by theirs ([_keySources]).
  void setCloudFeed(int podcast, String? feedId) {
    _db.execute('begin');
    try {
      _db.execute('update podcasts set cloud_feed_id = ? where id = ?', [feedId, podcast]);
      final files = feedId == null ? const <String>[] : _keySources(_db, podcast);
      _db.execute('commit');
      for (final path in files) {
        File('${directory.path}/$path').delete().ignore();
      }
    } catch (_) {
      _db.execute('rollback');
      rethrow;
    }
    _changed();
  }

  // Listening.

  /// Saves where the listener is in [episode], quietly: the position moves
  /// every few seconds while playing and nothing on screen lists by it.
  /// The length the player found, when the feed didn't say or was wrong.
  void setDuration(int episode, Duration duration) =>
    _db.execute('update episodes set duration_ms = ? where id = ?', [duration.inMilliseconds, episode]);

  void savePosition(int episode, Duration position, {bool notify = false}) {
    _db.execute(
      'update episodes set position_ms = ?, played_at = ? where id = ?',
      [position.inMilliseconds, DateTime.now().millisecondsSinceEpoch, episode],
    );
    if (notify) _changed();
  }

  void setPlayed(Iterable<int> episodes, bool played) {
    final ids = episodes.toList();
    if (ids.isEmpty) return;
    _db.execute(
      'update episodes set played = ?, position_ms = 0, played_at = ? where id in (${List.filled(ids.length, '?').join(',')})',
      [played ? 1 : 0, DateTime.now().millisecondsSinceEpoch, ...ids],
    );
    if (played) _db.execute('delete from queue where episode_id in (${List.filled(ids.length, '?').join(',')})', ids);
    _changed();
  }

  void setAllPlayed(int podcast, bool played) => setPlayed(
    [for (final row in _db.select('select id from episodes where podcast_id = ?', [podcast])) row['id'] as int],
    played,
  );

  int? get nowPlaying => _db.select('select episode_id from now_playing where id = 1').firstOrNull?['episode_id'] as int?;

  set nowPlaying(int? episode) =>
    _db.execute('insert into now_playing (id, episode_id) values (1, ?) on conflict (id) do update set episode_id = excluded.episode_id', [episode]);

  // Up Next.

  /// Puts [episode] first in Up Next.
  void playNext(int episode) {
    final first = _db.select('select min(position) as p from queue').first['p'] as num?;
    _db.execute(
      'insert into queue (episode_id, position) values (?, ?) on conflict (episode_id) do update set position = excluded.position',
      [episode, (first ?? 1) - 1],
    );
    _changed();
  }

  /// Puts [episodes] at the end of Up Next, in order.
  void playLast(Iterable<int> episodes) {
    var last = (_db.select('select max(position) as p from queue').first['p'] as num?) ?? 0;
    for (final id in episodes) {
      _db.execute('insert into queue (episode_id, position) values (?, ?) on conflict (episode_id) do nothing', [id, ++last]);
    }
    _changed();
  }

  void dequeue(int episode) {
    _db.execute('delete from queue where episode_id = ?', [episode]);
    _changed();
  }

  /// Moves the episode at [from] in Up Next to [to].
  void reorder(int from, int to) {
    final ids = [for (final e in queue) e.id];
    if (from < 0 || from >= ids.length) return;
    final moved = ids.removeAt(from);
    ids.insert(to.clamp(0, ids.length), moved);
    _db.execute('begin');
    for (final (i, id) in ids.indexed) {
      _db.execute('update queue set position = ? where episode_id = ?', [i.toDouble(), id]);
    }
    _db.execute('commit');
    _changed();
  }

  void clearQueue() {
    _db.execute('delete from queue');
    _changed();
  }

  /// Takes the first episode off Up Next.
  PodcastEpisode? takeNext() {
    final next = queue.firstOrNull;
    if (next != null) dequeue(next.id);
    return next;
  }

  // Downloads.

  void setDownload(int episode, DownloadState state, {String? path, double? progress, String? error, bool notify = true}) {
    _db.execute('''
      update episodes set download_state = ?, download_path = coalesce(?, download_path),
        download_progress = coalesce(?, download_progress), download_error = ?,
        downloaded_at = case when ? = 'done' and download_state != 'done' then ? else downloaded_at end
      where id = ?
    ''', [state.name, path, progress, error, state.name, DateTime.now().millisecondsSinceEpoch, episode]);
    if (state == DownloadState.none) {
      _db.execute('update episodes set download_path = null, download_progress = 0 where id = ?', [episode]);
    }
    if (notify) _changed();
  }

  /// Where [episode]'s download is on this device. Paths are kept relative
  /// to [directory], which iOS moves between launches.
  File? downloadFile(PodcastEpisode episode) => switch (episode.downloadPath) {
    final path? => File('${directory.path}/$path'),
    null => null,
  };

  /// Finished downloads, the longest unused first.
  List<StoredDownload> storedDownloads() => [
    for (final r in _db.select('''
      select $_episodeColumns, e.played_at,
        max(coalesce(e.played_at, 0), coalesce(e.downloaded_at, e.added_at)) as last_used
      from episodes e join podcasts p on p.id = e.podcast_id
      where e.download_state = 'done' and e.download_path is not null
      order by last_used, e.id
    '''))
      (episode: _episode(r), playedAt: _time(r['played_at']), lastUsed: _time(r['last_used'])!),
  ];

  /// Downloads that were running when the app last stopped.
  List<PodcastEpisode> unfinishedDownloads() =>
    _episodes("e.download_state in ('queued', 'downloading')", const [], 'e.id');

  // Settings.

  void updateSettings(PlayerSettings s) {
    final kv = {
      'speed': '${s.speed}',
      'skip_back': '${s.skipBack.inSeconds}',
      'skip_forward': '${s.skipForward.inSeconds}',
      'remote_skips': '${s.remoteSkips}',
      'auto_download': '${s.autoDownload}',
      'wifi_only': '${s.wifiOnly}',
      'remove_played_after': '${s.removePlayedAfter?.inSeconds ?? -1}',
      'remove_unplayed_after': '${s.removeUnplayedAfter?.inSeconds ?? -1}',
      'storage_limit_bytes': '${s.storageLimit ?? 0}',
    };
    for (final MapEntry(:key, :value) in kv.entries) {
      _db.execute('insert into settings (key, value) values (?, ?) on conflict (key) do update set value = excluded.value', [key, value]);
    }
    _changed();
  }

  @override
  void dispose() {
    _db.close();
    super.dispose();
  }
}

/// A YouTube video's thumbnail: 320×180, with no letterbox bars, and there
/// for every video.
String videoThumbnail(String videoId) => 'https://i.ytimg.com/vi/$videoId/mqdefault.jpg';
