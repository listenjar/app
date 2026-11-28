// The listener's library, the same on each of their devices, on a
// Listenjar Cloud plan (10 GB, 100 GB): a classic podcast library. Every RSS
// show they follow, where they are in each episode, and Up Next, by feed
// URL and episode guid. Nothing here is YouTube's: a YouTube playlist,
// channel or podcast of the listener's own joins once Listenjar hosts it
// and it is an RSS show like any other (cloud_shows.dart); until then, and
// for a single video, it stays on the device it was made on. Downloads and
// settings stay each device's. None of it counts against the plan's
// storage, which is uploaded audio only.
//
// A three-way merge, with no change log: `sync_base` (library.dart) holds
// each record as the Cloud and this device last agreed on it. A pass
//
// 1. pulls what changed in the Cloud since the version it last saw
//    (pullLibrary). A record this device hasn't changed since the base
//    becomes the base, `pending` until the library has it; one both changed
//    goes to the newer change, by when the listener played, followed or
//    added it here, and a change here otherwise.
// 2. applies what is pending: follows and lets go of shows, puts where they
//    are on episodes that are here (the rest wait for their show's next
//    refresh), and lays out Up Next.
// 3. pushes what differs from the base (pushLibrary), which becomes the
//    base.
//
// Passes run on signing in, when another device pushes (watchLibrary),
// shortly after the library changes, and every minute, which is how where
// the listener is in what's playing gets out. Only a pull or a change here
// costs a request.
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cancellation_token/cancellation_token.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:sqlite3/sqlite3.dart';

import 'account.dart';
import 'backend/api.dart';
import 'library.dart';
import 'podcasts.dart';

final _log = Logger('library sync');

/// A pass this long after the library changes, so a burst makes one.
const _settle = Duration(seconds: 5);

/// A pass this often while syncing, for where the listener is in what's
/// playing, which the library saves without telling anyone.
const _every = Duration(minutes: 1);

/// A show that couldn't be followed is tried again after this.
const _retryFollow = Duration(hours: 1);

const _pushMax = 500;

/// As watchMyFeeds' (feeds.dart).
const _watchIdle = Duration(seconds: 60);
const _watchRetry = (Duration(seconds: 2), Duration(minutes: 5));

/// A record's key: its kind, its show's feed URL and its item.
typedef _Key = (LibraryKind, String, String);

/// What [_Key] holds here, as its record's data, with its [_sig] and when
/// the listener last changed it, when that's known.
typedef _Local = ({String sig, LibraryData data, int? changedAt});

/// One row of the base: its record's data as JSON, and its [_sig].
typedef _Base = ({int updatedAt, String? json, String? sig, bool pending});

final class LibrarySync extends ChangeNotifier {
  LibrarySync(this._account, this._podcasts) {
    _account.addListener(_follow);
    _library.addListener(_libraryChanged);
    _follow();
  }

  final Account _account;
  final Podcasts _podcasts;
  Library get _library => _podcasts.library;
  final _life = CancellationToken();

  /// The listener syncing, while signed in on a Cloud plan.
  String? _user;
  Timer? _timer;
  Timer? _soon;
  Future<void>? _pass;
  bool _again = false;
  bool _againPull = false;

  /// Shows the Cloud has that couldn't be followed here, and when.
  final _failed = <String, DateTime>{};

  DateTime? syncedAt;
  Object? error;

  /// Whether the library syncs between the listener's devices: signed in,
  /// on a Listenjar Cloud plan.
  bool get on => _user != null;

  void _follow() {
    final user = _account.user;
    final syncing = user != null && user.storageLimitBytes != null ? user.id : null;
    if (syncing == _user) return;
    _user = syncing;
    _timer?.cancel();
    _soon?.cancel();
    if (syncing == null) {
      notifyListeners();
      return;
    }
    _timer = Timer.periodic(_every, (_) => sync(pull: false));
    unawaited(sync());
    unawaited(_watch(syncing));
    notifyListeners();
  }

  void _libraryChanged() {
    if (_user == null || _applying) return;
    _soon?.cancel();
    _soon = Timer(_settle, () => sync(pull: false));
  }

