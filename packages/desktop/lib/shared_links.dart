// Links shared to ListenJar from other apps, and what it does with them.
//
// They arrive on the `listenjar/links` channel from each platform's runner:
// Android's share sheet (MainActivity.kt), a `<scheme>://open?url=…` link on
// every platform, and a second launch with the link as its argument (Linux,
// Windows). A first launch on Linux and Windows passes it to main().
//
// A YouTube channel or playlist becomes a ListenJar Cloud feed, which takes
// a paid plan. A YouTube video becomes a podcast of a single episode in the
// library, free; on a paid plan the listener may add it to a podcast of
// their own in the Cloud instead. Any other link goes to search, which knows
// podcast feeds.
import 'dart:async';

import 'package:cancellation_token/cancellation_token.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'backend/api.dart' show Feed, Plan, SourceKind;
import 'config.dart' show appScheme;
import 'links.dart';
import 'log.dart';
import 'plans.dart' show askPodcastTitle, showPlans;
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
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'open' && call.arguments is String) _take(call.arguments as String);
    });
    // Links the runner held until this side listened.
    unawaited(_channel.invokeListMethod<String>('pending').then(
      (links) => links?.forEach(_take),
      onError: (Object _) {}, // No runner side on this platform.
    ));
  }

  static const _channel = MethodChannel('listenjar/links');
  final _waiting = <Uri>[];

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
    if (!await mayFollowInCloud(context, 'this ${kindLabel(youtube.kind)}')) return;
    if (!context.mounted) return;
    await addToCloud(context, youtube.url);
    return;
  }
  final user = s.account.user;
  if (user != null && user.plan != Plan.free) {
    final choice = await _askWhere(context);
    if (choice == null || !context.mounted) return;
    if (choice case _Own(:final feed)) {
      await _guard(context, () async {
        await s.feeds.addVideo(feed, youtube.url, CancellationToken());
        if (context.mounted) tell(context, 'Added to “${feed.title}”. It arrives as this device syncs it.');
      });
      return;
    }
    await addToCloud(context, youtube.url);
    return;
  }
  await _guard(context, () async {
    final episode = await s.podcasts.youtubeVideo(youtube, CancellationToken(), follow: true);
    navigation.openShow(episode.podcastId);
    if (context.mounted) tell(context, 'Added “${episode.title}” to your library.');
  });
}

/// Adds [url] to ListenJar Cloud as a feed of its own, and shows it there.
Future<void> addToCloud(BuildContext context, String url) => _guard(context, () async {
  final s = Services.of(context);
  final navigation = Navigation.of(context);
  tell(context, 'Adding it to ListenJar Cloud…');
  final feed = await s.feeds.add(url, CancellationToken().merge(TimeoutCancellationToken(const Duration(minutes: 2))));
  navigation.openCloud();
  if (context.mounted) tell(context, '“${feed.title}” is now a ListenJar feed. Its episodes arrive as this device syncs them.');
});

/// Whether the listener may follow [what] (“Lex Fridman”, this YouTube
/// channel) in ListenJar Cloud. If they
/// can't, says why: signed out, offers to sign in; on the free plan, the
/// plans.
Future<bool> mayFollowInCloud(BuildContext context, String what) async {
  final user = Services.of(context).account.user;
  if (user == null) {
    await _askToSignIn(
      context,
      title: 'Follow $what with ListenJar Cloud',
      body: 'Single videos play here for free. Following a playlist or a channel makes it a podcast: '
        'ListenJar keeps its new videos as episodes in the cloud, for this app and any podcast app. '
        'That takes an account and a plan.',
    );
    return false;
  }
  if (user.plan == Plan.free) {
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
  if (user.plan == Plan.free) {
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

/// Adds the YouTube video at [url] to [feed], a podcast of the listener's
/// own, or, when [feed] is null, to a new one they name.
Future<void> addVideoToOwnPodcast(BuildContext context, String url, Feed? feed) async {
  if (!await mayAddVideoToCloud(context) || !context.mounted) return;
  final feeds = Services.of(context).feeds;
  final title = feed == null ? await askPodcastTitle(context) : null;
  if ((feed == null && title == null) || !context.mounted) return;
  await _guard(context, () async {
    final target = feed ?? await feeds.create(title!);
    await feeds.addVideo(target, url, CancellationToken());
    if (context.mounted) tell(context, 'Added to “${target.title}”. It uploads from this device.');
  });
}

Future<void> _guard(BuildContext context, Future<void> Function() action) async {
  try {
    await action();
  } on PlanLimit {
    if (context.mounted) await showPlans(context, title: 'Your storage is full');
  } catch (e, stack) {
    _log.warning('Couldn’t add a shared link', e, stack);
    if (context.mounted) tell(context, 'Couldn’t add that: $e');
  }
}

/// Offers to sign in; yes closes Now Playing, if it's open, for the Cloud.
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
  if (go != true) return;
  root.popUntil((route) => route.isFirst);
  navigation.openCloud();
}

sealed class _Where {
  const _Where();
}

final class _Own extends _Where {
  const _Own(this.feed);
  final Feed feed;
}

final class _Single extends _Where {
  const _Single();
}

/// On a paid plan: into one of the listener's own podcasts, or a podcast
/// of its own.
Future<_Where?> _askWhere(BuildContext context) {
  final s = Services.of(context);
  final text = Theme.of(context).textTheme;
  final own = s.feeds.own;
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
            for (final feed in own) option(Icons.playlist_add_rounded, 'Add to “${feed.title}”', null, _Own(feed)),
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
