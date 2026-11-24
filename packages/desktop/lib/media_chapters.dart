// The chapters an audio file carries itself, as podcast publishers embed
// them: ID3v2 CHAP frames in an MP3, and in an M4A a QuickTime chapter track
// (Apple's) or Nero's chpl box. From a download, or from the stream as it
// plays, through HTTP range requests: either way it reads the tag or the
// moov and the chapter titles, never the audio. Pure Dart, no widgets.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cancellation_token/cancellation_token.dart';

import 'chapters.dart';

/// A tag or moov larger than this isn't read.
const _limit = 16 << 20;

/// More chapter samples than this aren't read.
const _most = 1000;

/// The chapters in [file], or none when it carries none this can read.
Future<List<Chapter>> fileChapters(File file) async {
  final raf = await file.open();
  try {
    return await _chapters(_FileBytes(raf, await raf.length()));
  } finally {
    await raf.close();
  }
}

/// The chapters in the audio at [url], read with range requests, or none
/// when it carries none this can read or its server can't send ranges.
Future<List<Chapter>> streamChapters(HttpClient http, Uri url, CancellationToken token) async {
  final head = await _HttpBytes.open(http, url, token);
  return head == null ? const [] : _chapters(head);
}

Future<List<Chapter>> _chapters(_Bytes bytes) async {
  try {
    final head = await bytes.read(0, 10);
    if (head.length < 10) return const [];
    if (_ascii(head, 0, 3) == 'ID3') return _named(await _id3(bytes, head));
    if (_ascii(head, 4, 8) == 'ftyp') return _named(await _mp4(bytes));
    return const [];
  } on FormatException {
    return const [];
  } on RangeError {
    return const [];
  }
}

/// Where the audio's bytes come from: random access, in windows of at least
/// [_window], kept so that nearby reads cost nothing more.
abstract class _Bytes {
  _Bytes(this.length);
  final int length;

  /// Of a stream, one request's worth: an ID3 tag usually, an M4A's header.
  static const _window = 256 << 10;

  Uint8List _kept = Uint8List(0);
  int _keptAt = 0;

  /// [count] bytes from [offset], fewer at the end.
  Future<Uint8List> read(int offset, int count) async {
    final end = (offset + count).clamp(0, length);
    if (offset < _keptAt || end > _keptAt + _kept.length) {
      _kept = await fetch(offset, ((offset + (count > _window ? count : _window)).clamp(0, length)) - offset);
      _keptAt = offset;
    }
    return Uint8List.sublistView(_kept, offset - _keptAt, (end - _keptAt).clamp(0, _kept.length));
  }

  Future<Uint8List> fetch(int offset, int count);
}

final class _FileBytes extends _Bytes {
  _FileBytes(this._raf, super.length);
  final RandomAccessFile _raf;

  @override
  Future<Uint8List> fetch(int offset, int count) async {
    await _raf.setPosition(offset);
    return _raf.read(count);
  }
}

final class _HttpBytes extends _Bytes {
  _HttpBytes._(this._http, this._url, this._token, int length, Uint8List first) : super(length) {
    _kept = first;
  }

  final HttpClient _http;
  final Uri _url;
  final CancellationToken _token;

  /// The first window, and with it the length; null when the server doesn't
  /// answer a range request with one.
  static Future<_HttpBytes?> open(HttpClient http, Uri url, CancellationToken token) async {
    final (body, total) = await _get(http, url, 0, _Bytes._window, token);
    if (total == null) return null;
    return _HttpBytes._(http, url, token, total, body);
  }

  @override
  Future<Uint8List> fetch(int offset, int count) async => (await _get(_http, _url, offset, count, _token)).$1;

