// ListenJar: a podcast player first, free and without an account (the
// library, refresh, downloads and playback: library.dart, podcasts.dart,
// downloads.dart, player.dart), and ListenJar Cloud beside it for listeners
// who sign in (cloud.dart: their YouTube feeds, synced from this device by
// feeds.dart and sync.dart). Their own feeds play here like any podcast.
// The window is shell.dart. Everything below lives for the process: the
// window, the tray (tray.dart) and the schedule (schedule.dart) share it.
import 'dart:async';

import 'package:cancellation_token/cancellation_token.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

import 'account.dart';
import 'backend/api.dart' show Plan;
import 'cloud.dart' show feedToDevice, ownToCloud, ownToDevice, showToCloud;
import 'directory.dart';
import 'downloads.dart';
import 'feeds.dart';
import 'library.dart';
import 'links.dart' show parseYouTubeLink;
import 'log.dart';
import 'player.dart';
import 'podcasts.dart';
import 'schedule.dart';
import 'shared_links.dart' show IncomingLinks;
import 'shell.dart';
import 'theme.dart' as brand;
import 'tray.dart';
import 'ui.dart';
import 'updates.dart';
import 'youtube.dart';

/// [arguments] carry a link on Linux and Windows when one opened the app
/// (shared_links.dart).
Future<void> main([List<String> arguments = const []]) async {
  AppServices? services;
  IncomingLinks? links;
  startLogging(state: () => appState(services, links), control: (parameters) => control(services, parameters));
  WidgetsFlutterBinding.ensureInitialized();
  links = IncomingLinks(arguments);
  // The YouTube session starts now, so the first search doesn't wait for it.
  final youtube = YouTubeService()..warmUp();
  final account = Account();
  final feeds = Feeds(account, youtube);
  unawaited(account.restore());
  final library = await Library.open();
  final downloads = Downloads(library, youtube);
  final podcasts = Podcasts(library, downloads, youtube)..paid = () => account.restoring ? null : account.user?.plan == Plan.paid;
  var wasPaid = podcasts.paid();
  account.addListener(() {
    if (podcasts.paid() == wasPaid) return;
    wasPaid = podcasts.paid();
    podcasts.planChanged();
  });
  final player = await Player.start(library, youtube, downloads);
  unawaited(downloads.start());
  CloudShows(account, feeds, podcasts);
  Tray.start(account, feeds);
  unawaited(SyncSchedule().start(feeds, podcasts));
  unawaited(podcasts.refreshAll());
  unawaited(startUpdates());
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
      final user => {
        'plan': user.plan,
        'cloud': user.storageLimitBytes != null,
        'feeds': [
          for (final f in s.feeds.feeds)
            {'id': f.id, 'kind': f.source?.kind.name ?? 'own', 'sync': s.feeds.statusOf(f)?.phase.name, 'show': s.library.podcasts.where((p) => p.cloudFeedId == f.id).firstOrNull?.id},
        ],
      },
    },
    'player': {
      'episode': episode == null ? null : {'id': episode.id, 'title': episode.title, 'show': episode.from, 'audio': episode.audioUrl, 'artwork': episode.artwork, 'cover': episode.cover},
      'playing': player.playing,
      'loading': player.loading,
      'position': '${player.position}',
      'duration': '${player.duration}',
      'speed': player.speed,
      'sleep': player.sleep?.toString(),
      'problem': player.problem,
      'error': player.error?.toString(),
      'chapters': [for (final c in player.chapters) '${c.start} ${c.title}'],
    },
    'upNext': [for (final e in library.queue) e.title],
    'following': [
      for (final p in library.podcasts.where((p) => p.followed))
        {'id': p.id, 'kind': p.kind.name, 'episodes': library.episodes(p.id).length, if (p.refreshError != null) 'error': p.refreshError},
    ],
    'downloads': [
      for (final e in library.downloads())
        {'title': e.title, 'state': e.downloadState.name, if (e.downloadState == DownloadState.downloading) 'progress': e.downloadProgress},
    ],
    'linksWaiting': [for (final link in links?.waiting ?? const <Uri>[]) '$link'],
    'updates': updatesState(),
  };
}

