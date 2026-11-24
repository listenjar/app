// The listener's podcast library on this device: the shows they follow,
// every episode their feeds list, where they stopped in each, what is
// downloaded, the Up Next queue and the player's settings. One SQLite file
// (library.sqlite) in the app's support directory; no account needed, and
// nothing in it leaves the device. Queries are synchronous (package:sqlite3
// over FFI) and small, so widgets read straight from it on build; every
// change notifies once. No widgets here.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import 'backend/api.dart' show SourceKind;
import 'links.dart';

import 'rss.dart';

/// What a show in the library is.
enum PodcastKind {
  /// A podcast's RSS feed, a ListenJar feed among them.
  rss,

  /// A single YouTube video kept as a show of one episode, on this device
  /// only.
  youtube,

  /// A YouTube playlist or channel followed on this device only: its videos
  /// stream from YouTube, and refreshing lists the new ones. In ListenJar
  /// Cloud instead, it is an [rss] show.
  youtubeFeed,

  /// A podcast of the listener's own on this device only: YouTube videos
  /// they gathered, which stream from YouTube as they play. In ListenJar
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

  /// The listener's ListenJar feed this is, while they are signed in.
  final String? cloudFeedId;
  final bool autoDownload;

  /// False for a show looked at from search, or a YouTube video played from
  /// it, that the listener hasn't followed: kept while something of it is
  /// playing, queued or downloaded.
  final bool followed;
  final int unplayed;
  final DateTime? latestAt;

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
  /// else the episode's own picture, else the show's.
  String? get artwork => switch (videoId) {
    final id? => videoThumbnail(id),
    null => artworkUrl ?? podcastArtworkUrl,
  };

  /// Whether the cover is a video's 16:9 frame.
  bool get widescreen => videoId != null;

  /// The big cover: a video's sharpest frame, else [artwork].
  String? get cover => switch (videoId) {
    final id? => 'https://i.ytimg.com/vi/$id/maxresdefault.jpg',
    null => artwork,
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
    this.newInCloud = false,
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

  /// Playlists and channels the listener follows, and podcasts they make,
  /// start in ListenJar Cloud rather than on this device, on a plan that
  /// has the Cloud. Each can move later.
  final bool newInCloud;

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
    bool? newInCloud,
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
    newInCloud: newInCloud ?? this.newInCloud,
  );
}

/// What [PlayerSettings.copyWith] takes for a nullable setting left as is.
const _same = Object();

/// A finished download, with when it was last used: played, or else
/// downloaded.
typedef StoredDownload = ({PodcastEpisode episode, DateTime? playedAt, DateTime lastUsed});

/// How a show's episodes are listed.
enum EpisodeFilter { all, unplayed, downloaded }

