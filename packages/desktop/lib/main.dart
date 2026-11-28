// Listenjar: a podcast player first, free and without an account (the
// library, refresh, downloads and playback: library.dart, podcasts.dart,
// downloads.dart, player.dart), and Listenjar Cloud beside it for listeners
// who sign in (cloud.dart: their YouTube feeds, synced from this device by
// feeds.dart and sync.dart). Their own feeds play here like any podcast.
// The window is shell.dart. Everything below lives for the process: the
// window, the tray (tray.dart) and the schedule (schedule.dart) share it.
import 'dart:async';

import 'package:cancellation_token/cancellation_token.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nativeapi/nativeapi.dart' as native show Size;
import 'package:nativeapi_flutter/nativeapi_flutter.dart' show Application, WindowManager;

import 'account.dart';
import 'cloud_shows.dart';
import 'backend/api.dart' show FeedVisibility, Plan;
import 'directory.dart';
import 'downloads.dart';
import 'feeds.dart';
import 'library.dart';
import 'library_sync.dart';
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
  final youtube = YouTubeService()
    ..warmUp()
    ..watchReleases();
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
  librarySync = LibrarySync(account, podcasts);
  Tray.start(account, feeds);
  unawaited(SyncSchedule().start(feeds, podcasts));
  unawaited(podcasts.refreshAll());
  // Back online: the feeds that couldn't sync while it was gone sync now.
  var wasOffline = podcasts.offline;
  podcasts.addListener(() {
    if (podcasts.offline == wasOffline) return;
    wasOffline = podcasts.offline;
    if (!wasOffline) feeds.syncNow();
  });
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

/// The library between the listener's devices, on a Listenjar Cloud plan.
LibrarySync? librarySync;

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
      'episode': episode == null
        ? null
        : {'id': episode.id, 'title': episode.title, 'show': episode.from, 'audio': episode.audioUrl, 'artwork': episode.artwork, 'cover': episode.cover, 'notes': library.description(episode.id).length},
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
    // What plays after the episode when Up Next is empty.
    'then': player.following?.title,
    'librarySync': switch (librarySync) {
      final sync? => {'on': sync.on, 'syncedAt': sync.syncedAt?.toIso8601String(), 'error': sync.error?.toString()},
      null => null,
    },
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
    'youtubejs': s.youtube.bundles.state,
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
    case 'syncLibrary':
      // A library sync pass with Listenjar Cloud now.
      unawaited(librarySync?.sync());
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
    case 'video':
      // A YouTube video `url` pasted into Search: looked up, then played.
      final link = parseYouTubeLink(parameters['url'] ?? '') ?? (throw ArgumentError('not a YouTube link'));
      unawaited(() async {
        final token = CancellationToken();
        final found = await (await s.youtube.session(token)).lookup(SourceRef(SourceRefKind.video, link.id, link.url), token);
        final episode = await s.podcasts.youtubeVideo(
          link,
          token,
          title: found.title,
          channel: found.details.firstOrNull,
          artworkUrl: found.thumbnailUrl,
          description: found.description,
          publishedAt: found.publishedAt,
        );
        await player.playEpisode(episode);
      }());
    case 'rss':
      // A podcast's RSS feed (`url`), followed as the directory does.
      final url = Uri.tryParse(parameters['url'] ?? '') ?? (throw ArgumentError('url?'));
      unawaited(s.podcasts.follow(url, CancellationToken()));
    case 'follow':
      // A YouTube playlist or channel `url`, followed on this device.
      final link = parseYouTubeLink(parameters['url'] ?? '') ?? (throw ArgumentError('not a YouTube link'));
      unawaited(s.podcasts.followYouTube(link, TimeoutCancellationToken(const Duration(minutes: 3))));
    case 'unfollow':
      final show = s.library.podcast(int.tryParse(parameters['show'] ?? '') ?? -1) ?? (throw ArgumentError('no show ${parameters['show']}'));
      unawaited(s.podcasts.unfollow(show));
    case 'visibility':
      // A podcast of the listener's own in the Cloud (`feed`, an id) made
      // `public` (a page on listenjar.com) or `private`.
      final feed = s.feeds.feeds.where((f) => f.id == parameters['feed']).firstOrNull
        ?? (throw ArgumentError('no feed ${parameters['feed']}'));
      unawaited(s.feeds.setVisibility(feed, FeedVisibility.fromJson(parameters['to'] ?? 'public')));
    case 'open':
      // A Listenjar `feed` (an id), a `show` (an id), `settings`,
      // `nowPlaying`, `plans` (the sheet, titled by its value if any),
      // `newPodcast` (making one, as the Library's button does) or `search`.
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
        case {'newPodcast': _}:
          appNavigation.openNewPodcast();
        case {'search': final query}:
          // Search, asking `query` of podcasts, or of YouTube when `youtube`
          // is true.
          appNavigation.openSearch(query: query, youtube: parameters['youtube'] == 'true');
        default:
          throw ArgumentError('open what? feed, show, settings, nowPlaying, plans, newPodcast or search');
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
    case 'key':
      // A `key` (up, down, left, right, space, enter, escape or tab) pressed
      // and let go, to whatever has focus.
      final (physical, logical) = switch (parameters['key']) {
        'up' => (PhysicalKeyboardKey.arrowUp, LogicalKeyboardKey.arrowUp),
        'down' => (PhysicalKeyboardKey.arrowDown, LogicalKeyboardKey.arrowDown),
        'left' => (PhysicalKeyboardKey.arrowLeft, LogicalKeyboardKey.arrowLeft),
        'right' => (PhysicalKeyboardKey.arrowRight, LogicalKeyboardKey.arrowRight),
        'space' => (PhysicalKeyboardKey.space, LogicalKeyboardKey.space),
        'enter' => (PhysicalKeyboardKey.enter, LogicalKeyboardKey.enter),
        'escape' => (PhysicalKeyboardKey.escape, LogicalKeyboardKey.escape),
        'tab' => (PhysicalKeyboardKey.tab, LogicalKeyboardKey.tab),
        final key => throw ArgumentError('key $key? up, down, left, right, space, enter, escape or tab'),
      };
      _press(physical, logical);
    case 'window':
      // The window resized to `width` × `height` logical pixels, to see the
      // narrow (phone) layout on a computer; macOS stops it at 520 wide.
      double at(String key) => double.tryParse(parameters[key] ?? '') ?? (throw ArgumentError('$key?'));
      final window = Application.instance.getPrimaryWindow() ?? WindowManager.instance.getCurrent() ?? (throw StateError('no window'));
      window.setSize(native.Size(width: at('width'), height: at('height')), false);
    case final action:
      throw ArgumentError('unknown action $action; play, pause, stop, seek, refresh, add, follow, unfollow, move, open, download, drag, key or window');
  }
}

/// [logical] down and up, through the focus tree as a keyboard's would go.
void _press(PhysicalKeyboardKey physical, LogicalKeyboardKey logical) {
  // The key message handler is what still routes a key through the focus tree.
  // ignore: deprecated_member_use
  final handler = ServicesBinding.instance.keyEventManager.keyMessageHandler ?? (throw StateError('no key handler'));
  final keyboard = HardwareKeyboard.instance;
  for (final event in <KeyEvent>[
    KeyDownEvent(physicalKey: physical, logicalKey: logical, timeStamp: Duration.zero),
    KeyUpEvent(physicalKey: physical, logicalKey: logical, timeStamp: Duration.zero),
  ]) {
    keyboard.handleKeyEvent(event);
    // ignore: deprecated_member_use
    handler(KeyMessage([event], null));
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
          title: 'Listenjar',
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
