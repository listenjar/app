// Rewrites YouTube's AAC audio as a regular M4A before it is kept or
// uploaded (downloads.dart, sync.dart). YouTube sends a fragmented MP4 made
// for DASH: its moov holds no samples, and each fragment (moof, then mdat)
// indexes its own. A player that wants the whole index up front reads
// through the whole file first: AVPlayer, and Apple Podcasts with it, does,
// and reports about twice the real duration. A regular file indexes every
// sample in one moov ahead of the samples, so a player starts after its
// first bytes, as with ffmpeg's `-c copy -movflags +faststart`.
//
// Pure Dart, so it runs the same on every platform. Two passes, file to
// file, never holding the audio in memory: the first reads the fragment
// headers into one sample table (ISO/IEC 14496-12: stts, stsc, stsz, stco),
// the second writes ftyp, moov and a single mdat, copying each run of
// samples in order (one chunk per run). Anything unexpected (more than one
// track, an edit list, encryption, a gap) leaves the file as downloaded.
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cancellation_token/cancellation_token.dart';
import 'package:logging/logging.dart';

final _log = Logger('faststart');

/// [file], YouTube's AAC as downloaded (`audio/mp4`), rewritten as a
/// regular M4A next to it; the caller deletes or keeps the copy. Null, with
/// a warning, when [file] isn't a fragmented MP4 this can rewrite: use it as
/// it is.
Future<File?> faststart(File file, CancellationToken token) async {
  final output = File('${file.path}.m4a');
  try {
    final stopwatch = Stopwatch()..start();
    await _rewrite(file, output, token);
    _log.fine('Rewrote ${file.path} in ${stopwatch.elapsedMilliseconds} ms');
    return output;
  } on Object catch (e) {
    try {
      await output.delete();
    } on PathNotFoundException {
      // Failed before writing.
    }
    if (e is! FormatException && e is! RangeError) rethrow;
    _log.warning('Leaving ${file.path} as downloaded: $e');
    return null;
  }
}

/// A run of samples in the input: one chunk in the output.
typedef _Run = ({int offset, int length, int count, int description});

Future<void> _rewrite(File input, File output, CancellationToken token) async {
  final raf = await input.open();
  try {
    final length = await raf.length();
    _Track? track;
    final mdats = <(int, int)>[];

    // Pass 1: the top-level boxes, reading moov and each moof.
    var at = 0;
    while (at < length) {
      token.throwIfCancelled();
      await raf.setPosition(at);
      final head = ByteData.sublistView(await raf.read(16));
      if (head.lengthInBytes < 8) throw const FormatException('truncated box header');
      var size = head.getUint32(0);
      final type = _type(head, 4);
      var header = 8;
      if (size == 1) {
        size = head.getUint64(8);
        header = 16;
      } else if (size == 0) {
        size = length - at;
      }
      if (size < header || at + size > length) throw FormatException('truncated $type box');
      Future<ByteData> payload() async {
        if (size > 64 << 20) throw FormatException('$type box of $size bytes');
        await raf.setPosition(at + header);
        final bytes = await raf.read(size - header);
        if (bytes.length != size - header) throw FormatException('truncated $type box');
        return ByteData.sublistView(bytes);
      }

      switch (type) {
        case 'moov':
          if (track != null) throw const FormatException('two moov boxes');
          track = _Track(await payload());
        case 'moof':
          if (track == null) throw const FormatException('moof before moov');
          track.fragment(await payload(), at);
        case 'mdat':
          mdats.add((at + header, at + size));
        default:
        // ftyp, sidx, free: nothing the regular file needs.
      }
      at += size;
    }
    if (track == null) throw const FormatException('no moov');
    if (track.runs.isEmpty) throw const FormatException('no fragments');
    track.checkInside(mdats);

    // Pass 2: ftyp, moov, then the samples in one mdat.
    final ftyp = _box('ftyp', [_fourcc('M4A '), _u32(0x200), _fourcc('M4A '), _fourcc('isom'), _fourcc('mp42')]);
    final samples = track.runs.fold(0, (sum, run) => sum + run.length);
    final mdatHeader = samples + 8 > 0xffffffff
      ? (ByteData(16)
          ..setUint32(0, 1)
          ..setUint32(4, 0x6d646174 /* mdat */)
          ..setUint64(8, samples + 16))
      : (ByteData(8)
          ..setUint32(0, samples + 8)
          ..setUint32(4, 0x6d646174 /* mdat */));
    var wide = false;
    var moov = track.moov(0, wide: false);
    final lastOffset = ftyp.length + moov.length + mdatHeader.lengthInBytes + samples - track.runs.last.length;
    if (lastOffset > 0xffffffff) {
      wide = true;
      moov = track.moov(0, wide: true);
    }
    moov = track.moov(ftyp.length + moov.length + mdatHeader.lengthInBytes, wide: wide);

    final out = await output.open(mode: FileMode.write);
    try {
      await out.writeFrom(ftyp);
      await out.writeFrom(moov);
      await out.writeFrom(Uint8List.sublistView(mdatHeader));
      final buffer = Uint8List(1 << 20);
      for (final run in track.runs) {
        token.throwIfCancelled();
        await raf.setPosition(run.offset);
        var left = run.length;
        while (left > 0) {
          final n = await raf.readInto(buffer, 0, min(left, buffer.length));
          if (n == 0) throw const FormatException('file ended inside samples');
          await out.writeFrom(buffer, 0, n);
          left -= n;
        }
      }
    } finally {
      await out.close();
    }
  } finally {
    await raf.close();
  }
}