const _schema = 4;

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
    _migrate(db);
    return Library._(db, support);
  }

  static void _migrate(Database db) {
    final version = db.select('pragma user_version').first.columnAt(0) as int;
    if (version < 1) {
      db.execute('''
        create table podcasts (
          id integer primary key,
          feed_url text not null unique,
          kind text not null default 'rss',
          title text not null,
          author text not null default '',
          description text not null default '',
          artwork_url text,
          link text,
          subscribed_at integer not null,
          refreshed_at integer,
          refresh_error text,
          etag text,
          last_modified text,
          cloud_feed_id text,
          auto_download integer not null default 0,
          followed integer not null default 1
        ) strict;
        create table episodes (
          id integer primary key,
          podcast_id integer not null references podcasts (id) on delete cascade,
          guid text not null,
          title text not null,
          description text not null default '',
          published_at integer,
          duration_ms integer,
          audio_url text,
          audio_type text,
          audio_bytes integer,
          artwork_url text,
          link text,
          youtube_id text,
          season integer,
          number integer,
          position_ms integer not null default 0,
          played integer not null default 0,
          played_at integer,
          download_path text,
          download_state text not null default 'none',
          download_progress real not null default 0,
          download_error text,
          added_at integer not null,
          unique (podcast_id, guid)
        ) strict;
        create index episodes_by_date on episodes (podcast_id, published_at desc);
        create index episodes_new on episodes (played, published_at desc);
        create table queue (
          episode_id integer primary key references episodes (id) on delete cascade,
          position real not null
        ) strict;
        create table settings (
          key text primary key,
          value text not null
        ) strict;
      ''');
    }
    if (version < 2) {
      db.execute('''
        create table if not exists now_playing (
          id integer primary key check (id = 1),
          episode_id integer references episodes (id) on delete set null
        ) strict;
      ''');
    }
    if (version < 3) {
      // When each download finished, for removing the unused ones.
      db.execute('''
        alter table episodes add column downloaded_at integer;
        update episodes set downloaded_at = added_at where download_state = 'done';
      ''');
    }
    if (version < 4) {
      // Where the listener was in a YouTube playlist or channel moved to
      // ListenJar Cloud, by video, until its uploads arrive (carry).
      db.execute('''
        create table if not exists carried (
          feed_id text not null,
          video_id text not null,
          position_ms integer not null,
          played integer not null,
          primary key (feed_id, video_id)
        ) strict;
      ''');
    }
    db.execute('pragma user_version = $_schema');
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
      newInCloud: (kv['new_in_cloud'] ?? '${d.newInCloud}') == 'true',
    );
  }

  void _changed() {
    _load();
    notifyListeners();
  }

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
  );

  /// A stored duration: whole seconds, negative for none.
  static Duration? _seconds(String value) => switch (int.tryParse(value)) {
    final s? when s >= 0 => Duration(seconds: s),
    _ => null,
  };

  static DateTime? _time(Object? ms) => ms is int ? DateTime.fromMillisecondsSinceEpoch(ms) : null;

  static const _episodeColumns = '''
    e.id, e.podcast_id, e.guid, e.title, e.published_at, e.duration_ms, e.audio_url, e.audio_type,
    e.audio_bytes, e.artwork_url, e.link, e.youtube_id, e.season, e.number, e.position_ms, e.played,
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
  Podcast? podcastByUrl(String feedUrl) => _podcasts.where((p) => p.feedUrl == feedUrl).firstOrNull;

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

  /// [podcast]'s episodes, newest first unless [oldestFirst]; with a [query],
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
    return _episodes(where, args, oldestFirst ? 'e.published_at asc, e.id asc' : 'e.published_at desc, e.id desc');
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
      insert into podcasts (feed_url, title, author, description, artwork_url, link, subscribed_at, refreshed_at, etag, last_modified, cloud_feed_id, followed)
      values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      on conflict (feed_url) do update set
        title = excluded.title, author = excluded.author, description = excluded.description,
        artwork_url = excluded.artwork_url, link = excluded.link, refreshed_at = excluded.refreshed_at,
        etag = excluded.etag, last_modified = excluded.last_modified, refresh_error = null,
        cloud_feed_id = coalesce(excluded.cloud_feed_id, podcasts.cloud_feed_id),
        followed = max(podcasts.followed, excluded.followed),
        subscribed_at = case when podcasts.followed = 0 and excluded.followed = 1 then excluded.subscribed_at else podcasts.subscribed_at end
    ''', [feedUrl, feed.title, feed.author, feed.description, feed.artworkUrl, feed.link, now, now, etag, lastModified, cloudFeedId, follow ? 1 : 0]);
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
  /// ids of the new ones.
  List<int> _store(int podcast, List<ParsedEpisode> episodes, {int? playedBefore}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final sorted = [...episodes]..sort((a, b) => (b.publishedAt ?? DateTime(0)).compareTo(a.publishedAt ?? DateTime(0)));
    final known = {
      for (final row in _db.select('select guid from episodes where podcast_id = ?', [podcast])) row['guid'] as String,
    };
    final added = <int>[];
    final insert = _db.prepare('''
      insert into episodes (podcast_id, guid, title, description, published_at, duration_ms, audio_url, audio_type,
        audio_bytes, artwork_url, link, season, number, played, added_at)
      values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''');
    final update = _db.prepare('''
      update episodes set title = ?, description = ?, published_at = ?, duration_ms = coalesce(?, duration_ms),
        audio_url = ?, audio_type = ?, audio_bytes = ?, artwork_url = ?, link = ?, season = ?, number = ?
      where podcast_id = ? and guid = ?
    ''');
    _db.execute('begin');
    try {
      for (final (i, e) in sorted.indexed) {
        if (known.contains(e.guid)) {
          update.execute([
            e.title, e.description, e.publishedAt?.millisecondsSinceEpoch, e.duration?.inMilliseconds, e.audioUrl,
            e.audioType, e.audioBytes, e.artworkUrl, e.link, e.season, e.number, podcast, e.guid,
          ]);
          continue;
        }
        insert.execute([
          podcast, e.guid, e.title, e.description, e.publishedAt?.millisecondsSinceEpoch, e.duration?.inMilliseconds,
          e.audioUrl, e.audioType, e.audioBytes, e.artworkUrl, e.link, e.season, e.number,
          playedBefore != null && i >= playedBefore ? 1 : 0, now,
        ]);
        added.add(_db.lastInsertRowId);
      }
      _db.execute('commit');
    } catch (_) {
      _db.execute('rollback');
      rethrow;
    } finally {
      insert.close();
      update.close();
    }
    return added;
  }

  /// What a refresh found: the feed, unless it hadn't changed. Returns the
  /// new episodes.
  List<PodcastEpisode> refreshed(int podcast, FeedFetch fetch) {
    final now = DateTime.now().millisecondsSinceEpoch;
    var added = const <int>[];
    if (fetch.feed case final feed?) {
      _db.execute('''
        update podcasts set title = ?, author = ?, description = ?, artwork_url = coalesce(?, artwork_url), link = ?
        where id = ?
      ''', [feed.title, feed.author, feed.description, feed.artworkUrl, feed.link, podcast]);
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
      insert into episodes (podcast_id, guid, title, description, published_at, duration_ms, artwork_url, link, youtube_id, added_at)
      values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      on conflict (podcast_id, guid) do nothing
    ''', [id, 'yt:$videoId', title, description, publishedAt?.millisecondsSinceEpoch, duration?.inMilliseconds, artworkUrl, url, videoId, now]);
    _changed();
    return podcast(id)!;
  }

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
  /// are dated when they turned up, so they count as new.
  List<PodcastEpisode> youtubeFeedRefreshed(int podcast, {required String? title, required String? artworkUrl, required List<YouTubeVideo> videos, required bool dated}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final added = <int>[];
    _db.execute('begin');
    try {
      _db.execute(
        'update podcasts set title = coalesce(?, title), artwork_url = coalesce(?, artwork_url), refreshed_at = ?, refresh_error = null where id = ?',
        [title, artworkUrl, now, podcast],
      );
      // Oldest first, so the newest gets the highest id and lists first.
      for (final (i, v) in videos.indexed.toList().reversed) {
        final url = _watchUrl(v.id);
        final rows = _db.select('''
          insert into episodes (podcast_id, guid, title, published_at, duration_ms, link, youtube_id, played, added_at)
          values (?, ?, ?, ?, ?, ?, ?, ?, ?)
          on conflict (podcast_id, guid) do nothing
          returning id
        ''', [
          podcast, 'yt:${v.id}', v.title, dated ? now : null, v.seconds == null ? null : v.seconds! * 1000, url, v.id,
          !dated && i >= _newestCount ? 1 : 0, now,
        ]);
        if (rows.isNotEmpty) added.add(rows.first['id'] as int);
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

  /// Makes a podcast of the listener's own on this device, empty until they
  /// add videos.
  Podcast createOwn(String title, {String? artworkUrl}) {
    final now = DateTime.now();
    final rows = _db.select('''
      insert into podcasts (feed_url, kind, title, author, artwork_url, subscribed_at, refreshed_at, followed)
      values (?, 'own', ?, 'Podcast of your own', ?, ?, ?, 1)
      returning id
    ''', ['listenjar:own:${now.microsecondsSinceEpoch}', title, artworkUrl, now.millisecondsSinceEpoch, now.millisecondsSinceEpoch]);
    _changed();
    return podcast(rows.first['id'] as int)!;
  }

  /// Adds the YouTube video [videoId] to [podcast], a podcast of the
  /// listener's own, dated [addedAt] (now by default), as ListenJar Cloud
  /// dates what is added to one there. Null when it's already there.
  PodcastEpisode? addOwnVideo(int podcast, {required String videoId, required String title, Duration? duration, DateTime? addedAt}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final rows = _db.select('''
      insert into episodes (podcast_id, guid, title, published_at, duration_ms, link, youtube_id, added_at)
      values (?, ?, ?, ?, ?, ?, ?, ?)
      on conflict (podcast_id, guid) do nothing
      returning id
    ''', [podcast, 'yt:$videoId', title, addedAt?.millisecondsSinceEpoch ?? now, duration?.inMilliseconds, _watchUrl(videoId), videoId, now]);
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

  // Moving between this device and ListenJar Cloud.

  /// The videos of [podcast] the listener played or started, by video id.
  Map<String, (Duration, bool)> _listened(int podcast) => {
    for (final e in episodes(podcast))
      if (e.videoId case final id? when e.played || e.position > Duration.zero) id: (e.position, e.played),
  };

  /// Puts [listened] on the episodes of [podcast] that are the same videos;
  /// returns the video ids it put.
  Set<String> _listen(int podcast, Map<String, (Duration, bool)> listened) {
    final put = <String>{};
    for (final e in episodes(podcast)) {
      final id = e.videoId;
      final listening = id == null ? null : listened[id];
      if (listening == null) continue;
      final (position, played) = listening;
      _db.execute('update episodes set position_ms = ?, played = ? where id = ?', [position.inMilliseconds, played ? 1 : 0, e.id]);
      put.add(id!);
    }
    return put;
  }

  /// Where the listener was in [from], onto [to]: the same YouTube videos,
  /// one show moving between this device and ListenJar Cloud.
  void copyListening(int from, int to) {
    _listen(to, _listened(from));
    _changed();
  }

  /// Keeps where the listener was in [podcast] for [feedId], its ListenJar
  /// Cloud feed now, whose episodes arrive as they upload ([applyCarried]).
  void carry(int podcast, String feedId) {
    for (final MapEntry(key: video, value: (position, played)) in _listened(podcast).entries) {
      _db.execute(
        'insert or replace into carried (feed_id, video_id, position_ms, played) values (?, ?, ?, ?)',
        [feedId, video, position.inMilliseconds, played ? 1 : 0],
      );
    }
  }

  /// Puts what [carry] kept on the episodes of [podcast], [feedId]'s show,
  /// that have arrived, and forgets it for those.
  void applyCarried(int podcast, String feedId) {
    final rows = _db.select('select video_id, position_ms, played from carried where feed_id = ?', [feedId]);
    if (rows.isEmpty) return;
    final put = _listen(podcast, {
      for (final r in rows) r['video_id'] as String: (Duration(milliseconds: r['position_ms'] as int), r['played'] == 1),
    });
    for (final id in put) {
      _db.execute('delete from carried where feed_id = ? and video_id = ?', [feedId, id]);
    }
    if (put.isNotEmpty) _changed();
  }

  /// Keeps [podcast], a ListenJar Cloud show whose feed is gone, on this
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
          'update episodes set guid = ?, youtube_id = ?, link = ?, audio_url = null, audio_type = null, audio_bytes = null where id = ?',
          ['yt:$id', id, _watchUrl(id), e.id],
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

  /// Forgets what was carried for feeds the listener no longer has.
  void forgetCarried(Set<String> live) {
    for (final r in _db.select('select distinct feed_id from carried')) {
      if (!live.contains(r['feed_id'])) _db.execute('delete from carried where feed_id = ?', [r['feed_id']]);
    }
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

  /// Links [podcast] to the listener's ListenJar feed, or unlinks it.
  void setCloudFeed(int podcast, String? feedId) {
    _db.execute('update podcasts set cloud_feed_id = ? where id = ?', [feedId, podcast]);
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
      'new_in_cloud': '${s.newInCloud}',
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
