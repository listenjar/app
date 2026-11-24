// Links shared to ListenJar from other apps, and what it does with them.
//
// Each platform's runner holds them until Dart takes them: Android's share
// sheet and links opened with the app wait in SharedLinks.java, which Dart
// calls over JNI; a `<scheme>://open?url=…` link waits in SharedLinks.swift
// on iOS, over FFI, and in macOS's runner, on the `listenjar/links` channel.
// Linux and Windows pass a link as an argument: a first launch's to main(),
// a second launch's on that channel.
//
// A YouTube channel or playlist takes a paid plan: followed on this device,
// streaming from YouTube, or as a ListenJar Cloud feed, as the listener
// picks. A YouTube video becomes a podcast of a single episode in the
// library, free; on a paid plan the listener may add it to a podcast of
// their own instead, on this device or in the Cloud. Any other link goes to search, which knows
// podcast feeds. Local pays for everything on this device; what goes to the
// Cloud takes 10 GB or 100 GB (mayUseCloud).
import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:cancellation_token/cancellation_token.dart';
import 'package:flutter/services.dart';
import 'package:jni/jni.dart';
import 'package:objective_c/objective_c.dart' as objc;
import 'package:material_ui/material_ui.dart';

import 'backend/api.dart' show Feed, SourceKind;
import 'library.dart' show Podcast;
import 'config.dart' show appScheme;
import 'links.dart';
import 'log.dart';
import 'plans.dart' show askNewPodcast, cloudPlanHint, hasCloud, isPaid, showPlans;
import 'shared_links.g.dart' as android;
import 'shared_links_ios.g.dart' as ios;
import 'sync.dart' show PlanLimit;
import 'theme.dart' as brand;
import 'ui.dart';

final _log = Logger('links');

/// Links waiting for the window to act on them, oldest first.
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
  final _waiting = <Uri>[];

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

  Uri? next() => _waiting.isEmpty ? null : _waiting.removeAt(0);

  List<Uri> get waiting => List.unmodifiable(_waiting);

  void _take(String text) {
    final link = linkIn(text);
    _log.fine('Received “$text”${link == null ? ': no link in it' : ''}');
    if (link != null) {
      _waiting.add(link);
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

/// Does what [link] asks, as the rules at the top of this file say.
Future<void> openLink(BuildContext context, Uri link) async {
  final s = Services.of(context);
  final navigation = Navigation.of(context);
  final youtube = parseYouTubeLink(link.toString());
  _log.info('Opening $link as ${youtube?.kind.name ?? 'a search'}');
  if (youtube == null) {
    navigation.openSearch(query: link.toString());
    return;
  }
  if (youtube.kind != SourceKind.video) {
    await followYouTube(context, youtube, 'this ${kindLabel(youtube.kind)}');
    return;
  }
  if (isPaid(s.account.user)) {
    final choice = await _askWhere(context);
    if (choice == null || !context.mounted) return;
    await switch (choice) {
      _Own(:final own) => addVideoToOwnPodcast(context, youtube.url, own),
      _New() => addVideoToOwnPodcast(context, youtube.url, null),
      _Single() => addToCloud(context, youtube.url),
    };
    return;
  }
  await _guard(context, () async {
    final episode = await s.podcasts.youtubeVideo(youtube, CancellationToken(), follow: true);
    navigation.openShow(episode.podcastId);
    if (context.mounted) tell(context, 'Added “${episode.title}” to your library.');
  });
}

/// Follows the YouTube playlist or channel [link], called [what], with a
/// plan: on this device, where its videos stream from YouTube as they play
/// and nothing downloads, or in ListenJar Cloud, which uploads them for any
/// podcast app. [cloud] says which; null asks.
Future<void> followYouTube(BuildContext context, YouTubeLink link, String what, {bool? cloud}) async {
  if (!await mayFollowInCloud(context, what) || !context.mounted) return;
  cloud ??= await _askHowToFollow(context, what);
  if (cloud == null || !context.mounted) return;
  if (cloud) return addToCloud(context, link.url);
  final s = Services.of(context);
  final navigation = Navigation.of(context);
  await _guard(context, () async {
    tell(context, 'Listing its videos…');
    final show = await s.podcasts.followYouTube(link, TimeoutCancellationToken(const Duration(minutes: 3)));
    navigation.openShow(show.id);
    if (context.mounted) tell(context, 'Following “${show.title}” on this device. Its videos stream from YouTube.');
  });
}

/// On a paid plan: a playlist or channel on this device, or in the Cloud.
Future<bool?> _askHowToFollow(BuildContext context, String what) {
  final text = Theme.of(context).textTheme;
  Widget option(IconData icon, String title, String body, bool cloud) => InkWell(
    borderRadius: BorderRadius.circular(14),
    onTap: () => Navigator.pop(context, cloud),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: Row(children: [
        Icon(icon, color: brand.fgSoft, size: 22),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: text.titleMedium!.copyWith(fontSize: 15)),
            Text(body, style: text.bodySmall!.copyWith(color: brand.fgSoft)),
          ]),
        ),
      ]),
    ),
  );
  return showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: brand.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(brand.radiusSheet)),
      title: Text('Follow $what', style: text.titleLarge),
      contentPadding: const EdgeInsets.fromLTRB(12, 16, 12, 8),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          option(Icons.smart_display_outlined, 'On this device', followLocalHint, false),
          option(
            Icons.cloud_outlined,
            'In ListenJar Cloud',
            hasCloud(Services.of(context).account.user) ? followCloudHint : cloudPlanHint,
            true,
          ),
        ]),
      ),
      actions: [
        TextButton(style: brand.button(brand.Tone.quiet, brand.ButtonSize.sm), onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      ],
    ),
  );
}