/// The one track of a fragmented MP4: its moov, the defaults its fragments
/// fall back on (trex), and the sample table gathered from them.
final class _Track {
  _Track(ByteData moov) : _moov = _children(moov) {
    final mvhd = _one(_moov, 'mvhd');
    _movieTimescale = _mid32(mvhd.data);
    final trak = _one(_moov, 'trak');
    final trakBoxes = _children(trak.data);
    if (trakBoxes.any((b) => b.type == 'edts')) throw const FormatException('edit list');
    _id = _mid32(_one(trakBoxes, 'tkhd').data);
    final mdia = _children(_one(trakBoxes, 'mdia').data);
    _mediaTimescale = _mid32(_one(mdia, 'mdhd').data);
    final stbl = _children(_one(_children(_one(mdia, 'minf').data), 'stbl').data);
    for (final box in stbl) {
      if (!const {'stsd', 'stts', 'stsc', 'stsz', 'stco', 'co64', 'sgpd'}.contains(box.type)) {
        throw FormatException('${box.type} in stbl');
      }
      if (const {'stts', 'stsc', 'stsz', 'stco', 'co64'}.contains(box.type) && box.data.getUint32(4) != 0) {
        throw FormatException('samples in the moov ${box.type}');
      }
    }
    _one(stbl, 'stsd');
    if (_movieTimescale == 0 || _mediaTimescale == 0) throw const FormatException('zero timescale');
    final trex = _children(_one(_moov, 'mvex').data).where((b) => b.type == 'trex' && b.data.getUint32(4) == _id).firstOrNull;
    if (trex != null) {
      _defaultDescription = trex.data.getUint32(8);
      _defaultDuration = trex.data.getUint32(12);
      _defaultSize = trex.data.getUint32(16);
      _defaultFlags = trex.data.getUint32(20);
    }
  }

  final List<_Box> _moov;
  late final int _movieTimescale;
  late final int _mediaTimescale;
  late final int _id;
  int? _defaultDescription;
  int? _defaultDuration;
  int? _defaultSize;
  int? _defaultFlags;

  final runs = <_Run>[];
  final _sizes = <int>[];
  final _sttsCounts = <int>[];
  final _sttsDeltas = <int>[];
  var _duration = 0;
  int? _decodeStart;

