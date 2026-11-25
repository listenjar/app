// Podcast feeds as the player reads them: fetched over HTTP with the
// validators of the last fetch (ETag, Last-Modified), so an unchanged feed
// costs one 304, and parsed in another isolate, since a long-running show's
// RSS runs to megabytes. RSS 2.0 with the iTunes and Podcasting 2.0
// namespaces, and Atom; anything else is an error the listener sees on the
// show. No widgets here.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:cancellation_token/cancellation_token.dart';
import 'package:xml/xml.dart';

import 'log.dart';

final _log = Logger('rss');

/// Who the player says it is to podcast hosts; some refuse Dart's default.
const userAgent = 'ListenJar/0.1 (+https://listenjar.com)';

const _fetchTimeout = Duration(seconds: 45);

/// A feed bigger than this is not a podcast feed.
const _maxFeedBytes = 64 << 20;

/// A show, as its feed describes it.
final class ParsedFeed {
  const ParsedFeed({
    required this.title,
    required this.author,
    required this.description,
    required this.artworkUrl,
    required this.link,
    required this.newFeedUrl,
    required this.episodes,
    this.serial = false,
  });
  final String title;
  final String author;
  final String description;
  final String? artworkUrl;
  final String? link;

  /// `itunes:new-feed-url`: the show moved, follow it from now on.
  final String? newFeedUrl;
  final List<ParsedEpisode> episodes;

  /// `itunes:type` serial: its episodes go in order of their numbers.
  final bool serial;
}

/// An episode, as its feed describes it. Items without audio are left out.
final class ParsedEpisode {
  const ParsedEpisode({
    required this.guid,
    required this.title,
    required this.description,
    required this.publishedAt,
    required this.duration,
    required this.audioUrl,
    required this.audioType,
    required this.audioBytes,
    required this.artworkUrl,
    required this.link,
    required this.season,
    required this.number,
  });
  final String guid;
  final String title;

  /// Show notes, often HTML.
  final String description;
  final DateTime? publishedAt;
  final Duration? duration;
  final String audioUrl;
  final String? audioType;
  final int? audioBytes;
  final String? artworkUrl;
  final String? link;
  final int? season;
  final int? number;
}

/// A fetch's answer: the feed, or that it hasn't changed since [etag] and
/// [lastModified] were given.
final class FeedFetch {
  const FeedFetch({required this.feed, required this.etag, required this.lastModified, required this.url});

  /// Null when the server said 304 Not Modified.
  final ParsedFeed? feed;
  final String? etag;
  final String? lastModified;

  /// Where the feed was found after redirects; a permanent redirect moves
  /// the subscription.
  final Uri url;
}

/// The feed is there but isn't one ListenJar can read.
final class NotAFeed implements Exception {
  const NotAFeed(this.reason);
  final String reason;
  @override
  String toString() => reason;
}

final class FeedStatus implements Exception {
  const FeedStatus(this.statusCode);
  final int statusCode;
  @override
  String toString() => switch (statusCode) {
    404 || 410 => 'The feed is gone (HTTP $statusCode)',
    401 || 403 => 'The feed refused ListenJar (HTTP $statusCode)',
    _ => 'The feed answered HTTP $statusCode',
  };
}

/// Fetches and parses [url]. Sends [etag] and [lastModified] from the last
/// fetch, if any, so an unchanged feed answers 304.
Future<FeedFetch> fetchFeed(
  HttpClient http,
  Uri url,
  CancellationToken token, {
  String? etag,
  String? lastModified,
}) => traced(
  _log,
  'feed $url',
  () => _fetchFeed(http, url, token, etag: etag, lastModified: lastModified),
  describe: (f) => switch (f.feed) {
    null => 'not modified',
    final feed => '${feed.episodes.length} episodes${f.url == url ? '' : ', moved to ${f.url}'}',
  },
);

