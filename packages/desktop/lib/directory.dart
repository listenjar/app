// Finding podcasts: Apple's podcast directory, the one AntennaPod and most
// open-source players search by default. Free, keyless and the biggest
// catalogue; the app asks it straight from the device, so search terms go
// to Apple and nowhere else. Its charts fill the search page before anyone
// types. No widgets here.
import 'dart:convert';
import 'dart:io';

import 'package:cancellation_token/cancellation_token.dart';

import 'links.dart' show ApplePodcastsLink, canonicalSourceUrl;
import 'rss.dart' show userAgent;

const _timeout = Duration(seconds: 20);

/// Apple's copy of an episode's artwork, with what tells which episode it
/// is: its guid, else its audio's URL.
typedef AppleEpisodeArt = ({String? guid, String? audioUrl, String artworkUrl});

/// A show the directory knows.
final class DirectoryPodcast {
  const DirectoryPodcast({
    required this.title,
    required this.author,
    required this.feedUrl,
    required this.artworkUrl,
    required this.genre,
    required this.episodeCount,
  });
  final String title;
  final String author;
  final String feedUrl;
  final String? artworkUrl;
  final String? genre;
  final int? episodeCount;
}

final class PodcastDirectory {
  PodcastDirectory();

  final _http = HttpClient()
    ..connectionTimeout = _timeout
    ..userAgent = userAgent;

  /// The storefront the charts and search answer for: the device's region.
  String get _country {
    final locale = Platform.localeName; // en_US, en-GB, de_DE.UTF-8
    final match = RegExp(r'[_-]([A-Za-z]{2})\b').firstMatch(locale);
    return (match?.group(1) ?? 'us').toLowerCase();
  }

  List<DirectoryPodcast>? _charts;

  /// Shows whose names or makers match [query].
  Future<List<DirectoryPodcast>> search(String query, CancellationToken token) async {
    final json = await _get(
      Uri.https('itunes.apple.com', '/search', {
        'media': 'podcast',
        'entity': 'podcast',
        'limit': '40',
        'country': _country,
        'term': query,
      }),
      token,
    );
    return _results(json);
  }

  /// The region's top shows, asked once per launch.
  Future<List<DirectoryPodcast>> charts(CancellationToken token) async {
    if (_charts case final charts?) return charts;
    final top = await _get(Uri.parse('https://rss.marketingtools.apple.com/api/v2/$_country/podcasts/top/50/podcasts.json'), token);
    final ids = [
      for (final r in ((top['feed'] as Map?)?['results'] as List?) ?? const [])
        if ((r as Map)['id'] case final String id) id,
    ];
    if (ids.isEmpty) return const [];
    final found = _results(await _get(Uri.https('itunes.apple.com', '/lookup', {'id': ids.join(','), 'entity': 'podcast', 'country': _country}), token));
    // Lookup answers in its own order; the chart's is the point.
    final rank = {for (final (i, id) in ids.indexed) id: i};
    found.sort((a, b) => (rank[a._id] ?? 999).compareTo(rank[b._id] ?? 999));
    return _charts = found;
  }

  /// The feed behind an Apple Podcasts [link], and the episode's guid in it
  /// when the link names one Apple still lists among the show's latest 200.
  /// Null when Apple shares no feed for the show: one it hosts itself, or
  /// gone from the directory.
  Future<({String feedUrl, String? episodeGuid})?> applePodcast(ApplePodcastsLink link, CancellationToken token) async {
    final json = await _get(
      Uri.https('itunes.apple.com', '/lookup', {
        'id': link.showId,
        if (link.episodeId != null) ...{'entity': 'podcastEpisode', 'limit': '200'},
      }),
      token,
    );
    final results = (json['results'] as List?)?.cast<Map<String, Object?>>() ?? const [];
    final feed = results.map((r) => r['feedUrl']).whereType<String>().where((f) => f.isNotEmpty).firstOrNull;
    if (feed == null) return null;
    final episode = results.where((r) => '${r['trackId']}' == link.episodeId).firstOrNull;
    return (feedUrl: feed, episodeGuid: episode?['episodeGuid'] as String?);
  }

  /// Apple's id for the show whose feed is at [feedUrl], found by searching
  /// for its [title] in the device's storefront, then the US one. Null when
  /// Apple lists no show at that feed.
  Future<int?> appleId(String title, String feedUrl, CancellationToken token) async {
    final want = canonicalSourceUrl(feedUrl);
    for (final country in {_country, 'us'}) {
      final json = await _get(
        Uri.https('itunes.apple.com', '/search', {'media': 'podcast', 'entity': 'podcast', 'limit': '50', 'country': country, 'term': title}),
        token,
      );
      for (final r in (json['results'] as List?) ?? const []) {
        if (r case {'feedUrl': final String feed, 'collectionId': final int id} when canonicalSourceUrl(feed) == want) return id;
      }
    }
    return null;
  }

  /// Apple's copies of the artwork of the latest 200 episodes of the show
  /// Apple knows as [appleId]: each episode's own picture where it has one,
  /// else the show's, served from Apple's image servers at 600 px.
  Future<List<AppleEpisodeArt>> episodeArtwork(int appleId, CancellationToken token) async {
    final json = await _get(
      Uri.https('itunes.apple.com', '/lookup', {'id': '$appleId', 'entity': 'podcastEpisode', 'limit': '200', 'country': _country}),
      token,
    );
    return [
      for (final r in (json['results'] as List?) ?? const [])
        if (r case {'wrapperType': 'podcastEpisode'})
          if (r['artworkUrl600'] ?? r['artworkUrl160'] case final String art when art.isNotEmpty)
            (guid: r['episodeGuid'] as String?, audioUrl: r['episodeUrl'] as String?, artworkUrl: art),
    ];
  }

  Future<Map<String, Object?>> _get(Uri url, CancellationToken token) async {
    final request = await _http.getUrl(url).timeout(_timeout).asCancellable(token);
    final response = await request.close().timeout(_timeout).asCancellable(token);
    final body = await response.transform(utf8.decoder).join().timeout(_timeout).asCancellable(token);
    if (response.statusCode != HttpStatus.ok) throw HttpException('Apple’s podcast directory answered HTTP ${response.statusCode}', uri: url);
    return jsonDecode(body) as Map<String, Object?>;
  }

  List<_Found> _results(Map<String, Object?> json) => [
    for (final r in (json['results'] as List?) ?? const [])
      if (r case {'feedUrl': final String feed, 'collectionName': final String title} when feed.isNotEmpty)
        _Found(
          '${r['collectionId']}',
          title: title,
          author: r['artistName'] as String? ?? '',
          feedUrl: feed,
          artworkUrl: r['artworkUrl600'] as String? ?? r['artworkUrl100'] as String?,
          genre: r['primaryGenreName'] as String?,
          episodeCount: r['trackCount'] as int?,
        ),
  ];

  void close() => _http.close(force: true);
}

final class _Found extends DirectoryPodcast {
  const _Found(
    this._id, {
    required super.title,
    required super.author,
    required super.feedUrl,
    required super.artworkUrl,
    required super.genre,
    required super.episodeCount,
  });
  final String _id;
}
