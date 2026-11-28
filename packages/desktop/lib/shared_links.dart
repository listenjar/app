// Links shared to Listenjar from other apps, and what it does with them.
//
// Each platform's runner holds them until Dart takes them: Android's share
// sheet and links opened with the app wait in SharedLinks.java, which Dart
// calls over JNI; a `<scheme>://open?url=…` link waits in SharedLinks.swift
// on iOS, over FFI, and in macOS's runner, on the `listenjar/links` channel.
// Linux and Windows pass a link as an argument: a first launch's to main(),
// a second launch's on that channel.
//
// A YouTube channel or playlist takes a paid plan: followed on this device,
// streaming from YouTube, or as a Listenjar Cloud feed, as the listener
// picks. A YouTube video becomes a podcast of a single episode in the
// library, free; on a paid plan the listener may add it to a podcast of
// their own instead, on this device or in the Cloud. Any other link goes to search, which knows
// podcast feeds. Local pays for everything on this device; what goes to the
// Cloud takes 10 GB or 100 GB (mayUseCloud). An Apple Podcasts link opens
// its show, and the episode it names, through Apple's directory. Links in
// show notes open here too (openWebLink): a YouTube video to play, without
// a question, and the rest as above, or in the browser.
import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:cancellation_token/cancellation_token.dart';
import 'package:flutter/services.dart';
import 'package:jni/jni.dart';
import 'package:objective_c/objective_c.dart' as objc;
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import 'backend/api.dart' show Feed, SourceKind;
import 'library.dart' show Podcast;
import 'config.dart' show appScheme;
import 'links.dart';
import 'log.dart';
import 'plans.dart' show askNewPodcast, hasCloud, isPaid, showPlans;
import 'shared_links.g.dart' as android;
import 'shared_links_ios.g.dart' as ios;
import 'sync.dart' show PlanLimit;
import 'theme.dart' as brand;
import 'ui.dart';
import 'youtube.dart' show SearchResult, SourceRef, SourceRefKind;

final _log = Logger('links');

/// The link waiting for the window to act on it: only the latest, as a
/// newer share replaces one not opened yet (and the shell closes the
/// question of one being opened).
final class IncomingLinks extends ChangeNotifier {
  IncomingLinks(List<String> arguments) {
    for (final argument in arguments) {
      _take(argument);
    }
    if (Platform.isAndroid) {
      _listenAndroid();
    } else if (Platform.isIOS) {
      _listenIOS();
    } else {
      _listenChannel();
    }
  }

  static const _channel = MethodChannel('listenjar/links');
  Uri? _waiting;

  // SharedLinks.java pings from the activity, on the main thread, which is
  // also the UI thread: the ping comes here as a message (async), after the
  // activity's callback returns. take() is quick enough for that thread.
  void _listenAndroid() {
    void arrived() {
      final links = android.SharedLinks.take()!;
      for (final link in links.asDart()) {
        _take(link!.toDartString(releaseOriginal: true));
      }
      links.release();
    }

    android.SharedLinks.listen(android.SharedLinks$Listener.implement(
      android.$SharedLinks$Listener(arrived: arrived, arrived$async: true),
    ));
  }

  // SharedLinks.swift pings on the main thread, which is the UI thread; the
  // ping comes here as a message, after the scene callback returns. The
  // callable lives as long as the app, as SharedLinks keeps it.
  void _listenIOS() {
    final arrived = NativeCallable<Void Function()>.listener(() {
      for (final link in ios.LJSharedLinks.take().asDart()) {
        _take(objc.NSString.as(link).toDartString());
      }
    });
    ios.LJSharedLinks.listen(arrived.nativeFunction);
  }

  // macOS's runner, and a second launch on Linux and Windows.
  void _listenChannel() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'open' && call.arguments is String) _take(call.arguments as String);
    });
    // Links the runner held until this side listened.
    unawaited(_channel.invokeListMethod<String>('pending').then(
      (links) => links?.forEach(_take),
      onError: (Object _) {}, // No runner side on this platform.
    ));
  }

  Uri? next() {
    final link = _waiting;
    _waiting = null;
    return link;
  }

  List<Uri> get waiting => [?_waiting];

  void _take(String text) {
    final link = linkIn(text);
    _log.fine('Received “$text”${link == null ? ': no link in it' : ''}');
    if (link != null) {
      _waiting = link;
      notifyListeners();
    }
  }
}