Future<FeedFetch> _fetchFeed(
  HttpClient http,
  Uri url,
  CancellationToken token, {
  String? etag,
  String? lastModified,
}) async {
  var target = url;
  var permanent = url;
  // Follows redirects by hand, to learn which were permanent.
  for (var hop = 0; hop < 8; hop++) {
    final request = await http.getUrl(target).timeout(_fetchTimeout).asCancellable(token);
    request
      ..followRedirects = false
      ..headers.set(HttpHeaders.userAgentHeader, userAgent)
      ..headers.set(HttpHeaders.acceptHeader, 'application/rss+xml, application/atom+xml, application/xml;q=0.9, text/xml;q=0.8, */*;q=0.5');
    if (etag != null) request.headers.set(HttpHeaders.ifNoneMatchHeader, etag);
    if (lastModified != null) request.headers.set(HttpHeaders.ifModifiedSinceHeader, lastModified);
    final response = await request.close().timeout(_fetchTimeout).asCancellable(token);
    if (response.isRedirect) {
      await response.drain<void>();
      final location = response.headers.value(HttpHeaders.locationHeader);
      if (location == null) throw FeedStatus(response.statusCode);
      final next = target.resolve(location);
      if (response.statusCode == HttpStatus.movedPermanently || response.statusCode == HttpStatus.permanentRedirect) {
        if (permanent == target) permanent = next;
      }
      target = next;
      continue;
    }
    final newEtag = response.headers.value(HttpHeaders.etagHeader);
    final newModified = response.headers.value(HttpHeaders.lastModifiedHeader);
    if (response.statusCode == HttpStatus.notModified) {
      await response.drain<void>();
      return FeedFetch(feed: null, etag: newEtag ?? etag, lastModified: newModified ?? lastModified, url: permanent);
    }
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw FeedStatus(response.statusCode);
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(_fetchTimeout)) {
      token.throwIfCancelled();
      bytes.add(chunk);
      if (bytes.length > _maxFeedBytes) throw const NotAFeed('The feed is too big to be a podcast');
    }
    final body = bytes.takeBytes();
    final feed = await Isolate.run(() => parseFeed(body));
    return FeedFetch(feed: feed, etag: newEtag, lastModified: newModified, url: permanent);
  }
  throw const NotAFeed('The feed redirects too many times');
}

/// Parses RSS 2.0 or Atom from [bytes], honouring the encoding the XML
/// declares.
ParsedFeed parseFeed(List<int> bytes) {
  final head = latin1.decode(bytes.take(200).toList(), allowInvalid: true);
  final declared = RegExp(r'''encoding=["']([\w-]+)["']''').firstMatch(head)?.group(1)?.toLowerCase();
  final text = switch (declared) {
    'iso-8859-1' || 'latin1' || 'windows-1252' => latin1.decode(bytes, allowInvalid: true),
    _ => utf8.decode(bytes, allowMalformed: true),
  };
  final XmlDocument document;
  try {
    document = XmlDocument.parse(text.startsWith('﻿') ? text.substring(1) : text);
  } on XmlException catch (e) {
    throw NotAFeed('That isn’t a podcast feed (${e.message})');
  }
  final root = document.rootElement;
  return switch (root.localName) {
    'rss' || 'RDF' => _rss(root),
    'feed' => _atom(root),
    'html' => throw const NotAFeed('That’s a web page, not a podcast feed'),
    _ => throw NotAFeed('That isn’t a podcast feed (<${root.localName}>)'),
  };
}