  /// [count] bytes from [offset], and the whole length from Content-Range.
  static Future<(Uint8List, int?)> _get(HttpClient http, Uri url, int offset, int count, CancellationToken token) async {
    final request = await http.getUrl(url).asCancellable(token);
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-${offset + count - 1}');
    final response = await request.close().asCancellable(token);
    if (response.statusCode != HttpStatus.partialContent) {
      // The whole file instead, or an error: not something to read a tag
      // from, so not read at all.
      (await response.detachSocket()).destroy();
      return (Uint8List(0), null);
    }
    final total = int.tryParse(response.headers.value(HttpHeaders.contentRangeHeader)?.split('/').last ?? '');
    final body = BytesBuilder(copy: false);
    await for (final chunk in response) {
      token.throwIfCancelled();
      body.add(chunk);
    }
    return (body.toBytes(), total);
  }
}

/// In start order, each with a title.
List<Chapter> _named(List<Chapter> chapters) {
  chapters.sort((a, b) => a.start.compareTo(b.start));
  return [
    for (final (i, c) in chapters.indexed) (start: c.start, title: c.title.isEmpty ? 'Chapter ${i + 1}' : c.title),
  ];
}

// MP3: ID3v2.3 and 2.4 (id3.org's id3v2-chapters-1.0).

Future<List<Chapter>> _id3(_Bytes bytes, Uint8List head) async {
  final major = head[3];
  if (major != 3 && major != 4) return const [];
  final flags = head[5];
  final size = _syncsafe(head, 6);
  if (size > _limit) return const [];
  var tag = await bytes.read(10, size);
  // 2.3 unsynchronises the whole tag; 2.4 does it per frame, rarely.
  if (major == 3 && flags & 0x80 != 0) tag = _resync(tag);
  var at = 0;
  if (flags & 0x40 != 0) at = major == 4 ? _syncsafe(tag, 0) : _u32(tag, 0) + 4;
  final chapters = <Chapter>[];
  for (final (id, body) in _frames(tag, at, major)) {
    if (id != 'CHAP') continue;
    final end = body.indexOf(0);
    if (end < 0 || end + 17 > body.length) continue;
    var title = '';
    for (final (sub, text) in _frames(body, end + 17, major)) {
      if (sub == 'TIT2') title = _id3Text(text);
    }
    chapters.add((start: Duration(milliseconds: _u32(body, end + 1)), title: title));
  }
  return chapters;
}

Iterable<(String, Uint8List)> _frames(Uint8List data, int from, int major) sync* {
  var at = from;
  while (at + 10 <= data.length && data[at] != 0) {
    final id = _ascii(data, at, at + 4);
    final size = major == 4 ? _syncsafe(data, at + 4) : _u32(data, at + 4);
    final body = at + 10;
    if (size < 0 || body + size > data.length) return;
    yield (id, Uint8List.sublistView(data, body, body + size));
    at = body + size;
  }
}

String _id3Text(Uint8List frame) {
  if (frame.isEmpty) return '';
  final bytes = Uint8List.sublistView(frame, 1);
  final text = switch (frame[0]) {
    0 => latin1.decode(bytes),
    1 => _utf16(bytes, bigEndian: false, bom: true),
    2 => _utf16(bytes, bigEndian: true, bom: false),
    _ => utf8.decode(bytes, allowMalformed: true),
  };
  return text.replaceAll('\u0000', '').trim();
}

Uint8List _resync(Uint8List data) {
  final out = BytesBuilder(copy: false);
  for (var i = 0; i < data.length; i++) {
    out.addByte(data[i]);
    if (data[i] == 0xFF && i + 1 < data.length && data[i + 1] == 0) i++;
  }
  return out.toBytes();
}

int _syncsafe(Uint8List b, int at) => (b[at] & 0x7F) << 21 | (b[at + 1] & 0x7F) << 14 | (b[at + 2] & 0x7F) << 7 | b[at + 3] & 0x7F;

// M4A: ISO/IEC 14496-12 boxes.

typedef _Box = ({String type, ByteData data});