/// `ext.listenjar.control` (log.dart): drives the player for whoever
/// debugs it. The command starts; the answer is the state at that moment.
void control(AppServices? s, Map<String, String> parameters) {
  if (s == null) throw StateError('starting');
  final player = s.player;
  switch (parameters['action']) {
    case 'play':
      final id = int.tryParse(parameters['episode'] ?? '');
      final episode = id == null ? null : s.library.episode(id);
      unawaited(episode == null ? player.play() : player.playEpisode(episode));
    case 'pause':
      unawaited(player.pause());
    case 'stop':
      unawaited(player.stop());
    case 'seek':
      unawaited(player.seek(Duration(milliseconds: ((double.tryParse(parameters['seconds'] ?? '') ?? 0) * 1000).round())));
    case 'refresh':
      unawaited(s.podcasts.refreshAll(force: true));
    case 'add':
      // A YouTube video (`url`) into a podcast of the listener's own:
      // `into` a Cloud feed id or `local:<show id>`; their first in the
      // Cloud if not given.
      final url = parameters['url'] ?? '';
      switch (parameters['into']) {
        case final into? when into.startsWith('local:'):
          final show = s.library.podcast(int.parse(into.substring(6))) ?? (throw ArgumentError('no show $into'));
          final link = parseYouTubeLink(url) ?? (throw ArgumentError('not a YouTube link'));
          unawaited(s.podcasts.addToOwn(show, link, CancellationToken()));
        case final into:
          final feed = (into == null ? s.feeds.own.firstOrNull : s.feeds.feeds.where((f) => f.id == into).firstOrNull)
            ?? (throw StateError('no podcast of your own ${into ?? ''}'));
          unawaited(s.feeds.addVideo(feed, url, CancellationToken()));
      }
    case 'create':
      // A podcast of the listener's own called `title`, in the Cloud if
      // `cloud` is true, else on this device.
      final title = parameters['title'] ?? (throw ArgumentError('title?'));
      if (parameters['cloud'] == 'true') {
        unawaited(s.feeds.create(title));
      } else {
        s.library.createOwn(title);
      }
    case 'rss':
      // A podcast's RSS feed (`url`), followed as the directory does.
      final url = Uri.tryParse(parameters['url'] ?? '') ?? (throw ArgumentError('url?'));
      unawaited(s.podcasts.follow(url, CancellationToken()));
    case 'follow':
      // A YouTube playlist or channel (`url`) on this device, streaming.
      final link = parseYouTubeLink(parameters['url'] ?? '') ?? (throw ArgumentError('not a YouTube link'));
      unawaited(s.podcasts.followYouTube(link, CancellationToken()));
    case 'unfollow':
      final show = s.library.podcast(int.tryParse(parameters['show'] ?? '') ?? -1) ?? (throw ArgumentError('no show ${parameters['show']}'));
      unawaited(s.podcasts.unfollow(show));
    case 'move':
      // A YouTube playlist or channel, or a podcast of the listener's own,
      // between this device (`show`) and ListenJar Cloud (`feed`), as the
      // show's and the feed's menus do.
      switch (parameters) {
        case {'show': final id}:
          final show = s.library.podcast(int.parse(id)) ?? (throw ArgumentError('no show $id'));
          unawaited(show.isOwn ? ownToCloud(s.feeds, s.podcasts, show) : showToCloud(s.feeds, s.podcasts, show));
        case {'feed': final id}:
          final feed = s.feeds.feeds.where((f) => f.id == id).firstOrNull ?? (throw ArgumentError('no feed $id'));
          unawaited(feed.source == null ? ownToDevice(s.feeds, s.podcasts, feed) : feedToDevice(s.feeds, s.podcasts, feed));
        default:
          throw ArgumentError('move what? show or feed');
      }
    case 'open':
      // A ListenJar `feed` (an id), a `show` (an id), `settings`,
      // `nowPlaying` or `plans` (the sheet, titled by its value if any).
      switch (parameters) {
        case {'feed': final id}:
          appNavigation.openFeed(id);
        case {'show': final id}:
          appNavigation.openShow(int.parse(id));
        case {'settings': _}:
          appNavigation.openSettings();
        case {'nowPlaying': _}:
          appNavigation.openNowPlaying();
        case {'plans': final title}:
          appNavigation.openPlans(title: title.isEmpty ? null : title);
        default:
          throw ArgumentError('open what? feed, show, settings, nowPlaying or plans');
      }
    case 'download':
      final episode = s.library.episode(int.tryParse(parameters['episode'] ?? '') ?? -1);
      unawaited(s.downloads.download(episode ?? (throw ArgumentError('no episode ${parameters['episode']}'))));
    case 'drag':
      // A pointer of `kind` (touch, the default, mouse or trackpad) from
      // `x`,`y` by `dx`,`dy` logical pixels over `ms` (default 300).
      double at(String key) => double.tryParse(parameters[key] ?? '') ?? (throw ArgumentError('$key?'));
      final kind = PointerDeviceKind.values.byName(parameters['kind'] ?? 'touch');
      final ms = int.tryParse(parameters['ms'] ?? '') ?? 300;
      unawaited(_drag(Offset(at('x'), at('y')), Offset(at('dx'), at('dy')), Duration(milliseconds: ms), kind));
    case final action:
      throw ArgumentError('unknown action $action; play, pause, stop, seek, refresh, add, follow, unfollow, move, open, download or drag');
  }
}

