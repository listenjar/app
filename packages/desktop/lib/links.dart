// Recognises the YouTube links ListenJar takes, as the website does
// (apps/web/src/lib/youtube.ts in the listenjar monorepo): a video, a playlist
// or a channel, rewritten to its canonical https form.
import 'backend/api.dart' show SourceKind;

final class YouTubeLink {
  const YouTubeLink(this.kind, this.id, this.url);
  final SourceKind kind;

  /// Video id, playlist id, channel id, or `@handle`.
  final String id;

  /// The canonical link. A channel by handle or name is canonical only once
  /// YouTube resolves it to `/channel/UC…`.
  final String url;
}

const _hosts = {'youtube.com', 'www.youtube.com', 'm.youtube.com', 'music.youtube.com', 'youtu.be'};
final _videoId = RegExp(r'^[\w-]{11}$');
final _listId = RegExp(r'^[\w-]{10,}$');

YouTubeLink? parseYouTubeLink(String input) {
  final text = input.trim();
  if (text.isEmpty) return null;
  final url = Uri.tryParse(RegExp(r'^https?://', caseSensitive: false).hasMatch(text) ? text : 'https://$text');
  if (url == null || !_hosts.contains(url.host.toLowerCase())) return null;

  final parts = url.pathSegments.where((p) => p.isNotEmpty).toList();
  final first = parts.elementAtOrNull(0) ?? '';
  final second = parts.elementAtOrNull(1) ?? '';

  if (url.host.toLowerCase() == 'youtu.be') return _videoId.hasMatch(first) ? _video(first) : null;
  if (first == 'playlist') {
    final list = url.queryParameters['list'] ?? '';
    return _listId.hasMatch(list)
      ? YouTubeLink(SourceKind.playlist, list, 'https://www.youtube.com/playlist?list=$list')
      : null;
  }
  if (first == 'watch') {
    final v = url.queryParameters['v'] ?? '';
    return _videoId.hasMatch(v) ? _video(v) : null;
  }
  if (const {'shorts', 'live', 'embed', 'v'}.contains(first)) return _videoId.hasMatch(second) ? _video(second) : null;
  if (first.startsWith('@') && first.length > 1) {
    return YouTubeLink(SourceKind.channel, first, 'https://www.youtube.com/${Uri.encodeComponent(first)}');
  }
  if (const {'channel', 'c', 'user'}.contains(first) && second.isNotEmpty) {
    return YouTubeLink(SourceKind.channel, second, 'https://www.youtube.com/$first/${Uri.encodeComponent(second)}');
  }
  return null;
}

YouTubeLink _video(String id) => YouTubeLink(SourceKind.video, id, 'https://www.youtube.com/watch?v=$id');

String kindLabel(SourceKind kind) => switch (kind) {
  SourceKind.video => 'YouTube video',
  SourceKind.playlist => 'YouTube playlist',
  SourceKind.channel => 'YouTube channel',
};

/// An Apple Podcasts link: a show, and the episode when it names one
/// (`podcasts.apple.com/us/podcast/name/id1200361736?i=1000803767035`).
final class ApplePodcastsLink {
  const ApplePodcastsLink(this.showId, this.episodeId);

  /// Apple's id for the show, its `collectionId`.
  final String showId;

  /// Apple's id for the episode, its `trackId`.
  final String? episodeId;
}

const _appleHosts = {'podcasts.apple.com', 'itunes.apple.com'};

ApplePodcastsLink? parseApplePodcastsLink(String input) {
  final text = input.trim();
  final url = Uri.tryParse(RegExp(r'^https?://', caseSensitive: false).hasMatch(text) ? text : 'https://$text');
  if (url == null || !_appleHosts.contains(url.host.toLowerCase())) return null;
  final show = url.pathSegments.map(RegExp(r'^id(\d+)$').firstMatch).nonNulls.lastOrNull?.group(1);
  if (show == null) return null;
  final episode = url.queryParameters['i'];
  return ApplePodcastsLink(show, episode != null && RegExp(r'^\d+$').hasMatch(episode) ? episode : null);
}