Future<List<Chapter>> _mp4(_Bytes bytes) async {
  final length = bytes.length;
  var at = 0;
  ByteData? moov;
  while (at + 8 <= length) {
    final header = ByteData.sublistView(await bytes.read(at, 16));
    var size = header.getUint32(0);
    var headerSize = 8;
    if (size == 1) {
      size = header.getUint64(8);
      headerSize = 16;
    } else if (size == 0) {
      size = length - at;
    }
    if (size < headerSize) return const [];
    if (_type(header, 4) == 'moov') {
      if (size > _limit) return const [];
      moov = ByteData.sublistView(await bytes.read(at + headerSize, size - headerSize));
      break;
    }
    at += size;
  }
  if (moov == null) return const [];
  final boxes = _children(moov);
  final quickTime = await _chapterTrack(bytes, boxes);
  if (quickTime.isNotEmpty) return quickTime;
  final chpl = _child(_child(boxes, 'udta'), 'chpl');
  return chpl == null ? const [] : _nero(chpl);
}

/// The text track an audio track names as its chapters (tref `chap`): one
/// sample a chapter, its title.
Future<List<Chapter>> _chapterTrack(_Bytes bytes, List<_Box> moov) async {
  final tracks = [for (final b in moov) if (b.type == 'trak') _children(b.data)];
  final referenced = <int>{};
  for (final track in tracks) {
    if (_child(_child(track, 'tref'), 'chap') case final chap?) {
      for (var i = 0; i + 4 <= chap.lengthInBytes; i += 4) {
        referenced.add(chap.getUint32(i));
      }
    }
  }
  for (final track in tracks) {
    final tkhd = _child(track, 'tkhd');
    if (tkhd == null || !referenced.contains(tkhd.getUint32(tkhd.getUint8(0) == 1 ? 20 : 12))) continue;
    final mdia = _children(_child(track, 'mdia')!);
    final mdhd = _child(mdia, 'mdhd')!;
    final timescale = mdhd.getUint32(mdhd.getUint8(0) == 1 ? 20 : 12);
    final stbl = _children(_child(_child(mdia, 'minf'), 'stbl')!);
    if (timescale == 0) return const [];

    // Each sample's start, from its durations.
    final starts = <int>[];
    final stts = _child(stbl, 'stts')!;
    var t = 0;
    for (var i = 0, n = stts.getUint32(4); i < n && starts.length < _most; i++) {
      final count = stts.getUint32(8 + i * 8);
      final delta = stts.getUint32(12 + i * 8);
      for (var j = 0; j < count && starts.length < _most; j++) {
        starts.add(t);
        t += delta;
      }
    }

    // Each sample's place in the file, from the chunks.
    final stsz = _child(stbl, 'stsz')!;
    final fixed = stsz.getUint32(4);
    int sizeOf(int sample) => fixed != 0 ? fixed : stsz.getUint32(12 + sample * 4);
    final chunks = <int>[];
    if (_child(stbl, 'stco') case final stco?) {
      for (var i = 0, n = stco.getUint32(4); i < n; i++) {
        chunks.add(stco.getUint32(8 + i * 4));
      }
    } else if (_child(stbl, 'co64') case final co64?) {
      for (var i = 0, n = co64.getUint32(4); i < n; i++) {
        chunks.add(co64.getUint64(8 + i * 8));
      }
    }
    final stsc = _child(stbl, 'stsc')!;
    final runs = [for (var i = 0, n = stsc.getUint32(4); i < n; i++) (first: stsc.getUint32(8 + i * 12), count: stsc.getUint32(12 + i * 12))];
    final places = <(int, int)>[];
    var sample = 0;
    for (var c = 0; c < chunks.length && places.length < starts.length; c++) {
      final perChunk = runs.lastWhere((r) => r.first <= c + 1, orElse: () => (first: 1, count: 1)).count;
      var offset = chunks[c];
      for (var j = 0; j < perChunk && places.length < starts.length; j++, sample++) {
        places.add((offset, sizeOf(sample)));
        offset += sizeOf(sample);
      }
    }

    final chapters = <Chapter>[];
    if (places.isEmpty) return const [];
    // The titles usually sit together: one read for all of them.
    final first = places.map((p) => p.$1).reduce((a, b) => a < b ? a : b);
    final last = places.map((p) => p.$1 + p.$2).reduce((a, b) => a > b ? a : b);
    if (last - first <= _limit) await bytes.read(first, last - first);
    for (final (i, (offset, size)) in places.indexed) {
      if (size < 2) continue;
      final sample = await bytes.read(offset, size);
      if (sample.length < 2) continue;
      final textLength = ByteData.sublistView(sample).getUint16(0);
      final text = Uint8List.sublistView(sample, 2, (2 + textLength).clamp(2, sample.length));
      final title = text.length >= 2 && text[0] == 0xFE && text[1] == 0xFF
        ? _utf16(text, bigEndian: true, bom: true)
        : utf8.decode(text, allowMalformed: true);
      chapters.add((start: Duration(microseconds: starts[i] * 1000000 ~/ timescale), title: title.trim()));
    }
    return chapters;
  }
  return const [];
}