  /// Adds the samples of the moof at [moofOffset] in the file.
  void fragment(ByteData moof, int moofOffset) {
    final trafs = <_Box>[];
    for (final box in _children(moof)) {
      switch (box.type) {
        case 'mfhd':
          break;
        case 'traf':
          trafs.add(box);
        default:
          throw FormatException('${box.type} in moof');
      }
    }
    if (trafs.length != 1) throw FormatException('${trafs.length} tracks in a fragment');
    final traf = _children(trafs.single.data);
    for (final box in traf) {
      if (!const {'tfhd', 'tfdt', 'trun'}.contains(box.type)) throw FormatException('${box.type} in traf');
    }

    // tfhd: where the data is, and this fragment's defaults.
    final tfhd = _one(traf, 'tfhd').data;
    final tfhdFlags = tfhd.getUint32(0) & 0xffffff;
    if (tfhd.getUint32(4) != _id) throw const FormatException('fragment of another track');
    if (tfhdFlags & 0x10000 != 0) throw const FormatException('empty fragment duration');
    var at = 8;
    int field32() => tfhd.getUint32((at += 4) - 4);
    // Without a base-data-offset, the data is relative to the moof: the
    // only traf is the first, so default-base-is-moof changes nothing.
    final base = tfhdFlags & 0x1 != 0 ? tfhd.getUint64((at += 8) - 8) : moofOffset;
    final description = tfhdFlags & 0x2 != 0 ? field32() : _defaultDescription;
    final defaultDuration = tfhdFlags & 0x8 != 0 ? field32() : _defaultDuration;
    final defaultSize = tfhdFlags & 0x10 != 0 ? field32() : _defaultSize;
    final defaultFlags = tfhdFlags & 0x20 != 0 ? field32() : _defaultFlags;
    if (description == null || description == 0) throw const FormatException('no sample description');

    // tfdt: the fragments must follow one another without gaps.
    final tfdt = traf.where((b) => b.type == 'tfdt').firstOrNull?.data;
    if (tfdt != null) {
      final time = tfdt.getUint8(0) == 1 ? tfdt.getUint64(4) : tfdt.getUint32(4);
      _decodeStart ??= time;
      if (time != _decodeStart! + _duration) throw FormatException('fragment at $time, expected ${_decodeStart! + _duration}');
    }

    var next = base;
    for (final trun in traf.where((b) => b.type == 'trun').map((b) => b.data)) {
      final flags = trun.getUint32(0) & 0xffffff;
      final count = trun.getUint32(4);
      var at = 8;
      final offset = flags & 0x1 != 0 ? base + trun.getInt32((at += 4) - 4) : next;
      final firstFlags = flags & 0x4 != 0 ? trun.getUint32((at += 4) - 4) : null;
      var length = 0;
      for (var i = 0; i < count; i++) {
        final duration = flags & 0x100 != 0 ? trun.getUint32((at += 4) - 4) : defaultDuration;
        final size = flags & 0x200 != 0 ? trun.getUint32((at += 4) - 4) : defaultSize;
        var sampleFlags = flags & 0x400 != 0 ? trun.getUint32((at += 4) - 4) : defaultFlags;
        if (i == 0 && firstFlags != null) sampleFlags = firstFlags;
        if (flags & 0x800 != 0 && trun.getInt32((at += 4) - 4) != 0) throw const FormatException('composition offsets');
        if (duration == null || size == null) throw const FormatException('sample without a duration or size');
        // is_non_sync_sample: every AAC sample is a sync sample, so there is no stss.
        if ((sampleFlags ?? 0) & 0x10000 != 0) throw const FormatException('non-sync sample');
        _sizes.add(size);
        if (_sttsDeltas.isNotEmpty && _sttsDeltas.last == duration) {
          _sttsCounts.last++;
        } else {
          _sttsCounts.add(1);
          _sttsDeltas.add(duration);
        }
        _duration += duration;
        length += size;
      }
      if (count > 0) runs.add((offset: offset, length: length, count: count, description: description));
      next = offset + length;
    }
  }