/// The web link in [text]: a link, a `<scheme>://open?url=…` wrapper, or
/// the first link in shared text ("Watch this: https://youtu.be/…").
Uri? linkIn(String text) {
  final match = RegExp(r'[a-z][a-z0-9+.-]*://\S+', caseSensitive: false).firstMatch(text);
  if (match == null) return null;
  final uri = Uri.tryParse(match[0]!);
  if (uri == null) return null;
  if (uri.scheme == appScheme) {
    // Sign-in brings the window back; signin.dart handles the rest.
    if (uri.host != 'open') return null;
    return switch (uri.queryParameters['url']) {
      final inner? => linkIn(inner),
      null => null,
    };
  }
  return uri.scheme == 'http' || uri.scheme == 'https' ? uri : null;
}

/// Does what [link] asks, as the rules at the top of this file say. Gives
/// up, asking nothing, once [replaced] says a newer link came.
Future<void> openLink(BuildContext context, Uri link, {bool Function()? replaced}) async {
  bool isReplaced() => replaced?.call() ?? false;
  final s = Services.of(context);
  final navigation = Navigation.of(context);
  if (parseApplePodcastsLink(link.toString()) case final apple?) {
    await openApplePodcasts(context, apple, link);
    return;
  }
  final youtube = parseYouTubeLink(link.toString());
  _log.info('Opening $link as ${youtube?.kind.name ?? 'a search'}');
  if (youtube == null) {
    navigation.openSearch(query: link.toString());
    return;
  }
  // A share often opens the app, or comes in as it starts, before the API
  // has said who is signed in: on a paid plan that would read as free, and
  // the video would skip the question of where it goes.
  if (s.account.restoring) {
    _log.fine('Waiting for the account before opening $link');
    await s.account.restored();
    if (!context.mounted || isReplaced()) return;
  }
  if (youtube.kind != SourceKind.video) {
    await followYouTube(context, youtube, 'this ${kindLabel(youtube.kind)}');
    return;
  }
  if (isPaid(s.account.user)) {
    // Their podcasts in Listenjar Cloud list from its feeds, which load just
    // after the account: wait, or they'd be missing from the choices.
    // What it is, for the question to name: looked up meanwhile.
    final video = _lookUp(s, youtube);
    if (s.feeds.loading) {
      await s.feeds.load();
      if (!context.mounted || isReplaced()) return;
    }
    final choice = await _askWhere(context, youtube, video);
    if (choice == null || !context.mounted) return;
    // Known by now, most likely: saves adding it looking it up again.
    final title = await video.timeout(Duration.zero, onTimeout: () => null);
    if (!context.mounted) return;
    await switch (choice) {
      _Own(:final own) => addVideoToOwnPodcast(context, youtube.url, own, title: title?.title),
      _New() => addVideoToOwnPodcast(context, youtube.url, null, title: title?.title),
    };
    return;
  }
  await _guard(context, () async {
    final episode = await s.podcasts.youtubeVideo(youtube, CancellationToken(), follow: true);
    navigation.openShow(episode.podcastId);
    if (context.mounted) tell(context, 'Added “${episode.title}” to your library.');
  });
}

/// A link tapped in show notes. An Apple Podcasts show or episode opens
/// here, as does a YouTube video, as a show of one, to play; a YouTube
/// channel or playlist is followed, which takes a plan. Anything else
/// opens in the browser.
Future<void> openWebLink(BuildContext context, Uri url) async {
  if (parseApplePodcastsLink(url.toString()) case final apple?) return openApplePodcasts(context, apple, url);
  final youtube = parseYouTubeLink(url.toString());
  if (youtube == null) {
    await launchUrl(url, mode: LaunchMode.externalApplication);
    return;
  }
  _log.info('Opening $url from show notes as a ${youtube.kind.name}');
  // Whatever it opens, opens in the window, under Now Playing or an
  // episode sheet: those close first, and the root's context carries on.
  final root = Navigator.of(context, rootNavigator: true);
  root.popUntil((r) => r.isFirst);
  final here = root.context;
  if (youtube.kind != SourceKind.video) {
    await followYouTube(here, youtube, 'this ${kindLabel(youtube.kind)}');
    return;
  }
  final s = Services.of(here);
  final navigation = Navigation.of(here);
  await _guard(here, () async {
    tell(here, 'Opening the video…');
    final episode = await s.podcasts.youtubeVideo(youtube, TimeoutCancellationToken(const Duration(minutes: 1)));
    if (!here.mounted) return;
    ScaffoldMessenger.maybeOf(here)?.hideCurrentSnackBar();
    navigation.openShow(episode.podcastId);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (root.mounted) unawaited(showEpisode(here, episode));
    });
  });
}

