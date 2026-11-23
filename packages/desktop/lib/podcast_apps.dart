// Opening a feed in the listener's podcast app: each app's subscribe link,
// per platform, as listenbox.app's podcast pages do (remix
// app/ui/podcast/PodcastApps.ts). Being an app, this one can also ask the OS
// which of them are installed, and offers only those, plus Player FM's web
// subscribe page and copying the link everywhere.
//
// Apps still maintained in 2026 only: Downcast, Podkicker and gpodder.net
// from that list are gone or unmaintained.
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

final class PodcastApp {
  const PodcastApp(this.title, this._icon, this._scheme, {this.fullUrl = false, this.web = false});
  final String title;
  final String _icon;
  final String _scheme;

  /// Its icon, from assets/podcast_apps (tool/icons.py renders them).
  String get icon => podcastAppIcon(_icon);

  /// The link opens the app but not the feed: the listener pastes it.
  /// Podcasts on macOS answers `podcast://` with an empty "Follow a show by
  /// URL" box; Apple documents only File > Follow a Show by URL.
  bool get pastesFeed => identical(this, _applePodcasts) && defaultTargetPlatform == TargetPlatform.macOS;

  /// The scheme takes the whole feed URL as a query value; otherwise it
  /// takes the URL without `https://`.
  final bool fullUrl;

  /// A web page, always there, rather than an installed app.
  final bool web;

  Uri link(String feedUrl) => Uri.parse(
    fullUrl ? '$_scheme${Uri.encodeComponent(feedUrl)}' : '$_scheme${feedUrl.replaceFirst(RegExp('^https?://'), '')}',
  );
}

const _applePodcasts = PodcastApp('Apple Podcasts', 'apple_podcasts', 'podcast://');
const _pocketCasts = PodcastApp('Pocket Casts', 'pocket_casts', 'pktc://subscribe/');
const _overcast = PodcastApp('Overcast', 'overcast', 'overcast://x-callback-url/add?url=', fullUrl: true);
const _castro = PodcastApp('Castro', 'castro', 'castro://subscribe/');
const _antennaPod = PodcastApp('AntennaPod', 'antennapod', 'antennapod-subscribe://');
const _podcastAddict = PodcastApp('Podcast Addict', 'podcast_addict', 'podcastaddict://');
const _podcastRepublic = PodcastApp('Podcast Republic', 'podcast_republic', 'podcastrepublic://subscribe/');
const _playerFm = PodcastApp('Player FM', 'player_fm', 'https://player.fm/subscribe?id=', fullUrl: true, web: true);

/// The asset of a podcast app's icon, or `rss` for a plain feed link.
String podcastAppIcon(String name) => 'assets/podcast_apps/$name.png';

/// The apps worth trying on [platform], most popular first.
List<PodcastApp> _candidates(TargetPlatform platform) => switch (platform) {
  TargetPlatform.iOS => const [_applePodcasts, _overcast, _pocketCasts, _castro, _playerFm],
  // Overcast and Castro run on Apple silicon Macs as iPad apps.
  TargetPlatform.macOS => const [_applePodcasts, _pocketCasts, _overcast, _castro, _playerFm],
  TargetPlatform.android => const [
    _pocketCasts,
    _podcastAddict,
    _antennaPod,
    _podcastRepublic,
    _playerFm,
  ],
  TargetPlatform.windows || TargetPlatform.linux || TargetPlatform.fuchsia => const [_pocketCasts, _playerFm],
};

/// The podcast apps this device can open, in order; web pages always count.
Future<List<PodcastApp>> installedPodcastApps() async {
  const probe = 'https://rss.listenjar.com/probe.xml';
  final apps = <PodcastApp>[];
  for (final app in _candidates(defaultTargetPlatform)) {
    if (app.web) {
      apps.add(app);
      continue;
    }
    try {
      if (await canLaunchUrl(app.link(probe))) apps.add(app);
    } catch (_) {
      // The platform can't tell: leave it out.
    }
  }
  return apps;
}

const _toast = MethodChannel('listenjar/toast');

/// Opens [feedUrl] in [app]: the app itself, or its page in the browser.
/// When the app only opens its "Follow a show by URL" box, the link goes on
/// the clipboard first, and a toast over that box (macos/Runner) says to
/// paste it.
Future<bool> openInPodcastApp(PodcastApp app, String feedUrl) async {
  if (app.pastesFeed) {
    await Clipboard.setData(ClipboardData(text: feedUrl));
    try {
      await _toast.invokeMethod<void>('pasteHint', {
        'title': 'Feed link copied',
        'message': 'Paste it into the box below, then click Follow.',
        'key': '⌘V',
        'app': 'com.apple.podcasts',
      });
    } on MissingPluginException {
      // An older build without the toast: the link is still copied.
    }
  }
  return launchUrl(app.link(feedUrl), mode: LaunchMode.externalApplication);
}
