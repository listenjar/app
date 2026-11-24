// ListenJar: a podcast player first, free and without an account (the
// library, refresh, downloads and playback: library.dart, podcasts.dart,
// downloads.dart, player.dart), and ListenJar Cloud beside it for listeners
// who sign in (cloud.dart: their YouTube feeds, synced from this device by
// feeds.dart and sync.dart). Their own feeds play here like any podcast.
// The window is shell.dart. Everything below lives for the process: the
// window, the tray (tray.dart) and the schedule (schedule.dart) share it.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import 'account.dart';
import 'directory.dart';
import 'downloads.dart';
import 'feeds.dart';
import 'library.dart';
import 'log.dart';
import 'player.dart';
import 'podcasts.dart';
import 'schedule.dart';
import 'shared_links.dart' show IncomingLinks;
import 'shell.dart';
import 'theme.dart' as brand;
import 'tray.dart';
import 'ui.dart';
import 'youtube.dart';

/// [arguments] carry a link on Linux and Windows when one opened the app
/// (shared_links.dart).
Future<void> main([List<String> arguments = const []]) async {
  AppServices? services;
  IncomingLinks? links;
  startLogging(state: () => appState(services, links));
  WidgetsFlutterBinding.ensureInitialized();
  links = IncomingLinks(arguments);
  // The YouTube session starts now, so the first search doesn't wait for it.
  final youtube = YouTubeService()..warmUp();
  final account = Account();
  final feeds = Feeds(account, youtube);
  unawaited(account.restore());
  final library = await Library.open();
  final downloads = Downloads(library, youtube);
  final podcasts = Podcasts(library, downloads, youtube);
  final player = await Player.start(library, youtube, downloads);
  unawaited(downloads.start());
  CloudShows(account, feeds, podcasts);
  Tray.start(account, feeds);
  unawaited(SyncSchedule().start(feeds, podcasts));
  unawaited(podcasts.refreshAll());
  services = (
    youtube: youtube,
    account: account,
    feeds: feeds,
    library: library,
    podcasts: podcasts,
    player: player,
    downloads: downloads,
    directory: PodcastDirectory(),
  );
  runApp(App(links: links, services: services));
}

/// What the app is doing, for `ext.listenjar.state` (log.dart). Nothing
/// personal: no email, no names.
Map<String, Object?> appState(AppServices? s, IncomingLinks? links) {
  if (s == null) return {'starting': true};
  final player = s.player;
  final episode = player.current;
  final library = s.library;
  return {
    'account': switch (s.account.user) {
      null => 'signed out',
      final user => {'plan': user.plan, 'feeds': s.feeds.feeds.length},
    },
    'player': {
      'episode': episode == null ? null : {'id': episode.id, 'title': episode.title, 'show': episode.from, 'audio': episode.audioUrl},
      'playing': player.playing,
      'loading': player.loading,
      'position': '${player.position}',
      'duration': '${player.duration}',
      'speed': player.speed,
      'sleep': player.sleep?.toString(),
      'problem': player.problem,
      'error': player.error?.toString(),
    },
    'upNext': [for (final e in library.queue) e.title],
    'following': library.podcasts.where((p) => p.followed).length,
    'downloads': [
      for (final e in library.downloads())
        {'title': e.title, 'state': e.downloadState.name, if (e.downloadState == DownloadState.downloading) 'progress': e.downloadProgress},
    ],
    'linksWaiting': [for (final link in links?.waiting ?? const <Uri>[]) '$link'],
  };
}

typedef AppServices = ({
  YouTubeService youtube,
  Account account,
  Feeds feeds,
  Library library,
  Podcasts podcasts,
  Player player,
  Downloads downloads,
  PodcastDirectory directory,
});

class App extends StatefulWidget {
  const App({super.key, required this.services, required this.links});
  final AppServices services;
  final IncomingLinks links;

  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> {
  final _navigation = Navigation();

  @override
  Widget build(BuildContext context) {
    final s = widget.services;
    return Services(
      youtube: s.youtube,
      account: s.account,
      feeds: s.feeds,
      library: s.library,
      podcasts: s.podcasts,
      player: s.player,
      downloads: s.downloads,
      directory: s.directory,
      child: NavigationScope(
        navigation: _navigation,
        child: MaterialApp(
          title: 'ListenJar',
          debugShowCheckedModeBanner: false,
          builder: (context, child) => kDebugMode
            ? Banner(message: 'DEBUG', location: BannerLocation.topEnd, child: child!)
            : child!,
          // Light only, like listenjar.com: paper is the ground (DESIGN.md).
          theme: brand.theme(),
          home: Shell(links: widget.links),
        ),
      ),
    );
  }
}

/// Keeps the signed-in listener's ListenJar feeds in the library, so they
/// play here like any podcast, and refreshes one as soon as it publishes.
final class CloudShows {
  CloudShows(this._account, this._feeds, this._podcasts) {
    _feeds.addListener(_changed);
  }

  final Account _account;
  final Feeds _feeds;
  final Podcasts _podcasts;

  /// Each feed's RSS address and episode count as last seen.
  Map<String, (String?, int?)> _seen = const {};
  bool _wasLoading = false;
  bool _loaded = false;

  void _changed() {
    if (_account.user == null) {
      _seen = const {};
      _loaded = false;
      return;
    }
    if (_wasLoading && !_feeds.loading && _feeds.feedsError == null) _loaded = true;
    _wasLoading = _feeds.loading;
    // Until the list has loaded, an empty one says nothing.
    if (!_loaded && _feeds.feeds.isEmpty) return;
    final now = {for (final f in _feeds.feeds) f.id: (f.rssUrl, f.episodeCount)};
    if (mapEquals(now, _seen)) return;
    final before = _seen;
    _seen = now;
    unawaited(_podcasts.followCloud(_feeds.feeds).then((_) async {
      for (final MapEntry(key: id, value: (_, count)) in now.entries) {
        final was = before[id];
        if (was != null && was.$2 != count) await _podcasts.cloudPublished(id);
      }
    }));
  }
}