  /// Runs a pass, or another right after the one running; [pull] asks the
  /// Cloud what changed, not only tells it.
  Future<void> sync({bool pull = true}) {
    if (_user == null || _life.isCancelled) return Future.value();
    if (_pass case final running?) {
      _again = true;
      _againPull |= pull;
      return running;
    }
    return _pass = () async {
      try {
        var pulling = pull;
        do {
          _again = false;
          await _run(pulling);
          pulling = _againPull;
          _againPull = false;
        } while (_again && _user != null && !_life.isCancelled);
      } finally {
        _pass = null;
      }
    }();
  }

  /// Watches the Cloud's version of the library and pulls when it moves.
  Future<void> _watch(String user) async {
    final (first, most) = _watchRetry;
    var wait = first;
    bool watching() => _user == user && !_life.isCancelled;
    while (watching()) {
      try {
        final response = await _account.api.watchLibrary();
        await for (final version in _versions(response.stream.timeout(_watchIdle))) {
          if (!watching()) break;
          wait = first;
          if (version > _version) unawaited(sync());
        }
      } on ApiStatusException catch (e) {
        if (e.statusCode == 401 || e.statusCode == 402) return;
      } catch (_) {
        // Offline, idle too long, or the server ended it: watch again.
      }
      await Future<void>.delayed(wait);
      wait = Duration(milliseconds: min(wait.inMilliseconds * 2, most.inMilliseconds));
    }
  }

  // The pass.

  bool _applying = false;

  Future<void> _run(bool pull) async {
    final user = _user;
    if (user == null) return;
    try {
      _startFor(user);
      if (pull) await _pull();
      await _applyPending();
      await _push();
      syncedAt = DateTime.now();
      error = null;
    } on CancelledException {
      return;
    } on ApiStatusException catch (e) {
      // The plan lost the Cloud: the account hears of it on its next call.
      if (e.statusCode == 402) unawaited(_account.refresh(force: true));
      error = e;
      _log.warning('Library sync failed', e);
    } catch (e, stack) {
      error = e;
      _log.warning('Library sync failed', e, stack);
    } finally {
      notifyListeners();
    }
  }

  /// A listener new to this device starts from an empty base: their
  /// library and this device's are merged, the newer change of each.
  void _startFor(String user) {
    if (_setting('sync_user') == user) return;
    _db.execute('delete from sync_base');
    _setSetting('sync_user', user);
    _setSetting('sync_version', '0');
  }

  int get _version => int.tryParse(_setting('sync_version') ?? '') ?? 0;

  Future<void> _pull() async {
    final local = _snapshot();
    var since = _version;
    while (true) {
      final changes = await _account.api.pullLibrary(since: since).asCancellable(_life.merge(_account.timeout()));
      _db.execute('begin');
      try {
        for (final record in changes.records) {
          _merge(record, local);
        }
        _setSetting('sync_version', '${changes.version}');
        _db.execute('commit');
      } catch (_) {
        _db.execute('rollback');
        rethrow;
      }
      since = changes.version;
      if (!changes.more) break;
    }
  }

  /// Takes [record] from the Cloud into the base, unless this device has
  /// a newer change of its own.
  void _merge(LibraryRecord record, Map<_Key, _Local> local) {
    final key = (record.kind, record.show, record.item);
    final data = record.deleted == true ? null : record.data;
    final remote = _sig(record.kind, data);
    final json = remote == null ? null : _json(data!);
    final base = _base(key);
    final here = local[key];
    final bool changedHere;
    if (base == null) {
      changedHere = here != null;
    } else if (base.pending || (here == null && record.kind == LibraryKind.listen)) {
      // Not applied yet; or an episode untouched here, which says nothing.
      changedHere = false;
    } else {
      changedHere = here?.sig != base.sig;
    }
    if (changedHere) {
      if (here?.sig == remote) {
        _setBase(key, record.updatedAt, json, pending: false);
        return;
      }
      // By each kind's own clock; a show let go or Up Next changed here,
      // with no time, is taken for the newer.
      final remoteWins = switch (here?.changedAt) {
        final at? => record.updatedAt > at,
        null => false,
      };
      if (!remoteWins) return;
    }
    _setBase(key, record.updatedAt, json, pending: remote != here?.sig);
  }