/// What following on this device means, in a line.
const followLocalHint = 'Streams each video from YouTube when you play it. Nothing downloads; only this app has it.';

/// What following in ListenJar Cloud means, in a line.
const followCloudHint = 'This device uploads every video, for any podcast app. Uses your storage.';

/// Adds [url] to ListenJar Cloud as a feed of its own, and opens it in the
/// Library. Without the Cloud, offers the plans that have it.
Future<void> addToCloud(BuildContext context, String url) async {
  if (!await mayUseCloud(context, 'Follow it in ListenJar Cloud') || !context.mounted) return;
  await _guard(context, () async {
  final s = Services.of(context);
  final navigation = Navigation.of(context);
  tell(context, 'Adding it to ListenJar Cloud…');
  final feed = await s.feeds.add(url, CancellationToken().merge(TimeoutCancellationToken(const Duration(minutes: 2))));
  navigation.openFeed(feed.id);
  if (context.mounted) tell(context, '“${feed.title}” is now a ListenJar feed. Its episodes arrive as this device syncs them.');
  });
}

/// Whether the listener's plan has ListenJar Cloud (10 GB, 100 GB). On
/// Local it doesn't: offers the plans that have it, under [title]. Signed
/// out or free, callers have asked [mayFollowInCloud] and the like first.
Future<bool> mayUseCloud(BuildContext context, String title) async {
  final user = Services.of(context).account.user;
  if (hasCloud(user)) return true;
  await showPlans(context, title: title, cloud: true);
  return false;
}

/// Whether the listener may follow [what] (“Lex Fridman”, this YouTube
/// channel), on this device or in ListenJar Cloud: both take a plan. If they
/// can't, says why: signed out, offers to sign in; on the free plan, the
/// plans.
Future<bool> mayFollowInCloud(BuildContext context, String what) async {
  final user = Services.of(context).account.user;
  if (user == null) {
    await _askToSignIn(
      context,
      title: 'Follow $what',
      body: 'Single videos play here for free. Following a playlist or a channel takes a plan: '
        'on this device, its new videos stream here from YouTube; in ListenJar Cloud, '
        'they become a podcast for any podcast app. Sign in to pick one.',
    );
    return false;
  }
  if (!isPaid(user)) {
    await showPlans(context, title: 'Follow playlists and channels');
    return false;
  }
  return true;
}

/// Whether the listener may put a YouTube video in ListenJar Cloud, as a
/// podcast of its own or in one of theirs. If they can't, says why, as
/// [mayFollowInCloud] does.
Future<bool> mayAddVideoToCloud(BuildContext context) async {
  final user = Services.of(context).account.user;
  if (user == null) {
    await _askToSignIn(
      context,
      title: 'Make it a podcast with ListenJar Cloud',
      body: 'This video plays here for free, and Add to Library keeps it on this device. '
        'As a podcast, of its own or in one of yours, ListenJar keeps it in the cloud, '
        'for this app and any podcast app. That takes an account and a plan.',
    );
    return false;
  }
  return mayUseCloud(context, 'Make it a podcast with ListenJar Cloud');
}