  /// Throws unless every run of samples lies inside an mdat.
  void checkInside(List<(int, int)> mdats) {
    var m = 0;
    for (final run in runs) {
      if (m < mdats.length && run.offset < mdats[m].$1) m = 0;
      while (m < mdats.length && mdats[m].$2 <= run.offset) {
        m++;
      }
      if (m == mdats.length || run.offset < mdats[m].$1 || run.offset + run.length > mdats[m].$2) {
        throw FormatException('samples at ${run.offset} outside any mdat');
      }
    }
  }

  /// The regular moov, its chunks starting at [dataStart] in the output;
  /// [wide] chunk offsets (co64) when they pass 4 GiB.
  Uint8List moov(int dataStart, {required bool wide}) {
    final movieDuration = (_duration * _movieTimescale + _mediaTimescale ~/ 2) ~/ _mediaTimescale;
    return _rebuild('moov', _moov, (box) => switch (box.type) {
      'mvhd' => _withDuration(box, 4, movieDuration),
      'mvex' => Uint8List(0),
      'trak' => _rebuild('trak', _children(box.data), (box) => switch (box.type) {
        'tkhd' => _withDuration(box, 8, movieDuration),
        'mdia' => _rebuild('mdia', _children(box.data), (box) => switch (box.type) {
          'mdhd' => _withDuration(box, 4, _duration),
          'minf' => _rebuild('minf', _children(box.data), (box) => switch (box.type) {
            'stbl' => _stbl(box, dataStart, wide),
            _ => null,
          }),
          _ => null,
        }),
        _ => null,
      }),
      _ => null,
    });
  }

  Uint8List _stbl(_Box stbl, int dataStart, bool wide) {
    final boxes = _children(stbl.data);

    final stts = ByteData(8 + _sttsCounts.length * 8)..setUint32(4, _sttsCounts.length);
    for (var i = 0; i < _sttsCounts.length; i++) {
      stts
        ..setUint32(8 + i * 8, _sttsCounts[i])
        ..setUint32(12 + i * 8, _sttsDeltas[i]);
    }

    final stsc = <int>[];
    for (var i = 0; i < runs.length; i++) {
      final run = runs[i];
      if (i > 0 && runs[i - 1].count == run.count && runs[i - 1].description == run.description) continue;
      stsc.addAll([i + 1, run.count, run.description]);
    }
    final stscBox = ByteData(8 + stsc.length * 4)..setUint32(4, stsc.length ~/ 3);
    for (var i = 0; i < stsc.length; i++) {
      stscBox.setUint32(8 + i * 4, stsc[i]);
    }

    final stsz = ByteData(12 + _sizes.length * 4)..setUint32(8, _sizes.length);
    for (var i = 0; i < _sizes.length; i++) {
      stsz.setUint32(12 + i * 4, _sizes[i]);
    }

    final width = wide ? 8 : 4;
    final stco = ByteData(8 + runs.length * width)..setUint32(4, runs.length);
    var offset = dataStart;
    for (var i = 0; i < runs.length; i++) {
      wide ? stco.setUint64(8 + i * 8, offset) : stco.setUint32(8 + i * 4, offset);
      offset += runs[i].length;
    }

    return _box('stbl', [
      _box('stsd', [_bytes(_one(boxes, 'stsd').data)]),
      _box('stts', [Uint8List.sublistView(stts)]),
      _box('stsc', [Uint8List.sublistView(stscBox)]),
      _box('stsz', [Uint8List.sublistView(stsz)]),
      _box(wide ? 'co64' : 'stco', [Uint8List.sublistView(stco)]),
      for (final box in boxes.where((b) => b.type == 'sgpd')) _box('sgpd', [_bytes(box.data)]),
    ]);
  }
}