  /// Puts on the library what the Cloud changed.
  Future<void> _applyPending() async {
    _applying = true;
    try {
      // Shows first: episodes are in them.
      for (final (key, base) in _pendingOf(LibraryKind.show)) {
        if (await _applyShow(key.$2, base.json)) _settled(key);
      }
      _applyListens();
      for (final (key, base) in _pendingOf(LibraryKind.queue)) {
        _applyQueue(key, base);
      }
    } finally {
      _library.reload();
      _applying = false;
    }
  }

  /// Follows the RSS show at [url], or lets it go when [json] is gone;
  /// false to try again on a later pass. A show Listenjar hosts comes and
  /// goes with its feed ([Podcasts.followCloud]), and a show here that
  /// isn't RSS yet is this device's alone.
  Future<bool> _applyShow(String url, String? json) async {
    final here = _library.podcastByUrl(url);
    if (here != null && (here.cloudFeedId != null || here.kind != PodcastKind.rss)) return true;
    if (json == null) {
      if (here != null && here.followed) await _podcasts.unfollow(here);
      return true;
    }
    if (here != null && here.followed) return true;
    if (_failed[url] case final at? when DateTime.now().difference(at) < _retryFollow) return false;
    try {
      await _podcasts.follow(Uri.parse(url), _life.merge(TimeoutCancellationToken(const Duration(minutes: 2))));
      _failed.remove(url);
      return true;
    } on CancelledException {
      if (_life.isCancelled) rethrow;
      _failed[url] = DateTime.now();
      return false;
    } catch (e) {
      _log.warning('Couldn’t follow $url from another device', e);
      _failed[url] = DateTime.now();
      return false;
    }
  }

  /// Where the listener is, on the episodes here that other devices moved,
  /// unless they played them here since; the rest wait for their show to
  /// list them.
  void _applyListens() {
    _db.execute('''
      update episodes set
        position_ms = json_extract(b.data, '\$.positionMs'),
        played = json_extract(b.data, '\$.played'),
        played_at = json_extract(b.data, '\$.playedAt')
      from sync_base b join podcasts p on p.feed_url = b.show
      where b.kind = 'listen' and b.pending = 1 and b.data is not null
        and episodes.podcast_id = p.id and episodes.guid = b.item
        and (episodes.played_at is null or episodes.played_at < json_extract(b.data, '\$.playedAt'))
    ''');
    _db.execute('''
      update sync_base set pending = 0
      where kind = 'listen' and pending = 1 and (data is null or exists (
        select 1 from episodes e join podcasts p on p.id = e.podcast_id
        where p.feed_url = sync_base.show and e.guid = sync_base.item
      ))
    ''');
  }

  /// Lays Up Next out as another device has it, with the episodes that are
  /// here; the base becomes what that is, so the rest isn't taken off the
  /// other devices.
  void _applyQueue(_Key key, _Base base) {
    final refs = base.json == null ? const <LibraryEpisodeRef>[] : LibraryData.fromJson(jsonDecode(base.json!)).queue ?? const [];
    final ids = <int>[];
    for (final ref in refs) {
      final row = _db.select(
        'select e.id from episodes e join podcasts p on p.id = e.podcast_id where p.feed_url = ? and e.guid = ?',
        [ref.show, ref.item],
      ).firstOrNull;
      if (row != null) ids.add(row['id'] as int);
    }
    _db.execute('begin');
    try {
      _db.execute('delete from queue');
      for (final (i, id) in ids.indexed) {
        _db.execute('insert or ignore into queue (episode_id, position) values (?, ?)', [id, i.toDouble()]);
      }
      _db.execute('commit');
    } catch (_) {
      _db.execute('rollback');
      rethrow;
    }
    final laid = _queueHere();
    _setBase(key, base.updatedAt, laid == null ? null : _json(laid.data), pending: false);
  }