/// Opens the show an Apple Podcasts [link] names, and over it the episode
/// when the link names one; closes Now Playing or an episode sheet first,
/// as the show opens under them. Apple shares no feed for the shows it
/// hosts itself: those open at [url], in the browser.
Future<void> openApplePodcasts(BuildContext context, ApplePodcastsLink link, Uri url, {bool follow = false}) async {
  final s = Services.of(context);
  final navigation = Navigation.of(context);
  final root = Navigator.of(context, rootNavigator: true);
  _log.info('Opening $url as Apple Podcasts show ${link.showId}, episode ${link.episodeId}');
  await _guard(context, () async {
    tell(context, 'Opening it…');
    final token = CancellationToken().merge(TimeoutCancellationToken(const Duration(minutes: 1)));
    final found = await s.directory.applePodcast(link, token);
    if (found == null) {
      if (context.mounted) tell(context, 'Apple doesn’t share this show’s feed, so it opens in the browser.');
      await launchUrl(url, mode: LaunchMode.externalApplication);
      return;
    }
    final show = await s.podcasts.open(Uri.parse(found.feedUrl), token, follow: follow);
    final episode = switch (found.episodeGuid) {
      final guid? => s.library.episodes(show.id).where((e) => e.guid == guid).firstOrNull,
      null => null,
    };
    if (!root.mounted) return;
    ScaffoldMessenger.maybeOf(root.context)?.hideCurrentSnackBar();
    root.popUntil((r) => r.isFirst);
    navigation.openShow(show.id);
    if (episode != null) {
      // Over the show page, once it's pushed.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (root.mounted) unawaited(showEpisode(root.context, episode));
      });
    } else if (link.episodeId != null) {
      tell(root.context, 'Couldn’t find that episode in “${show.title}”.');
    }
  });
}

/// Follows the YouTube playlist or channel [link], called [what], with a
/// plan: its videos list here and stream from YouTube at once. On a plan
/// with Listenjar Cloud this device then uploads them too, and it becomes a
/// podcast for any podcast app (cloud_shows.dart).
Future<void> followYouTube(BuildContext context, YouTubeLink link, String what) async {
  if (!await mayFollowInCloud(context, what) || !context.mounted) return;
  final s = Services.of(context);
  final navigation = Navigation.of(context);
  await _guard(context, () async {
    tell(context, 'Listing its videos…');
    final show = await s.podcasts.followYouTube(link, TimeoutCancellationToken(const Duration(minutes: 3)));
    navigation.openShow(show.id);
    if (context.mounted) tell(context, 'Following “${show.title}”.');
  });
}

/// Whether the listener's plan has Listenjar Cloud (10 GB, 100 GB). On
/// Local it doesn't: offers the plans that have it, under [title]. Signed
/// out or free, callers have asked [mayFollowInCloud] and the like first.
Future<bool> mayUseCloud(BuildContext context, String title) async {
  final user = Services.of(context).account.user;
  if (hasCloud(user)) return true;
  await showPlans(context, title: title, cloud: true);
  return false;
}

/// Whether the listener may follow [what] (“Lex Fridman”, this YouTube
/// channel), on this device or in Listenjar Cloud: both take a plan. If they
/// can't, says why: signed out, offers to sign in; on the free plan, the
/// plans.
Future<bool> mayFollowInCloud(BuildContext context, String what) async {
  final user = Services.of(context).account.user;
  if (user == null) {
    await _askToSignIn(
      context,
      title: 'Follow $what',
      body: 'Single videos play here for free. Following a playlist or a channel takes a plan: '
        'with Listenjar Local, its new videos stream here from YouTube; with 10 GB or 100 GB, '
        'they become a podcast in Listenjar Cloud for any podcast app. Sign in to pick a plan.',
    );
    return false;
  }
  if (!isPaid(user)) {
    await showPlans(context, title: 'Follow playlists and channels');
    return false;
  }
  return true;
}

/// Whether the listener may make a podcast of their own. If they can't,
/// says why, as [mayFollowInCloud] does.
Future<bool> mayMakePodcast(BuildContext context) async {
  final user = Services.of(context).account.user;
  if (user == null) {
    await _askToSignIn(
      context,
      title: 'Make a podcast of your own',
      body: 'Gather any YouTube videos into a podcast with your own name and artwork: '
        'on this device with Listenjar Local, or in Listenjar Cloud for any podcast app with 10 GB or 100 GB. '
        'That takes an account and a plan.',
    );
    return false;
  }
  if (!isPaid(user)) {
    await showPlans(context, title: 'Podcasts of your own');
    return false;
  }
  return true;
}