/// Nero's chapter list: 100 ns start times and titles.
List<Chapter> _nero(ByteData chpl) {
  var at = chpl.getUint8(0) == 1 ? 8 : 4;
  final count = chpl.getUint8(at++);
  final chapters = <Chapter>[];
  for (var i = 0; i < count && at + 9 <= chpl.lengthInBytes; i++) {
    final start = chpl.getUint64(at);
    final length = chpl.getUint8(at + 8);
    at += 9;
    final title = utf8.decode(Uint8List.sublistView(chpl, at, at + length), allowMalformed: true);
    at += length;
    chapters.add((start: Duration(microseconds: start ~/ 10), title: title.trim()));
  }
  return chapters;
}

List<_Box> _children(ByteData data) {
  final boxes = <_Box>[];
  var at = 0;
  while (at + 8 <= data.lengthInBytes) {
    var size = data.getUint32(at);
    var header = 8;
    if (size == 1) {
      size = data.getUint64(at + 8);
      header = 16;
    } else if (size == 0) {
      size = data.lengthInBytes - at;
    }
    if (size < header || at + size > data.lengthInBytes) break;
    boxes.add((type: _type(data, at + 4), data: ByteData.sublistView(data, at + header, at + size)));
    at += size;
  }
  return boxes;
}

ByteData? _child(Object? parent, String type) {
  final boxes = switch (parent) {
    final List<_Box> list => list,
    final ByteData data => _children(data),
    _ => const <_Box>[],
  };
  for (final b in boxes) {
    if (b.type == type) return b.data;
  }
  return null;
}

// Bytes.

String _type(ByteData data, int at) => String.fromCharCodes([for (var i = 0; i < 4; i++) data.getUint8(at + i)]);

String _ascii(Uint8List b, int from, int to) => String.fromCharCodes(b.sublist(from, to));

int _u32(Uint8List b, int at) => b[at] << 24 | b[at + 1] << 16 | b[at + 2] << 8 | b[at + 3];

String _utf16(Uint8List bytes, {required bool bigEndian, required bool bom}) {
  var big = bigEndian;
  var at = 0;
  if (bom && bytes.length >= 2) {
    if (bytes[0] == 0xFF && bytes[1] == 0xFE) {
      big = false;
      at = 2;
    } else if (bytes[0] == 0xFE && bytes[1] == 0xFF) {
      big = true;
      at = 2;
    }
  }
  final units = <int>[
    for (var i = at; i + 1 < bytes.length; i += 2) big ? bytes[i] << 8 | bytes[i + 1] : bytes[i + 1] << 8 | bytes[i],
  ];
  return String.fromCharCodes(units);
}