/// Moves a pointer of [kind] from [from] by [by] over [over], as a hand
/// would, one event a frame.
Future<void> _drag(Offset from, Offset by, Duration over, PointerDeviceKind kind) async {
  const device = 9000;
  const pointer = 9000;
  final clock = Stopwatch()..start();
  void send(PointerEvent event) => GestureBinding.instance.handlePointerEvent(event);
  final steps = (over.inMilliseconds / 16).ceil().clamp(1, 1000);
  final step = by / steps.toDouble();
  final trackpad = kind == PointerDeviceKind.trackpad;
  if (kind == PointerDeviceKind.mouse) send(PointerAddedEvent(timeStamp: clock.elapsed, kind: kind, device: device, position: from));
  send(trackpad
    ? PointerPanZoomStartEvent(timeStamp: clock.elapsed, device: device, pointer: pointer, position: from)
    : PointerDownEvent(timeStamp: clock.elapsed, kind: kind, device: device, pointer: pointer, position: from));
  for (var i = 1; i <= steps; i++) {
    await Future<void>.delayed(Duration(microseconds: over.inMicroseconds ~/ steps));
    send(trackpad
      ? PointerPanZoomUpdateEvent(timeStamp: clock.elapsed, device: device, pointer: pointer, position: from, pan: step * i.toDouble(), panDelta: step)
      : PointerMoveEvent(timeStamp: clock.elapsed, kind: kind, device: device, pointer: pointer, position: from + step * i.toDouble(), delta: step));
  }
  send(trackpad
    ? PointerPanZoomEndEvent(timeStamp: clock.elapsed, device: device, pointer: pointer, position: from)
    : PointerUpEvent(timeStamp: clock.elapsed, kind: kind, device: device, pointer: pointer, position: from + by));
  if (kind == PointerDeviceKind.mouse) send(PointerRemovedEvent(timeStamp: clock.elapsed, kind: kind, device: device, position: from + by));
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

/// The app's one Navigation, which `ext.listenjar.control` drives too.
final appNavigation = Navigation();

class _AppState extends State<App> {
  final _navigation = appNavigation;

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
          // macOS's window buttons are the status bar (shell.dart).
          builder: (context, child) => windowInsets(
            context,
            kDebugMode ? Banner(message: 'DEBUG', location: BannerLocation.topEnd, child: child!) : child!,
          ),
          // Light only, like listenjar.com: paper is the ground (DESIGN.md).
          theme: brand.theme(),
          // Android asks about updates over the window (updates.dart).
          home: UpdatePrompt(child: Shell(links: widget.links)),
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
    unawaited(_podcasts.followCloud(_feeds.feeds, removed: _feeds.removed).then((_) async {
      for (final MapEntry(key: id, value: (_, count)) in now.entries) {
        final was = before[id];
        if (was != null && was.$2 != count) await _podcasts.cloudPublished(id);
      }
    }));
  }
}