/// A podcast of the listener's own: on this device, where its videos
/// stream from YouTube, or in Listenjar Cloud, which uploads them for any
/// podcast app. Where the videos they pick can go.
/// A podcast of the listener's own: a show in the library, or, made on a
/// plan with Listenjar Cloud, a feed Listenjar hosts. Which one is the
/// plan's business; it lists, opens and fills the same either way.
final class OwnPodcast {
  const OwnPodcast.show(Podcast this.show) : feed = null;
  const OwnPodcast.feed(Feed this.feed) : show = null;
  final Podcast? show;
  final Feed? feed;

  /// Its id for [Navigation.openSearch]'s `into`.
  String get id => feed?.id ?? 'local:${show!.id}';
  String get title => feed?.title ?? show!.title;
}

/// The listener's podcasts of their own: those here, then those Listenjar
/// hosts that aren't one of them on its way up.
List<OwnPodcast> ownPodcasts(BuildContext context) {
  final s = Services.of(context);
  final here = [for (final p in s.library.podcasts) if (p.isOwn) p];
  final linked = {for (final p in here) ?p.cloudFeedId};
  return [
    for (final p in here) OwnPodcast.show(p),
    for (final f in s.feeds.own) if (!linked.contains(f.id)) OwnPodcast.feed(f),
  ];
}

/// The podcast of the listener's own whose [OwnPodcast.id] is [id].
OwnPodcast? ownPodcast(BuildContext context, String id) => ownPodcasts(context).where((o) => o.id == id).firstOrNull;

/// Makes a podcast of the listener's own, asking its name, offered as
/// [name]. It starts here; on a plan with Listenjar Cloud it becomes a
/// feed Listenjar hosts too (cloud_shows.dart). Null when they cancel or
/// it fails, which it says.
Future<OwnPodcast?> newOwnPodcast(BuildContext context, {String? name}) async {
  if (!await mayMakePodcast(context) || !context.mounted) return null;
  final title = await askNewPodcast(context, name: name);
  if (title == null || !context.mounted) return null;
  return OwnPodcast.show(Services.of(context).library.createOwn(title));
}

/// Adds the YouTube video at [url] to [own], a podcast of the listener's
/// own, or, when [own] is null, to a new one they make; returns where it
/// went, or null when it didn't, which it says. [title] and [duration],
/// when search knows them, save looking the video up.
Future<OwnPodcast?> addVideoToOwnPodcast(BuildContext context, String url, OwnPodcast? own, {String? title, Duration? duration}) async {
  final link = parseYouTubeLink(url);
  if (link == null || link.kind != SourceKind.video) return null;
  if (own != null && !await mayMakePodcast(context)) return null;
  if (!context.mounted) return null;
  final target = own ?? await newOwnPodcast(context, name: title);
  if (target == null || !context.mounted) return null;
  // One of theirs in the Cloud from when the plan had it.
  if (target.feed != null && !await mayUseCloud(context, 'Add to “${target.title}”')) return null;
  if (!context.mounted) return null;
  final s = Services.of(context);
  final token = TimeoutCancellationToken(const Duration(minutes: 2));
  var added = false;
  await _guard(context, () async {
    // Here first, streaming at once; then in its Listenjar feed, if it has
    // one, which uploads it.
    final feed = target.feed ?? s.feeds.feeds.where((f) => f.id == target.show!.cloudFeedId).firstOrNull;
    final show = target.show ?? s.library.podcasts.where((p) => p.cloudFeedId == feed!.id).firstOrNull;
    final episode = show == null ? null : await s.podcasts.addToOwn(show, link, token, title: title, duration: duration);
    // One episode per video: one it has already, it has in its feed too.
    final there = show != null && episode == null;
    if (feed != null && !there) await s.feeds.addVideo(feed, link.url, token);
    if (context.mounted) {
      tell(context, there ? 'It’s already in “${target.title}”.' : 'Added to “${target.title}”.');
    }
    added = true;
  });
  return added ? target : null;
}

Future<void> _guard(BuildContext context, Future<void> Function() action) async {
  try {
    await action();
  } on PlanLimit {
    if (context.mounted) await showPlans(context, title: 'Your storage is full', cloud: true);
  } catch (e, stack) {
    _log.warning('Couldn’t add a shared link', e, stack);
    if (context.mounted) tell(context, 'Couldn’t add that: $e');
  }
}

