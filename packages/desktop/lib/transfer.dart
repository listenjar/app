// Downloading a YouTube stream to this computer in ranges that survive a
// restart; uploads.dart sends it on to R2. Ported from the Listenbox client's Go sync
// engine (crates/sync-engine/download.go): 1 MiB ranges, four at a time, each
// range's SHA-256 journaled once it is on disk, so a resumed download fetches
// only what is missing.
import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:cancellation_token/cancellation_token.dart';
import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';

import 'youtube.dart';

const rangeBytes = 1 << 20;
const _rangeWorkers = 4;

/// A non-2xx answer from a media server or the upload URL.
final class TransferStatusException implements Exception {
  const TransferStatusException(this.what, this.statusCode);
  final String what;
  final int statusCode;
  @override
  String toString() => '$what: HTTP $statusCode';
}

/// Progress of one transfer, in bytes.
typedef Progress = void Function(int done, int total);

/// The journal of partial downloads and skipped videos, in SQLite next to the
/// downloads.
final class Journal {
  Journal._(this._db, this.directory);

  final Database _db;

  /// Where partial downloads live until they are uploaded.
  final Directory directory;

  static Journal open(Directory support) {
    final directory = Directory('${support.path}/downloads')..createSync(recursive: true);
    final db = sqlite3.open('${support.path}/sync.sqlite')
      ..execute('pragma journal_mode = wal')
      ..execute('''
        create table if not exists downloads (
          key text primary key,
          identity text not null
        ) strict;
        create table if not exists ranges (
          key text not null references downloads (key) on delete cascade,
          start integer not null,
          sha256 text not null,
          primary key (key, start)
        ) strict;
        create table if not exists skips (
          key text primary key,
          reason text not null,
          at integer not null
        ) strict;
        pragma foreign_keys = on;
      ''');
    return Journal._(db, directory);
  }

  void close() => _db.close();

  File file(String key) => File('${directory.path}/${key.replaceAll('/', '-')}.part');

  /// Starts or resumes [key]'s download of the rendition [identity]; a
  /// different rendition starts over.
  void begin(String key, String identity) {
    final saved = _db.select('select identity from downloads where key = ?', [key]).firstOrNull;
    if (saved?['identity'] == identity) return;
    _db
      ..execute('delete from downloads where key = ?', [key])
      ..execute('insert into downloads (key, identity) values (?, ?)', [key, identity]);
  }

  String? rangeHash(String key, int start) =>
    _db.select('select sha256 from ranges where key = ? and start = ?', [key, start]).firstOrNull?['sha256'] as String?;

  void saveRange(String key, int start, String hash) =>
    _db.execute('insert or replace into ranges (key, start, sha256) values (?, ?, ?)', [key, start, hash]);

  /// Forgets [key]'s download and deletes its file.
  Future<void> forget(String key) async {
    _db.execute('delete from downloads where key = ?', [key]);
    final f = file(key);
    if (await f.exists()) await f.delete();
  }

  /// Why [key] was skipped, while that is recent enough to trust.
  String? skipped(String key, Duration within) {
    final row = _db.select('select reason, at from skips where key = ?', [key]).firstOrNull;
    if (row == null) return null;
    final at = DateTime.fromMillisecondsSinceEpoch(row['at'] as int);
    return DateTime.now().difference(at) < within ? row['reason'] as String : null;
  }

  void skip(String key, String reason) => _db.execute(
    'insert or replace into skips (key, reason, at) values (?, ?, ?)',
    [key, reason, DateTime.now().millisecondsSinceEpoch],
  );
}

/// Downloads [stream] to [journal]'s file for [key], resuming saved ranges.
/// Throws [MediaUnavailable] when the server refuses it.
Future<File> download(
  HttpClient http,
  Journal journal,
  String key,
  MediaStream stream,
  Progress progress,
  CancellationToken token,
) async {
  final (total, validator) = await _probe(http, stream, token);
  final revision = validator ?? stream.url.queryParameters['lmt'] ?? '';
  journal.begin(key, '${stream.identity}:$total:$revision');
  final file = journal.file(key);
  final raf = await file.open(mode: FileMode.append);
  try {
    await raf.truncate(total);
    final starts = [for (var start = 0; start < total; start += rangeBytes) start];
    var received = 0;
    void add(int n) {
      received += n;
      progress(received, total);
    }

    // Writes are serialized: RandomAccessFile allows one operation at a time.
    var writing = Future<void>.value();
    Future<void> write(int start, Uint8List bytes) {
      final done = writing.then((_) async {
        await raf.setPosition(start);
        await raf.writeFrom(bytes);
        await raf.flush();
      });
      writing = done;
      return done;
    }

    Future<Uint8List> read(int start, int length) {
      final done = writing.then((_) async {
        await raf.setPosition(start);
        return raf.read(length);
      });
      writing = done.then((_) {});
      return done;
    }

    var next = 0;
    Future<void> worker() async {
      while (next < starts.length) {
        token.throwIfCancelled();
        final start = starts[next++];
        final end = (start + rangeBytes < total ? start + rangeBytes : total) - 1;
        final length = end - start + 1;
        if (journal.rangeHash(key, start) case final hash?) {
          final saved = await read(start, length);
          if (saved.length == length && sha256.convert(saved).toString() == hash) {
            add(length);
            continue;
          }
        }
        final bytes = await _range(http, stream, start, end, total, validator, add, token);
        await write(start, bytes);
        journal.saveRange(key, start, sha256.convert(bytes).toString());
      }
    }

    await Future.wait([for (var i = 0; i < _rangeWorkers; i++) worker()]);
  } finally {
    await raf.close();
  }
  return file;
}

