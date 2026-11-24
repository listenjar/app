// YouTube.js's Misc (src/parser/misc.ts): the values nodes are made of. Only
// the properties ListenJar reads so far; add others by their upstream names.
// ignore_for_file: non_constant_identifier_names
import 'package:cancellation_token/cancellation_token.dart';
import 'package:meta/meta.dart';

import 'engine.dart';
import 'innertube.dart';
import 'json.dart';

/// Formatted text. YouTube.js's runs are left out: [text] is all of them.
final class Text {
  const Text(this.text);
  final String? text;

  @internal
  static Text? fromJson(Object? raw) => raw is Map ? Text(string(raw['text'])) : null;

  @override
  String toString() => text ?? 'N/A';
}

final class Thumbnail {
  const Thumbnail({required this.url, required this.width, required this.height});
  final String url;
  final num width;
  final num height;

  @internal
  static Thumbnail fromJson(Object? raw) {
    final m = map(raw);
    return Thumbnail(url: string(m['url']) ?? '', width: number(m['width']) ?? 0, height: number(m['height']) ?? 0);
  }

  @internal
  static List<Thumbnail> listFromJson(Object? raw) => list(raw).map(fromJson).toList();
}

final class Author {
  const Author({required this.id, required this.name, required this.thumbnails, this.url});
  final String id;
  final String name;
  final List<Thumbnail> thumbnails;
  final String? url;

  @internal
  static Author? fromJson(Object? raw) {
    final m = mapOrNull(raw);
    if (m == null) return null;
    return Author(
      id: string(m['id']) ?? '',
      name: string(m['name']) ?? '',
      thumbnails: Thumbnail.listFromJson(m['thumbnails']),
      url: string(m['url']),
    );
  }
}

final class AudioTrack {
  const AudioTrack({required this.audio_is_default, required this.display_name, required this.id});
  final bool audio_is_default;
  final String display_name;
  final String id;
}

({int start, int end})? _byteRange(Object? raw) => switch (mapOrNull(raw)) {
  {'start': final num start, 'end': final num end} => (start: start.toInt(), end: end.toInt()),
  _ => null,
};

/// A stream format, live in YouTube.js until this object is collected.
final class Format {
  Format._(this._yt, this._handle, Json m)
    : itag = integer(m['itag']) ?? 0,
      url = string(m['url']),
      width = integer(m['width']),
      height = integer(m['height']),
      content_length = integer(m['content_length']),
      fps = number(m['fps']),
      bitrate = number(m['bitrate']) ?? 0,
      average_bitrate = number(m['average_bitrate']),
      mime_type = string(m['mime_type']) ?? '',
      is_type_otf = boolean(m['is_type_otf']) ?? false,
      has_audio = boolean(m['has_audio']) ?? false,
      has_video = boolean(m['has_video']) ?? false,
      drm_families = list(m['drm_families']).whereType<String>().toList(),
      xtags = string(m['xtags']),
      audio_quality = string(m['audio_quality']),
      approx_duration_ms = integer(m['approx_duration_ms']) ?? 0,
      init_range = _byteRange(m['init_range']),
      index_range = _byteRange(m['index_range']),
      audio_track = switch (mapOrNull(m['audio_track'])) {
        final t? => AudioTrack(
          audio_is_default: boolean(t['audio_is_default']) ?? false,
          display_name: string(t['display_name']) ?? '',
          id: string(t['id']) ?? '',
        ),
        null => null,
      },
      signature_cipher = string(m['signature_cipher']),
      cipher = string(m['cipher']) {
    retainHandle(_yt, this, _handle);
  }

  @internal
  static Format fromJson(YouTubei yt, Object? raw) {
    final m = map(raw);
    return Format._(yt, m[r'$handle']! as int, m);
  }

  final YouTubei _yt;
  final int _handle;

  final int itag;
  final String? url;
  final int? width;
  final int? height;
  final int? content_length;
  final num? fps;
  final num bitrate;
  final num? average_bitrate;
  final String mime_type;
  final bool is_type_otf;
  final bool has_audio;
  final bool has_video;
  final List<String> drm_families;
  final String? xtags;
  final String? audio_quality;
  final int approx_duration_ms;

  /// Where an adaptive format's initialization segment (ftyp, moov) and its
  /// segment index (sidx) lie in the file, inclusive.
  final ({int start, int end})? init_range;
  final ({int start, int end})? index_range;
  final AudioTrack? audio_track;
  final String? signature_cipher;
  final String? cipher;

  /// The playable URL, deciphered with [player]; without one, the URL as it
  /// came or an empty string.
  Future<String> decipher(Player? player, {CancellationToken? token}) async =>
    await callYouTubei(_yt, '__bridge.decipher', {'format': _handle, 'player': player?.handle}, token: token) as String;
}