/// Offers to sign in; yes closes Now Playing, if it's open, for Settings,
/// whose account panel has the ways to sign in.
Future<void> _askToSignIn(BuildContext context, {required String title, required String body}) async {
  final text = Theme.of(context).textTheme;
  final navigation = Navigation.of(context);
  final root = Navigator.of(context, rootNavigator: true);
  final go = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: brand.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(brand.radiusSheet)),
      title: Text(title, style: text.titleLarge),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Text(
          body,
          style: text.bodyMedium!.copyWith(color: brand.fgSoft),
        ),
      ),
      actions: [
        TextButton(style: brand.button(brand.Tone.quiet, brand.ButtonSize.sm), onPressed: () => Navigator.pop(context, false), child: const Text('Not now')),
        TextButton(style: brand.button(brand.Tone.accent, brand.ButtonSize.sm), onPressed: () => Navigator.pop(context, true), child: const Text('Sign in')),
      ],
    ),
  );
  if (go != true || !context.mounted) return;
  root.popUntil((route) => route.isFirst);
  navigation.openSettings();
}

sealed class _Where {
  const _Where();
}

final class _Own extends _Where {
  const _Own(this.own);
  final OwnPodcast own;
}

final class _New extends _Where {
  const _New();
}


/// [link]'s title, thumbnail, channel and length; null when YouTube won't
/// say, which the question gets by with.
Future<SearchResult?> _lookUp(Services s, YouTubeLink link) async {
  final token = TimeoutCancellationToken(const Duration(seconds: 30));
  try {
    return await (await s.youtube.session(token)).lookup(SourceRef(SourceRefKind.video, link.id, link.url), token);
  } catch (e) {
    _log.info('Couldn’t look up ${link.url} for the question', e);
    return null;
  }
}

/// On a paid plan: into one of the listener's own podcasts, or a new one.
/// Under its title, the [video] it's about, its link until [found] says
/// what it is.
Future<_Where?> _askWhere(BuildContext context, YouTubeLink video, Future<SearchResult?> found) {
  final text = Theme.of(context).textTheme;
  final own = ownPodcasts(context);
  Widget option(IconData icon, String title, String? body, _Where where) => InkWell(
    borderRadius: BorderRadius.circular(14),
    onTap: () => Navigator.pop(context, where),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: Row(children: [
        Icon(icon, color: brand.fgSoft, size: 22),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: text.titleMedium!.copyWith(fontSize: 15)),
            if (body != null) Text(body, style: text.bodySmall!.copyWith(color: brand.fgSoft)),
          ]),
        ),
      ]),
    ),
  );
  return showDialog<_Where>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: brand.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(brand.radiusSheet)),
      title: Text('Add this video', style: text.titleLarge),
      contentPadding: const EdgeInsets.fromLTRB(12, 16, 12, 8),
      // As wide when the video's title comes as before, so nothing jumps.
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: _VideoHeader(link: video, found: found),
            ),
            for (final o in own) option(Icons.playlist_add_rounded, 'Add to “${o.title}”', null, _Own(o)),
            option(Icons.add_rounded, 'Add to a new podcast…', null, const _New()),
          ]),
        ),
      ),
      actions: [
        TextButton(style: brand.button(brand.Tone.quiet, brand.ButtonSize.sm), onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      ],
    ),
  );
}

/// The video a question is about: its thumbnail, title, and channel and
/// length, once [found] has them; its link until then, or if YouTube won't
/// say.
final class _VideoHeader extends StatelessWidget {
  const _VideoHeader({required this.link, required this.found});
  final YouTubeLink link;
  final Future<SearchResult?> found;

  static const _width = 112.0;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    const placeholder = ColoredBox(color: brand.paperDeep);
    return FutureBuilder<SearchResult?>(
      future: found,
      builder: (context, snapshot) {
        final video = snapshot.data;
        final waiting = snapshot.connectionState != ConnectionState.done;
        final details = [...?video?.details.take(1), ?video?.badge].join(' · ');
        return Semantics(
          label: video == null ? link.url : '${video.title}${details.isEmpty ? '' : ', $details'}',
          excludeSemantics: true,
          child: Row(children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: _width,
                height: _width * 9 / 16,
                child: switch (video?.thumbnailUrl) {
                  null => placeholder,
                  final url => Image.network(
                    url,
                    fit: BoxFit.cover,
                    cacheWidth: (_width * dpr).round(),
                    errorBuilder: (_, _, _) => placeholder,
                    frameBuilder: (_, child, frame, sync) => sync || frame != null ? child : placeholder,
                  ),
                },
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                  video?.title ?? (waiting ? 'Looking it up…' : link.url),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: text.titleMedium!.copyWith(fontSize: 15, color: video == null ? brand.fgSoft : null),
                ),
                if (details.isNotEmpty || video == null)
                  Text(
                    video == null ? (waiting ? link.url : 'YouTube didn’t say what it is') : details,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodySmall!.copyWith(color: brand.fgSoft),
                  ),
              ]),
            ),
          ]),
        );
      },
    );
  }
}