/// The size of [stream] in bytes, from the player response or else from the media server.
Future<int> mediaLength(HttpClient http, MediaStream stream, CancellationToken token) async =>
  stream.format.content_length ?? (await _probe(http, stream, token)).$1;

/// The bytes of [stream] from [start] up to [end], in one request: for a
/// small range, such as the segment index.
Future<Uint8List> fetchRange(HttpClient http, MediaStream stream, int start, int end, int total, CancellationToken token) =>
  _range(http, stream, start, end - 1, total, null, (_) {}, token);

/// The bytes of [stream] from [start] up to [end], in order, for playing
/// while they arrive. The media servers send a request for more than about
/// 10 MB at a trickle (~32 KB/s), so like [download] this asks for
/// [rangeBytes] at a time, four ranges in flight.
Stream<List<int>> streamRange(HttpClient http, MediaStream stream, int start, int end, int total, CancellationToken token) async* {
  // Ending the stream (the player seeked or stopped) cancels the ranges
  // still in flight.
  final ended = CancellationToken();
  final merged = token.merge(ended);
  final pending = Queue<Future<Uint8List>>();
  var next = start;
  void fill() {
    while (pending.length < _rangeWorkers && next < end) {
      final last = (next + rangeBytes < end ? next + rangeBytes : end) - 1;
      pending.add(_range(http, stream, next, last, total, null, (_) {}, merged));
      next = last + 1;
    }
  }

  try {
    fill();
    while (pending.isNotEmpty) {
      final bytes = await pending.removeFirst();
      fill();
      yield bytes;
    }
  } finally {
    ended.cancel();
    for (final range in pending) {
      range.ignore();
    }
  }
}

Map<String, String> _mediaHeaders(MediaStream stream) => {
  'Origin': 'https://www.youtube.com',
  'User-Agent': stream.userAgent,
};

/// The stream's size and validator, from its first byte.
Future<(int, String?)> _probe(HttpClient http, MediaStream stream, CancellationToken token) async {
  final request = await http.getUrl(stream.url).asCancellable(token);
  _mediaHeaders(stream).forEach(request.headers.set);
  request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
  final response = await request.close().asCancellable(token);
  await response.drain<void>();
  if (response.statusCode == HttpStatus.forbidden) throw const MediaUnavailable();
  if (response.statusCode != HttpStatus.partialContent) throw TransferStatusException('download source', response.statusCode);
  final range = response.headers.value(HttpHeaders.contentRangeHeader) ?? '';
  final total = range.startsWith('bytes 0-0/') ? int.tryParse(range.substring('bytes 0-0/'.length)) : null;
  if (total == null || total <= 0 || total > 5000000000) throw StateError('invalid initial media range "$range"');
  var validator = response.headers.value(HttpHeaders.etagHeader);
  if (validator == null || validator.startsWith('W/')) validator = response.headers.value(HttpHeaders.lastModifiedHeader);
  return (total, validator);
}

Future<Uint8List> _range(
  HttpClient http,
  MediaStream stream,
  int start,
  int end,
  int total,
  String? validator,
  void Function(int) add,
  CancellationToken token,
) async {
  final request = await http.getUrl(stream.url).asCancellable(token);
  _mediaHeaders(stream).forEach(request.headers.set);
  request.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-$end');
  if (validator != null) request.headers.set(HttpHeaders.ifRangeHeader, validator);
  final response = await request.close().asCancellable(token);
  if (response.statusCode != HttpStatus.partialContent) {
    await response.drain<void>();
    if (response.statusCode == HttpStatus.forbidden) throw const MediaUnavailable();
    throw TransferStatusException('download source', response.statusCode);
  }
  if (response.headers.value(HttpHeaders.contentRangeHeader) != 'bytes $start-$end/$total') {
    await response.drain<void>();
    throw StateError('media range differs from the requested bytes');
  }
  final length = end - start + 1;
  final bytes = BytesBuilder(copy: false);
  final done = Completer<void>();
  final subscription = response.listen(
    (chunk) {
      if (bytes.length + chunk.length > length) {
        done.completeError(StateError('media range exceeded its declared length'));
        return;
      }
      bytes.add(chunk);
      add(chunk.length);
    },
    onError: done.completeError,
    onDone: () => done.isCompleted ? null : done.complete(),
    cancelOnError: true,
  );
  try {
    await done.future.asCancellable(token);
  } finally {
    await subscription.cancel();
  }
  if (bytes.length != length) throw const HttpException('media range was truncated');
  return bytes.takeBytes();
}