  /// Tells the Cloud what changed here since the base.
  Future<void> _push() async {
    final local = _snapshot();
    final base = {
      for (final r in _db.select('select kind, show, item, updated_at, data, pending from sync_base'))
        (LibraryKind.fromJson(r['kind']), r['show'] as String, r['item'] as String): _baseOf(LibraryKind.fromJson(r['kind']), r),
    };
    final now = DateTime.now().millisecondsSinceEpoch;
    final changes = <(_Key, String?, LibraryRecord)>[];
    for (final key in {...local.keys, ...base.keys}) {
      final b = base[key];
      if (b?.pending ?? false) continue;
      final here = local[key];
      if (here?.sig == b?.sig) continue;
      final (kind, show, item) = key;
      // Where the listener is stays when the episode leaves this device.
      if (here == null && kind == LibraryKind.listen) continue;
      // Up Next emptied here is an empty one, not a removed record.
      final data = here?.data ?? (kind == LibraryKind.queue ? const LibraryData(queue: []) : null);
      final updatedAt = kind == LibraryKind.listen ? here!.changedAt ?? now : max(now, (b?.updatedAt ?? 0) + 1);
      changes.add((
        key,
        here == null ? null : _json(here.data),
        LibraryRecord(kind: kind, show: show, item: item, updatedAt: updatedAt, deleted: data == null ? true : null, data: data),
      ));
    }
    for (var at = 0; at < changes.length; at += _pushMax) {
      final batch = changes.sublist(at, min(at + _pushMax, changes.length));
      await _account.api
        .pushLibrary(body: LibraryPush(records: [for (final (_, _, record) in batch) record]))
        .asCancellable(_life.merge(_account.timeout()));
      _db.execute('begin');
      for (final (key, json, record) in batch) {
        _setBase(key, record.updatedAt, json, pending: false);
      }
      _db.execute('commit');
    }
    if (changes.isNotEmpty) _log.info('Pushed ${changes.length} library changes');
  }

  // The library here, as records.

  Map<_Key, _Local> _snapshot() => {
    ..._showsHere(),
    ..._listensHere(),
    (LibraryKind.queue, '', ''): ?_queueHere(),
  };

  static _Local _local(LibraryKind kind, LibraryData data, int? changedAt) => (sig: _sig(kind, data)!, data: data, changedAt: changedAt);

  /// The RSS shows the listener follows, those Listenjar hosts among them.
  Map<_Key, _Local> _showsHere() => {
    for (final r in _db.select('''
      select p.feed_url, p.title, p.author, p.artwork_url, p.subscribed_at
      from podcasts p where p.followed = 1 and p.kind = 'rss'
    '''))
      (LibraryKind.show, r['feed_url'] as String, ''): _local(
        LibraryKind.show,
        LibraryData(
          title: r['title'] as String,
          author: r['author'] as String,
          artworkUrl: switch (r['artwork_url']) {
            final String url when url.startsWith('https://') || url.startsWith('http://') => url,
            _ => null,
          },
          subscribedAt: r['subscribed_at'] as int,
        ),
        r['subscribed_at'] as int,
      ),
  };

  /// The episodes of RSS shows, in [alias], by the guid their feed gives
  /// them: not one still streaming from its source until its upload is in
  /// its show's feed ([Library.hostedAt]).
  static String _classic(String alias) => "$alias.kind = 'rss' and e.audio_url is not null";

  /// Where the listener is in each episode they played or marked.
  Map<_Key, _Local> _listensHere() => {
    for (final r in _db.select('''
      select p.feed_url, e.guid, e.position_ms, e.played, e.played_at
      from episodes e join podcasts p on p.id = e.podcast_id
      where e.played_at is not null and ${_classic('p')}
    '''))
      (LibraryKind.listen, r['feed_url'] as String, r['guid'] as String): _local(
        LibraryKind.listen,
        LibraryData(positionMs: r['position_ms'] as int, played: r['played'] == 1, playedAt: r['played_at'] as int),
        r['played_at'] as int,
      ),
  };