ParsedFeed _rss(XmlElement root) {
  final channel = _child(root, 'channel');
  if (channel == null) throw const NotAFeed('The feed has no channel');
  final rssImage = channel.childElements.where((e) => e.localName == 'image' && e.getAttribute('href') == null).firstOrNull;
  final channelArt = _itunesImage(channel) ?? _text(_child(rssImage, 'url'));
  final items = root.localName == 'RDF' ? root.childElements.where((e) => e.localName == 'item') : channel.childElements.where((e) => e.localName == 'item');
  final episodes = <ParsedEpisode>[];
  final seen = <String>{};
  for (final item in items) {
    final enclosure = _audio(item);
    if (enclosure == null) continue;
    final (url, type, length) = enclosure;
    final link = _text(_child(item, 'link'));
    final title = _text(_child(item, 'title')) ?? '';
    final published = _date(_text(_child(item, 'pubDate')) ?? _text(_child(item, 'date')));
    final guid = _text(_child(item, 'guid')) ?? url;
    if (!seen.add(guid)) continue;
    episodes.add(ParsedEpisode(
      guid: guid,
      title: title.isEmpty ? 'Untitled episode' : title,
      description: _text(_child(item, 'encoded')) ?? _text(_child(item, 'description')) ?? _text(_child(item, 'summary')) ?? '',
      publishedAt: published,
      duration: _duration(_text(_child(item, 'duration'))),
      audioUrl: url,
      audioType: type,
      audioBytes: length,
      artworkUrl: _itunesImage(item),
      link: link,
      season: int.tryParse(_text(_child(item, 'season')) ?? ''),
      number: int.tryParse(_text(_child(item, 'episode')) ?? ''),
    ));
  }
  return ParsedFeed(
    title: _text(_child(channel, 'title')) ?? 'Untitled podcast',
    author: _text(_child(channel, 'author')) ?? _text(_child(_child(channel, 'owner'), 'name')) ?? '',
    description: _text(_child(channel, 'summary')) ?? _text(_child(channel, 'description')) ?? '',
    artworkUrl: channelArt,
    link: _text(channel.childElements.where((e) => e.localName == 'link' && e.namespaceUri == null).firstOrNull),
    newFeedUrl: _text(_child(channel, 'new-feed-url')),
    episodes: episodes,
    serial: _text(_child(channel, 'type'))?.toLowerCase() == 'serial',
  );
}

ParsedFeed _atom(XmlElement feed) {
  final episodes = <ParsedEpisode>[];
  for (final entry in feed.childElements.where((e) => e.localName == 'entry')) {
    final links = entry.childElements.where((e) => e.localName == 'link').toList();
    final audio = links.where((l) => l.getAttribute('rel') == 'enclosure').firstOrNull;
    final href = audio?.getAttribute('href');
    if (href == null) continue;
    final page = links.where((l) => (l.getAttribute('rel') ?? 'alternate') == 'alternate').firstOrNull?.getAttribute('href');
    episodes.add(ParsedEpisode(
      guid: _text(_child(entry, 'id')) ?? href,
      title: _text(_child(entry, 'title')) ?? 'Untitled episode',
      description: _text(_child(entry, 'content')) ?? _text(_child(entry, 'summary')) ?? '',
      publishedAt: DateTime.tryParse(_text(_child(entry, 'published')) ?? _text(_child(entry, 'updated')) ?? ''),
      duration: _duration(_text(_child(entry, 'duration'))),
      audioUrl: href,
      audioType: audio?.getAttribute('type'),
      audioBytes: int.tryParse(audio?.getAttribute('length') ?? ''),
      artworkUrl: _itunesImage(entry),
      link: page,
      season: null,
      number: null,
    ));
  }
  final author = _text(_child(_child(feed, 'author'), 'name')) ?? '';
  return ParsedFeed(
    title: _text(_child(feed, 'title')) ?? 'Untitled podcast',
    author: author,
    description: _text(_child(feed, 'subtitle')) ?? '',
    artworkUrl: _itunesImage(feed) ?? _text(_child(feed, 'logo')) ?? _text(_child(feed, 'icon')),
    link: feed.childElements
      .where((e) => e.localName == 'link' && (e.getAttribute('rel') ?? 'alternate') == 'alternate')
      .firstOrNull
      ?.getAttribute('href'),
    newFeedUrl: null,
    episodes: episodes,
  );
}

/// The first child named [name] in any namespace.
XmlElement? _child(XmlElement? parent, String name) =>
  parent?.childElements.where((e) => e.localName == name).firstOrNull;

