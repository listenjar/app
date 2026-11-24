// Serves the YouTube stream playing to the audio player, from a loopback
// HTTP server. The audio player (AVPlayer, ExoPlayer, libmpv) asks for the
// rest of the file in one request, which YouTube's media servers send at a
// trickle; this answers it from short ranges fetched ahead (transfer.dart's
// streamRange). It writes with addStream, so the fetching pauses while the
// player isn't reading: each open request holds at most a few ranges in
// memory. just_audio's own header proxy reads ahead without that limit.
//
// AVPlayer gets an HLS playlist instead of the file. YouTube's audio is a
// fragmented MP4 that names neither its length nor where its fragments are,
// so AVPlayer reads through the whole file before it plays (and reports
// twice the real duration). The file's segment index (sidx) says both; the
// playlist lists each segment by byte range, so AVPlayer starts after the
// first one.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cancellation_token/cancellation_token.dart';

import 'log.dart';
import 'transfer.dart' as transfer;
import 'youtube.dart';

final _log = Logger('stream');

final class StreamServer {
  StreamServer(this._http);

  final HttpClient _http;
  Future<HttpServer>? _server;
  _Served? _served;
  var _count = 0;

  /// A URL that plays [stream] until [token] is cancelled or another stream
  /// replaces it: the player plays one at a time. With [hls], an HLS
  /// playlist of the stream's segments when its index allows.
  Future<Uri> serve(MediaStream stream, int length, String contentType, CancellationToken token, {required bool hls}) async {
    final server = await (_server ??= _start());
    final base = '/${++_count}';
    final media = '$base${contentType == 'audio/webm' ? '.webm' : '.m4a'}';
    final playlist = hls && contentType == 'audio/mp4' ? await _playlist(stream, length, media, token) : null;
    _served = _Served(media, stream, length, contentType, token, playlist?.$1 == null ? null : '$base.m3u8', playlist?.$1, playlist?.$2);
    return Uri(scheme: 'http', host: server.address.address, port: server.port, path: playlist == null ? media : '$base.m3u8');
  }

  Future<HttpServer> _start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) => unawaited(_handle(request)));
    return server;
  }

  /// An HLS playlist of [stream]'s segments, and the file's first bytes
  /// (initialization segment and index) fetched to write it; null without
  /// an index.
  Future<(String, Uint8List)?> _playlist(MediaStream stream, int total, String media, CancellationToken token) async {
    final init = stream.format.init_range;
    final index = stream.format.index_range;
    if (init == null || index == null || init.start != 0 || index.end >= total) return null;
    final head = await traced(_log, 'segment index', () => transfer.fetchRange(_http, stream, 0, index.end + 1, total, token));
    final sidx = _parseSidx(ByteData.sublistView(head, index.start, index.end + 1));
    if (sidx == null) {
      _log.warning('Unreadable segment index; AVPlayer reads the whole file');
      return null;
    }
    final (:timescale, :firstOffset, :segments) = sidx;
    var offset = index.end + 1 + firstOffset;
    final lines = <String>[];
    var longest = 0.0;
    for (final (size, duration) in segments) {
      final seconds = duration / timescale;
      if (seconds > longest) longest = seconds;
      lines
        ..add('#EXTINF:${seconds.toStringAsFixed(3)},')
        ..add('#EXT-X-BYTERANGE:$size@$offset')
        ..add(media.substring(1));
      offset += size;
    }
    if (offset > total) return null;
    final playlist = [
      '#EXTM3U',
      '#EXT-X-VERSION:7',
      '#EXT-X-TARGETDURATION:${longest.ceil()}',
      '#EXT-X-PLAYLIST-TYPE:VOD',
      '#EXT-X-INDEPENDENT-SEGMENTS',
      '#EXT-X-MAP:URI="${media.substring(1)}",BYTERANGE="${init.end + 1}@0"',
      ...lines,
      '#EXT-X-ENDLIST',
      '',
    ].join('\n');
    return (playlist, head);
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    final served = _served;
    try {
      if (served == null || served.token.isCancelled) {
        response.statusCode = HttpStatus.notFound;
        return;
      }
      if (request.uri.path == served.playlistPath) {
        response.headers.contentType = ContentType('application', 'vnd.apple.mpegurl', charset: 'utf-8');
        response.write(served.playlist);
        return;
      }
      if (request.uri.path != served.path) {
        response.statusCode = HttpStatus.notFound;
        return;
      }
      final total = served.length;
      response.headers
        ..contentType = ContentType.parse(served.contentType)
        ..set(HttpHeaders.acceptRangesHeader, 'bytes');
      final range = request.headers.value(HttpHeaders.rangeHeader);
      final (start, end) = range == null ? (0, total) : _range(range, total) ?? (-1, -1);
      if (start < 0) {
        response
          ..statusCode = HttpStatus.requestedRangeNotSatisfiable
          ..headers.set(HttpHeaders.contentRangeHeader, 'bytes */$total');
        return;
      }
      if (range != null) {
        response
          ..statusCode = HttpStatus.partialContent
          ..headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-${end - 1}/$total');
      }
      response.contentLength = end - start;
      if (request.method == 'HEAD') return;
      // FINER: AVPlayer asks for each ~10 s segment on its own.
      _log.finer('${request.method} $start-$end of $total');
      // The initialization segment, already here from writing the playlist.
      if (served.head case final head? when end <= head.length) {
        response.add(Uint8List.sublistView(head, start, end));
        return;
      }
      await response.addStream(transfer.streamRange(_http, served.stream, start, end, total, served.token));
    } on CancelledException {
      // Another episode, or the app is closing.
    } on HttpException {
      // The player hung up: it seeked, or has enough.
    } on SocketException {
      // The same, noticed while writing.
    } catch (e, stack) {
      _log.warning('Streaming ${request.uri.path} failed', e, stack);
    } finally {
      await response.close().then<void>((_) {}, onError: (_) {});
    }
  }

  Future<void> close() async {
    _served = null;
    await (await _server)?.close(force: true);
  }
}