  _Local? _queueHere() {
    final refs = [
      for (final r in _db.select('''
        select p.feed_url, e.guid from queue q join episodes e on e.id = q.episode_id
        join podcasts p on p.id = e.podcast_id where ${_classic('p')} order by q.position
      '''))
        LibraryEpisodeRef(show: r['feed_url'] as String, item: r['guid'] as String),
    ];
    // Empty, it is as if there were none: a new device's says nothing.
    return refs.isEmpty ? null : _local(LibraryKind.queue, LibraryData(queue: refs), null);
  }

  // The base.

  Database get _db => _library.database;

  static _Base _baseOf(LibraryKind kind, Row r) {
    final json = r['data'] as String?;
    return (
      updatedAt: r['updated_at'] as int,
      json: json,
      sig: json == null ? null : _sig(kind, LibraryData.fromJson(jsonDecode(json))),
      pending: r['pending'] == 1,
    );
  }

  _Base? _base(_Key key) => switch (_db.select(
    'select updated_at, data, pending from sync_base where kind = ? and show = ? and item = ?',
    [key.$1.value, key.$2, key.$3],
  ).firstOrNull) {
    final r? => _baseOf(key.$1, r),
    null => null,
  };

  void _setBase(_Key key, int updatedAt, String? json, {required bool pending}) => _db.execute(
    '''
      insert into sync_base (kind, show, item, updated_at, data, pending) values (?, ?, ?, ?, ?, ?)
      on conflict (kind, show, item) do update set
        updated_at = excluded.updated_at, data = excluded.data, pending = excluded.pending
    ''',
    [key.$1.value, key.$2, key.$3, updatedAt, json, pending ? 1 : 0],
  );

  void _settled(_Key key) => _db.execute(
    'update sync_base set pending = 0 where kind = ? and show = ? and item = ?',
    [key.$1.value, key.$2, key.$3],
  );

  List<(_Key, _Base)> _pendingOf(LibraryKind kind) => [
    for (final r in _db.select('select show, item, updated_at, data, pending from sync_base where kind = ? and pending = 1', [kind.value]))
      ((kind, r['show'] as String, r['item'] as String), _baseOf(kind, r)),
  ];

  String? _setting(String key) =>
    _db.select('select value from settings where key = ?', [key]).firstOrNull?['value'] as String?;

  void _setSetting(String key, String value) => _db.execute(
    'insert into settings (key, value) values (?, ?) on conflict (key) do update set value = excluded.value',
    [key, value],
  );

  static String _json(LibraryData data) => jsonEncode(data.toJson());

  /// What two devices must agree on for a record to be the same on both,
  /// and nothing else, so that what each reads from its own feeds (titles,
  /// artwork, when it followed) doesn't bounce between them: that a show is
  /// followed; where the listener is in an episode; and Up Next. Null for
  /// none, as an empty Up Next is.
  static String? _sig(LibraryKind kind, LibraryData? data) => switch ((kind, data)) {
    (_, null) => null,
    (LibraryKind.show, _) => 'followed',
    (LibraryKind.listen, final d?) => jsonEncode([d.positionMs ?? 0, d.played ?? false]),
    (LibraryKind.queue, LibraryData(queue: null || [])) => null,
    (LibraryKind.queue, final d?) => jsonEncode([for (final r in d.queue!) [r.show, r.item]]),
  };

  void close() {
    _life.cancel();
    _timer?.cancel();
    _soon?.cancel();
    _account.removeListener(_follow);
    _library.removeListener(_libraryChanged);
  }
}

/// watchLibrary's events (public.yaml): each `data` a LibraryVersion.
Stream<int> _versions(Stream<List<int>> body) async* {
  final data = <String>[];
  await for (final line in body.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.isEmpty) {
      if (data.isNotEmpty) yield LibraryVersion.fromJson(jsonDecode(data.join('\n'))).version;
      data.clear();
    } else if (line.startsWith('data:')) {
      final value = line.substring(5);
      data.add(value.startsWith(' ') ? value.substring(1) : value);
    }
  }
}