String? _text(XmlElement? element) {
  final value = element?.innerText.trim();
  return value == null || value.isEmpty ? null : value;
}

String? _itunesImage(XmlElement parent) {
  for (final (name, attribute) in const [('image', 'href'), ('thumbnail', 'url')]) {
    for (final e in parent.childElements) {
      if (e.localName != name) continue;
      if (e.getAttribute(attribute)?.trim() case final url? when url.isNotEmpty) return url;
    }
  }
  return null;
}

/// The item's audio: its enclosure, else an audio `media:content`.
(String, String?, int?)? _audio(XmlElement item) {
  for (final e in item.childElements) {
    if (e.localName != 'enclosure') continue;
    final url = e.getAttribute('url')?.trim();
    if (url == null || url.isEmpty) continue;
    final type = e.getAttribute('type');
    if (type != null && !(type.startsWith('audio/') || type.startsWith('video/') || type == 'application/octet-stream')) continue;
    return (url, type, int.tryParse(e.getAttribute('length') ?? ''));
  }
  for (final e in item.descendantElements) {
    if (e.localName != 'content') continue;
    final url = e.getAttribute('url');
    final type = e.getAttribute('type') ?? '';
    if (url != null && (type.startsWith('audio/') || e.getAttribute('medium') == 'audio')) {
      return (url, type.isEmpty ? null : type, int.tryParse(e.getAttribute('fileSize') ?? ''));
    }
  }
  return null;
}

/// `itunes:duration`: `H:MM:SS`, `MM:SS` or seconds.
Duration? _duration(String? value) {
  if (value == null) return null;
  final parts = value.split(':').map((p) => double.tryParse(p.trim())).toList();
  if (parts.isEmpty || parts.length > 3 || parts.any((p) => p == null || p < 0)) return null;
  var seconds = 0.0;
  for (final p in parts) {
    seconds = seconds * 60 + p!;
  }
  return seconds > 0 ? Duration(milliseconds: (seconds * 1000).round()) : null;
}

const _months = {
  'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6,
  'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12,
};

const _zones = {
  'ut': 0, 'utc': 0, 'gmt': 0, 'z': 0,
  'est': -5, 'edt': -4, 'cst': -6, 'cdt': -5, 'mst': -7, 'mdt': -6, 'pst': -8, 'pdt': -7,
};

final _rfc822 = RegExp(
  r'^(?:\w+,?\s+)?(\d{1,2})\s+(\w{3})\w*\.?\s+(\d{2,4})(?:\s+(\d{1,2}):(\d{2})(?::(\d{2}))?)?\s*([+-]\d{4}|\w+)?',
);

/// RFC 822 dates as feeds actually write them, else ISO 8601.
DateTime? _date(String? value) {
  if (value == null) return null;
  final m = _rfc822.firstMatch(value.trim());
  if (m == null) return DateTime.tryParse(value.trim())?.toUtc();
  final month = _months[m.group(2)!.toLowerCase()];
  if (month == null) return null;
  var year = int.parse(m.group(3)!);
  if (year < 100) year += year < 70 ? 2000 : 1900;
  var at = DateTime.utc(
    year,
    month,
    int.parse(m.group(1)!),
    int.tryParse(m.group(4) ?? '') ?? 0,
    int.tryParse(m.group(5) ?? '') ?? 0,
    int.tryParse(m.group(6) ?? '') ?? 0,
  );
  final zone = m.group(7);
  if (zone != null) {
    if (zone.startsWith('+') || zone.startsWith('-')) {
      final sign = zone.startsWith('-') ? -1 : 1;
      final minutes = int.parse(zone.substring(1, 3)) * 60 + int.parse(zone.substring(3, 5));
      at = at.subtract(Duration(minutes: sign * minutes));
    } else if (_zones[zone.toLowerCase()] case final hours?) {
      at = at.subtract(Duration(hours: hours));
    }
  }
  return at;
}