final class _Served {
  const _Served(this.path, this.stream, this.length, this.contentType, this.token, this.playlistPath, this.playlist, this.head);
  final String path;
  final MediaStream stream;
  final int length;
  final String contentType;
  final CancellationToken token;
  final String? playlistPath;
  final String? playlist;
  final Uint8List? head;
}

/// A segment index box (ISO/IEC 14496-12 `sidx`): the timescale, where the
/// first segment starts after the box, and each segment's size in bytes
/// and duration in timescale units. Null for anything else, or an index of
/// indexes.
({int timescale, int firstOffset, List<(int, int)> segments})? _parseSidx(ByteData box) {
  if (box.lengthInBytes < 32 || box.getUint32(4) != 0x73696478 /* sidx */ ) return null;
  final version = box.getUint8(8);
  final timescale = box.getUint32(16);
  var at = 20;
  final int firstOffset;
  if (version == 0) {
    firstOffset = box.getUint32(at + 4);
    at += 8;
  } else {
    firstOffset = box.getUint64(at + 8);
    at += 16;
  }
  final count = box.getUint16(at + 2);
  at += 4;
  if (timescale == 0 || count == 0 || box.lengthInBytes < at + count * 12) return null;
  final segments = <(int, int)>[];
  for (var i = 0; i < count; i++, at += 12) {
    final reference = box.getUint32(at);
    if (reference >> 31 != 0) return null;
    segments.add((reference & 0x7fffffff, box.getUint32(at + 4)));
  }
  return (timescale: timescale, firstOffset: firstOffset, segments: segments);
}

/// A `Range: bytes=…` header as [start, end) within [total]; null when it
/// can't be satisfied.
(int, int)? _range(String header, int total) {
  final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(header.trim());
  if (match == null) return null;
  final first = int.tryParse(match[1]!);
  final last = int.tryParse(match[2]!);
  final (start, end) = switch ((first, last)) {
    (final a?, final b?) => (a, b + 1),
    (final a?, null) => (a, total),
    // The last b bytes.
    (null, final b?) => (total - b, total),
    _ => (-1, -1),
  };
  if (start < 0 || start >= total || end <= start) return null;
  return (start, end > total ? total : end);
}