/// A box: its type and its payload, after the header.
typedef _Box = ({String type, ByteData data});

/// The boxes [data] holds, in order.
List<_Box> _children(ByteData data) {
  final boxes = <_Box>[];
  var at = 0;
  while (at < data.lengthInBytes) {
    var size = data.getUint32(at);
    var header = 8;
    if (size == 1) {
      size = data.getUint64(at + 8);
      header = 16;
    } else if (size == 0) {
      size = data.lengthInBytes - at;
    }
    if (size < header || at + size > data.lengthInBytes) throw const FormatException('box overruns its parent');
    boxes.add((type: _type(data, at + 4), data: ByteData.sublistView(data, at + header, at + size)));
    at += size;
  }
  return boxes;
}

_Box _one(List<_Box> boxes, String type) {
  final found = boxes.where((b) => b.type == type).toList();
  if (found.length != 1) throw FormatException('${found.length} $type boxes');
  return found.single;
}

/// [children] in a box of [type], each replaced by what [replace] answers,
/// or kept when it answers null.
Uint8List _rebuild(String type, List<_Box> children, Uint8List? Function(_Box) replace) =>
  _box(type, [for (final child in children) replace(child) ?? _box(child.type, [_bytes(child.data)])]);

/// A full box laid out as version and flags, creation and modification
/// times, [mid] bytes, a duration, and the rest (mvhd, tkhd, mdhd), with
/// [duration]. The times are 32-bit in version 0 and 64-bit in version 1,
/// which this switches to when [duration] needs it.
Uint8List _withDuration(_Box box, int mid, int duration) {
  final data = box.data;
  final version = data.getUint8(0);
  if (version > 1) throw FormatException('${box.type} version $version');
  final t = version == 1 ? 8 : 4;
  int time(int at) => t == 8 ? data.getUint64(at) : data.getUint32(at);
  final midAt = 4 + 2 * t;
  final restAt = midAt + mid + t;
  final wide = version == 1 || duration > 0xffffffff;
  final w = wide ? 8 : 4;
  final head = ByteData(4 + 2 * w)..setUint32(0, (wide ? 1 << 24 : 0) | data.getUint32(0) & 0xffffff);
  final durationBytes = ByteData(w);
  if (wide) {
    head
      ..setUint64(4, time(4))
      ..setUint64(12, time(4 + t));
    durationBytes.setUint64(0, duration);
  } else {
    head
      ..setUint32(4, time(4))
      ..setUint32(8, time(4 + t));
    durationBytes.setUint32(0, duration);
  }
  return _box(box.type, [
    Uint8List.sublistView(head),
    Uint8List.sublistView(data, midAt, midAt + mid),
    Uint8List.sublistView(durationBytes),
    Uint8List.sublistView(data, restAt),
  ]);
}

/// The 32-bit field after a full box's two times: mvhd's and mdhd's
/// timescale, tkhd's track ID.
int _mid32(ByteData data) => data.getUint32(data.getUint8(0) == 1 ? 20 : 12);

Uint8List _box(String type, List<Uint8List> parts) {
  final length = parts.fold(8, (sum, part) => sum + part.length);
  final out = Uint8List(length);
  ByteData.sublistView(out).setUint32(0, length);
  out.setAll(4, type.codeUnits);
  var at = 8;
  for (final part in parts) {
    out.setAll(at, part);
    at += part.length;
  }
  return out;
}

Uint8List _bytes(ByteData data) => Uint8List.sublistView(data);

Uint8List _u32(int value) => Uint8List.sublistView(ByteData(4)..setUint32(0, value));

Uint8List _fourcc(String code) => Uint8List.fromList(code.codeUnits);

String _type(ByteData data, int at) => String.fromCharCodes([for (var i = 0; i < 4; i++) data.getUint8(at + i)]);