/// Whether the listener may make a podcast of their own. If they can't,
/// says why, as [mayFollowInCloud] does.
Future<bool> mayMakePodcast(BuildContext context) async {
  final user = Services.of(context).account.user;
  if (user == null) {
    await _askToSignIn(
      context,
      title: 'Make a podcast of your own',
      body: 'Gather any YouTube videos into a podcast with your own name and artwork, '
        'on this device or in ListenJar Cloud for any podcast app. '
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

/// Makes the YouTube video at [url] a ListenJar podcast of its own.
Future<void> makeVideoPodcast(BuildContext context, String url) async {
  if (!await mayAddVideoToCloud(context) || !context.mounted) return;
  final feeds = Services.of(context).feeds;
  await _guard(context, () async {
    final feed = await feeds.add(url, CancellationToken().merge(TimeoutCancellationToken(const Duration(minutes: 2))));
    if (context.mounted) tell(context, '“${feed.title}” is now a ListenJar podcast. It uploads from this device.');
  });
}

/// A podcast of the listener's own: on this device, where its videos
/// stream from YouTube, or in ListenJar Cloud, which uploads them for any
/// podcast app. Where the videos they pick can go.
sealed class OwnPodcast {
  const OwnPodcast();

  /// Its id for [Navigation.openSearch]'s `into`.
  String get id;
  String get title;

  /// Where it is: this device or the Cloud.
  IconData get icon => switch (this) {
    LocalOwn() => Icons.laptop_mac_rounded,
    CloudOwn() => Icons.cloud_outlined,
  };
}

final class CloudOwn extends OwnPodcast {
  const CloudOwn(this.feed);
  final Feed feed;

  @override
  String get id => feed.id;
  @override
  String get title => feed.title;
}

final class LocalOwn extends OwnPodcast {
  const LocalOwn(this.show);
  final Podcast show;

  @override
  String get id => 'local:${show.id}';
  @override
  String get title => show.title;
}

/// The listener's podcasts of their own, those on this device first.
List<OwnPodcast> ownPodcasts(BuildContext context) {
  final s = Services.of(context);
  return [
    for (final p in s.library.podcasts) if (p.isOwn) LocalOwn(p),
    for (final f in s.feeds.own) CloudOwn(f),
  ];
}

/// The podcast of the listener's own whose [OwnPodcast.id] is [id].
OwnPodcast? ownPodcast(BuildContext context, String id) => ownPodcasts(context).where((o) => o.id == id).firstOrNull;

/// Makes a podcast of the listener's own, asking its name and whether it's
/// on this device or in ListenJar Cloud; null when they cancel or it fails,
/// which it says.
Future<OwnPodcast?> newOwnPodcast(BuildContext context) async {
  if (!await mayMakePodcast(context) || !context.mounted) return null;
  final asked = await askNewPodcast(context);
  if (asked == null || !context.mounted) return null;
  final s = Services.of(context);
  if (asked.cloud && !await mayUseCloud(context, 'Podcasts of your own in ListenJar Cloud')) return null;
  if (!context.mounted) return null;
  OwnPodcast? made;
  await _guard(context, () async {
    made = asked.cloud ? CloudOwn(await s.feeds.create(asked.title)) : LocalOwn(s.library.createOwn(asked.title));
  });
  return made;
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
  final target = own ?? await newOwnPodcast(context);
  if (target == null || !context.mounted) return null;
  // One of theirs in the Cloud from when the plan had it.
  if (target is CloudOwn && !await mayUseCloud(context, 'Add to “${target.title}” in ListenJar Cloud')) return null;
  if (!context.mounted) return null;
  final s = Services.of(context);
  final token = TimeoutCancellationToken(const Duration(minutes: 2));
  var added = false;
  await _guard(context, () async {
    switch (target) {
      case CloudOwn(:final feed):
        await s.feeds.addVideo(feed, link.url, token);
        if (context.mounted) tell(context, 'Added to “${feed.title}”. It uploads from this device.');
      case LocalOwn(:final show):
        final episode = await s.podcasts.addToOwn(show, link, token, title: title, duration: duration);
        if (context.mounted) tell(context, episode == null ? 'It’s already in “${show.title}”.' : 'Added to “${show.title}”.');
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

final class _Single extends _Where {
  const _Single();
}

/// On a paid plan: into one of the listener's own podcasts, or a podcast
/// of its own.
Future<_Where?> _askWhere(BuildContext context) {
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
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (final o in own) option(Icons.playlist_add_rounded, 'Add to “${o.title}”', null, _Own(o)),
            option(Icons.add_rounded, 'Add to a new podcast…', null, const _New()),
            option(
              Icons.podcasts_rounded,
              'Make it a podcast of its own',
              'One episode, as a ListenJar feed for any podcast app.',
              const _Single(),
            ),
          ]),
        ),
      ),
      actions: [
        TextButton(style: brand.button(brand.Tone.quiet, brand.ButtonSize.sm), onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      ],
    ),
  );
}
