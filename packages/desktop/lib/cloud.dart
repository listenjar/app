// ListenJar Cloud inside the one player: the signed-in listener's own
// ListenJar feeds (account.dart) and how each syncs from this device
// (feeds.dart, sync.dart) through the ListenJar API (public.yaml) and its
// oasmith client in lib/backend (`moon run desktop:codegen`). There is no
// Cloud section: the feeds are shows in the Library (library_page.dart),
// each with what its sync is doing, and one opens here (CloudShowPage) with
// its episodes, uploaded or on their way (podcast.dart). Library makes
// podcasts of the listener's own, on this device or here; Search
// (search_page.dart) adds YouTube links and videos to them; Settings holds
// the account (AccountPanel). A followed playlist or channel, or a podcast
// of the listener's own, moves between this device and here either way,
// and where the listener was in each video comes along.
import 'dart:async';
import 'dart:io';

import 'package:cancellation_token/cancellation_token.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';

import 'account.dart';
import 'backend/api.dart';
import 'feeds.dart';
import 'menu.dart';
import 'plans.dart';
import 'podcast.dart';
import 'podcast_apps.dart';
import 'podcasts.dart' show Podcasts;
import 'library.dart' show Podcast;
import 'links.dart' show parseYouTubeLink;
import 'shared_links.dart' show CloudOwn, LocalOwn, mayFollowInCloud, mayMakePodcast, mayUseCloud, newOwnPodcast;
import 'shell.dart' show PageBody, backButton;
import 'sign_in_form.dart';
import 'sync.dart';
import 'theme.dart' as brand;
import 'ui.dart' show Navigation, Services, tell;

/// One ListenJar feed, pushed onto a section's stack: what went wrong
/// syncing, then its page (podcast.dart). Gone once it is removed.
final class CloudShowPage extends StatelessWidget {
  const CloudShowPage({super.key, required this.feedId});
  final String feedId;

  @override
  Widget build(BuildContext context) {
    final s = Services.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([s.feeds, s.account]),
      builder: (context, _) {
        final feed = s.feeds.feeds.where((f) => f.id == feedId).firstOrNull;
        if (feed == null) {
          return PageBody(children: [
            if (Navigator.of(context).canPop()) backButton(context, 'Back'),
            Text('This podcast is gone', style: Theme.of(context).textTheme.titleLarge),
          ]);
        }
        return PageBody(children: [
          if (Navigator.of(context).canPop()) backButton(context, 'Back'),
          if (s.feeds.storageFull) ...[const StorageFullNotice(), const SizedBox(height: 20)],
          PodcastPage(
            key: ValueKey(feed.id),
            feed: feed,
            feeds: s.feeds,
            onRemove: () => unawaited(removeCloudFeed(context, feed)),
          ),
        ]);
      },
    );
  }
}

/// Makes a podcast of the listener's own, named by them, on this device or
/// in ListenJar Cloud, and opens it to fill from Search. Asks them to sign
/// in or pick a plan first if they need to.
Future<void> createPodcast(BuildContext context) async {
  final navigation = Navigation.of(context);
  switch (await newOwnPodcast(context)) {
    case CloudOwn(:final feed):
      navigation.openFeed(feed.id);
    case LocalOwn(:final show):
      navigation.openShow(show.id);
    case null:
  }
}

/// What removing [feed] does, in its own terms: what leaves the podcast
/// app, and that its audio goes. Audio is shared, so when another feed of
/// the listener's may have the same videos, it says those keep theirs.
String _removeConsequence(Feeds feeds, Feed feed) {
  final shared = feeds.feeds.any((f) => f.id != feed.id);
  return switch (feed.source?.kind) {
    SourceKind.video => [
      'It leaves your podcast app, and its audio is deleted.',
      if (shared) 'If another podcast of yours has this video, it stays there.',
    ],
    SourceKind.playlist || SourceKind.channel => [
      'ListenJar stops following it. Its episodes leave your podcast app, and their audio is deleted.',
      if (shared) 'Videos another podcast of yours also has stay there.',
    ],
    null => [
      'Its episodes leave your podcast app, and their audio is deleted.',
      if (shared) 'Videos another podcast of yours also has stay there.',
    ],
  }.join(' ');
}

/// Asks, then removes the feed and everything uploaded to it, and leaves
/// its page.
Future<void> removeCloudFeed(BuildContext context, Feed feed) async {
  final feeds = Services.of(context).feeds;
  final text = Theme.of(context).textTheme;
  final sure = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: brand.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(brand.radiusSheet)),
      title: Text('Remove “${feed.title}”?', style: text.titleLarge),
      content: Text(_removeConsequence(feeds, feed), style: text.bodyMedium!.copyWith(color: brand.fgSoft)),
      actions: [
        TextButton(
          style: brand.button(brand.Tone.quiet, brand.ButtonSize.sm),
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Keep it'),
        ),
        TextButton(
          style: brand.button(brand.Tone.ink, brand.ButtonSize.sm),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Remove'),
        ),
      ],
    ),
  );
  if (sure != true || !context.mounted) return;
  final navigator = Navigator.of(context);
  try {
    await feeds.remove(feed);
    if (navigator.canPop()) navigator.pop();
  } catch (e) {
    if (context.mounted) tell(context, failure('Couldn’t remove it', e, other: 'Try again.'));
  }
}

/// Asks, then moves [show], a YouTube playlist or channel followed on this
/// device or a podcast of the listener's own there, to ListenJar Cloud:
/// this device uploads its videos, for any podcast app. Where the listener
/// was comes along as the uploads arrive.
Future<void> moveToCloud(BuildContext context, Podcast show) async {
  final own = show.isOwn;
  if (!own && parseYouTubeLink(show.feedUrl) == null) return;
  final may = own ? await mayMakePodcast(context) : await mayFollowInCloud(context, '“${show.title}”');
  if (!may || !context.mounted) return;
  if (!await mayUseCloud(context, 'Move “${show.title}” to ListenJar Cloud') || !context.mounted) return;
  final sure = await _confirm(
    context,
    title: 'Move “${show.title}” to ListenJar Cloud?',
    body: [
      own
        ? 'This device fetches each of its videos from YouTube and uploads it, so it plays in any podcast app.'
        : 'This device fetches every video from YouTube and uploads it, so it plays in any podcast app.',
      'It uses your plan’s storage. Where you are in each video comes along.',
    ].join(' '),
    action: 'Move to Cloud',
  );
  if (!sure || !context.mounted) return;
  final s = Services.of(context);
  final navigation = Navigation.of(context);
  final navigator = Navigator.of(context);
  try {
    tell(context, 'Moving it to ListenJar Cloud…');
    final feed = own ? await ownToCloud(s.feeds, s.podcasts, show) : await showToCloud(s.feeds, s.podcasts, show);
    if (navigator.canPop()) navigator.pop();
    navigation.openFeed(feed.id);
  } on PlanLimit {
    if (context.mounted) await showPlans(context, title: 'Your storage is full', cloud: true);
  } catch (e) {
    if (context.mounted) tell(context, failure('Couldn’t move it', e, other: 'Try again.'));
  }
}

/// Asks, then moves [feed], a YouTube playlist or channel or a podcast of
/// the listener's own in ListenJar Cloud, to this device: it streams here
/// from YouTube, and the feed and its uploads are deleted. Where the
/// listener was comes along.
Future<void> moveToDevice(BuildContext context, Feed feed) async {
  final own = feed.source == null;
  if (!own && parseYouTubeLink(feed.source?.url ?? '') == null) return;
  final sure = await _confirm(
    context,
    title: 'Move “${feed.title}” to this device?',
    body: [
      'Here its videos stream from YouTube as you play them, and only this app has it.',
      own
        ? 'It leaves your other podcast apps, and its audio is deleted from the cloud.'
        : 'ListenJar stops following it: it leaves your other podcast apps, and its audio is deleted from the cloud.',
      'Where you are in each episode comes along.',
    ].join(' '),
    action: 'Move to this device',
  );
  if (!sure || !context.mounted) return;
  final s = Services.of(context);
  final navigation = Navigation.of(context);
  final navigator = Navigator.of(context);
  try {
    tell(context, own ? 'Moving it to this device…' : 'Listing its videos…');
    final show = own ? await ownToDevice(s.feeds, s.podcasts, feed) : await feedToDevice(s.feeds, s.podcasts, feed);
    if (navigator.canPop()) navigator.pop();
    navigation.openShow(show.id);
  } catch (e) {
    if (context.mounted) tell(context, failure('Couldn’t move it', e, other: 'Try again.'));
  }
}

/// [show], a YouTube playlist or channel on this device, as a ListenJar
/// Cloud feed: where the listener was is carried to it, and the show here
/// goes.
Future<Feed> showToCloud(Feeds feeds, Podcasts podcasts, Podcast show) async {
  final feed = await feeds.add(show.feedUrl, CancellationToken().merge(TimeoutCancellationToken(const Duration(minutes: 2))));
  podcasts.library.carry(show.id, feed.id);
  await podcasts.unfollow(show);
  return feed;
}

/// [feed], a YouTube playlist or channel in ListenJar Cloud, followed on
/// this device instead: where the listener was comes along, and the feed
/// and its uploads are removed.
Future<Podcast> feedToDevice(Feeds feeds, Podcasts podcasts, Feed feed) async {
  final link = parseYouTubeLink(feed.source?.url ?? '') ?? (throw StateError('Not a YouTube playlist or channel'));
  final show = await podcasts.followYouTube(link, TimeoutCancellationToken(const Duration(minutes: 3)));
  final library = podcasts.library;
  // What was carried to the Cloud and hasn't arrived there yet, then the
  // Cloud show's own.
  library.applyCarried(show.id, feed.id);
  if (library.podcasts.where((p) => p.cloudFeedId == feed.id).firstOrNull case final cloud?) {
    library.copyListening(cloud.id, show.id);
  }
  // Still in the Cloud: the show here goes, or it would be there twice.
  try {
    await feeds.remove(feed);
  } catch (_) {
    await podcasts.unfollow(show);
    rethrow;
  }
  return show;
}

/// [show], a podcast of the listener's own on this device, as one in
/// ListenJar Cloud: its artwork and videos, oldest first so they list in
/// the same order; where the listener was is carried to it, and the show
/// here goes. If a video can't be added, the Cloud one goes instead.
Future<Feed> ownToCloud(Feeds feeds, Podcasts podcasts, Podcast show) async {
  final library = podcasts.library;
  final videos = [for (final e in library.episodes(show.id, oldestFirst: true)) ?e.videoId];
  final feed = await feeds.create(show.title);
  try {
    if (await podcasts.artworkBytes(show.artworkUrl) case final picture?) await feeds.setArtwork(feed, picture);
    for (final id in videos) {
      await feeds.addVideo(feed, 'https://www.youtube.com/watch?v=$id', TimeoutCancellationToken(const Duration(minutes: 2)));
    }
  } catch (_) {
    await feeds.remove(feed).catchError((_) {});
    rethrow;
  }
  library.carry(show.id, feed.id);
  await podcasts.unfollow(show);
  return feeds.feeds.where((f) => f.id == feed.id).firstOrNull ?? feed;
}

/// [feed], a podcast of the listener's own in ListenJar Cloud, as one on
/// this device: its artwork and videos, dated when they were added there;
/// where the listener was comes along, and the feed and its uploads are
/// removed. Until they are, nothing here waits on the network, so the show
/// is never in both places for long.
Future<Podcast> ownToDevice(Feeds feeds, Podcasts podcasts, Feed feed) async {
  final episodes = (await feeds.episodes(feed))..sort((a, b) => a.publishedAt.compareTo(b.publishedAt));
  // Fetched now: removing the feed removes its artwork too.
  final picture = await podcasts.artworkBytes(feed.imageUrl);
  final library = podcasts.library;
  final show = library.createOwn(feed.title);
  for (final e in episodes) {
    library.addOwnVideo(
      show.id,
      videoId: e.videoId,
      title: e.title,
      duration: switch (e.durationSeconds) {
        final s? => Duration(seconds: s),
        null => null,
      },
      addedAt: DateTime.tryParse(e.publishedAt),
    );
  }
  library.applyCarried(show.id, feed.id);
  if (library.podcasts.where((p) => p.cloudFeedId == feed.id).firstOrNull case final cloud?) {
    library.copyListening(cloud.id, show.id);
  }
  // Still in the Cloud: the show here goes, or it would be there twice.
  try {
    await feeds.remove(feed);
  } catch (_) {
    await podcasts.unfollow(show);
    rethrow;
  }
  // Moved; a picture that won't come along doesn't undo that.
  if (picture != null) {
    try {
      await podcasts.setOwnArtwork(show, picture);
    } catch (_) {}
  }
  return library.podcast(show.id)!;
}

Future<bool> _confirm(BuildContext context, {required String title, required String body, required String action}) async {
  final text = Theme.of(context).textTheme;
  final sure = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: brand.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(brand.radiusSheet)),
      title: Text(title, style: text.titleLarge),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Text(body, style: text.bodyMedium!.copyWith(color: brand.fgSoft)),
      ),
      actions: [
        TextButton(
          style: brand.button(brand.Tone.quiet, brand.ButtonSize.sm),
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          style: brand.button(brand.Tone.accent, brand.ButtonSize.sm),
          onPressed: () => Navigator.pop(context, true),
          child: Text(action),
        ),
      ],
    ),
  );
  return sure ?? false;
}

/// "Listen in…": the podcast apps on this device, then copying the link.
/// Until the feed's first episode is uploaded it has no RSS, so the button
/// waits, disabled, while the page shows the sync.
final class ListenIn extends StatefulWidget {
  const ListenIn({super.key, required this.feed});
  final Feed feed;

  @override
  State<ListenIn> createState() => _ListenInState();
}

final class _ListenInState extends State<ListenIn> {
  /// The podcast apps this device can open feeds in, asked once.
  static final _podcastApps = installedPodcastApps();

  Future<void> _copyFeedLink(String url) async {
    await Clipboard.setData(ClipboardData(text: url));
    if (mounted) tell(context, 'Feed link copied. Add it to your podcast app as a podcast by URL.');
  }

  Widget _menuIcon(String asset) => ClipRRect(
    borderRadius: BorderRadius.circular(5),
    child: Image.asset(asset, width: 22, height: 22, filterQuality: FilterQuality.medium),
  );

  @override
  Widget build(BuildContext context) {
    final rss = widget.feed.rssUrl;
    if (rss == null) {
      return Tooltip(
        message: 'Ready once the first episode is uploaded',
        child: TextButton(
          style: brand.button(brand.Tone.quiet, brand.ButtonSize.sm),
          onPressed: null,
          child: const Text('Listen in…'),
        ),
      );
    }
    return FutureBuilder(
      future: _podcastApps,
      builder: (context, snapshot) => Dropdown(
        items: [
          for (final app in snapshot.data ?? const <PodcastApp>[])
            MenuEntry(
              app.web ? '${app.title} (web)' : app.title,
              leading: _menuIcon(app.icon),
              onPressed: () => openInPodcastApp(app, rss),
            ),
          if (snapshot.data?.isNotEmpty ?? false) const MenuDivider(),
          MenuEntry('Copy feed link', leading: _menuIcon(podcastAppIcon('rss')), onPressed: () => _copyFeedLink(rss)),
        ],
        builder: (context, menu) => TextButton(
          style: brand.button(brand.Tone.quiet, brand.ButtonSize.sm),
          onPressed: menu.toggle,
          child: const Text('Listen in…'),
        ),
      ),
    );
  }
}

/// What syncing is doing with a feed, in a line, and whether it failed.
(String, bool) feedStatus(Feed feed, FeedSync? sync) {
  String episodes(int n) => n == 1 ? '1 episode' : '$n episodes';
  switch (sync) {
    case FeedSync(phase: FeedPhase.failed, error: PlanLimit(storageFull: true), :final waiting):
      return (waiting > 0 ? 'Storage full · $waiting waiting to upload' : 'Storage full', true);
    case FeedSync(phase: FeedPhase.failed, error: PlanLimit()):
      return ('Paused: takes a 10 GB or 100 GB plan', true);
    case FeedSync(phase: FeedPhase.upToDate, episodes: 0) when feed.source == null:
      return ('No episodes yet', false);
  }
  return switch (sync?.phase) {
    null || FeedPhase.waiting => ('Waiting to sync', false),
    FeedPhase.scanning => ('Checking YouTube…', false),
    FeedPhase.syncing => (
      [
        if (sync!.current case final title?)
          '${sync.stage ?? 'Syncing'} “$title”${sync.fraction == null ? '' : ' ${(sync.fraction! * 100).floor()}%'}',
        '${sync.queued} to go',
      ].join(' · '),
      false,
    ),
    FeedPhase.upToDate => (
      [
        episodes(sync!.episodes),
        'up to date',
        if (sync.skipped > 0) '${sync.skipped} unavailable',
      ].join(' · '),
      false,
    ),
    FeedPhase.failed => ('Couldn’t sync: ${sync!.error}', true),
  };
}

/// A feed's sync, short enough for a Library tile; null when there is
/// nothing to say, so the tile says who makes the show.
(String, bool)? feedTileStatus(Feed feed, FeedSync? sync, {required bool playable}) => switch (sync) {
  FeedSync(phase: FeedPhase.failed, error: PlanLimit(storageFull: true)) => ('Storage full', true),
  FeedSync(phase: FeedPhase.failed, error: PlanLimit()) => ('Paused: takes a 10 GB or 100 GB plan', true),
  FeedSync(phase: FeedPhase.failed) => ('Couldn’t sync', true),
  FeedSync(phase: FeedPhase.scanning) => ('Checking YouTube…', false),
  FeedSync(phase: FeedPhase.syncing, :final stage?, :final fraction?) => ('$stage ${(fraction * 100).floor()}%', false),
  FeedSync(phase: FeedPhase.syncing, :final queued) => ('Syncing · $queued to go', false),
  FeedSync(phase: FeedPhase.upToDate, episodes: 0) => ('No episodes yet', false),
  _ when !playable => ('Waiting to sync', false),
  _ => null,
};

/// The plan's storage is full and episodes wait: make room, or move to a
/// bigger plan.
final class StorageFullNotice extends StatelessWidget {
  const StorageFullNotice({super.key});

  @override
  Widget build(BuildContext context) {
    final s = Services.of(context);
    final user = s.account.user;
    if (user == null) return const SizedBox.shrink();
    final waiting = s.feeds.waitingForRoom;
    final bigger = biggerPlan(user);
    return Notice(
      danger: true,
      title: switch (user.storageLimitBytes) {
        final limit? => 'Your ${formatBytes(limit)} is full',
        null => 'Your storage is full',
      },
      body: [
        if (waiting > 0) waiting == 1 ? '1 episode is waiting to upload.' : '$waiting episodes are waiting to upload.',
        'Remove podcasts or episodes you’ve heard${bigger == null ? '' : ', or move to a bigger plan'}, and they upload by themselves.',
      ].join(' '),
      actions: [
        if (bigger != null)
          TextButton(
            style: brand.button(brand.Tone.quiet, brand.ButtonSize.sm),
            onPressed: () => openInBrowser(context, billingUrl),
            child: Text('Move to ${bigger.name.replaceFirst('ListenJar ', '')}'),
          ),
        TextButton(
          style: brand.button(brand.Tone.ink, brand.ButtonSize.sm),
          onPressed: () => unawaited(showMakeRoom(
            context,
            account: s.account,
            feeds: s.feeds,
            onRemove: (feed) => removeCloudFeed(context, feed),
          )),
          child: const Text('Make room'),
        ),
      ],
    );
  }
}

/// Settings' ListenJar Cloud: how to sign in, while nobody is; then who is,
/// their plan and storage, syncing now, signing out and deleting the
/// account ([deleteAccount]).
final class AccountPanel extends StatefulWidget {
  const AccountPanel({super.key});

  @override
  State<AccountPanel> createState() => _AccountPanelState();
}

final class _AccountPanelState extends State<AccountPanel> {
  void _plans([String title = 'Keep what you add']) => unawaited(showPlans(context, title: title));

  @override
  Widget build(BuildContext context) {
    final s = Services.of(context);
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: Listenable.merge([s.account, s.feeds]),
      builder: (context, _) => brand.panel(
        padding: 24,
        child: switch (s.account.user) {
          null => _signIn(text, s.account),
          final user => _signedIn(text, s, user),
        },
      ),
    );
  }

  Widget _signedIn(TextTheme text, Services s, User user) {
    final soft = text.bodySmall!.copyWith(color: brand.fgSoft);
    final limit = user.storageLimitBytes;
    final used = user.storageUsedBytes ?? 0;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        _avatar(text, user),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(user.name.isEmpty ? user.email : user.name, style: text.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
            if (user.name.isNotEmpty) Text(user.email, style: soft, maxLines: 1, overflow: TextOverflow.ellipsis),
          ]),
        ),
      ]),
      const SizedBox(height: 20),
      Text(planName(user), style: text.titleMedium!.copyWith(fontSize: 15)),
      const SizedBox(height: 6),
      if (user.plan == Plan.free)
        Text('Single videos, each removed about a day after you add it', style: soft)
      else
        Row(children: [
          if (limit != null) ...[StorageMeter(used: used, limit: limit), const SizedBox(width: 10)],
          Flexible(
            child: Text(
              limit == null ? 'Playlists, channels and podcasts of your own, on this device' : '${formatBytes(used)} of ${formatBytes(limit)} used',
              style: soft.copyWith(
                color: used >= (limit ?? 1 << 62) ? brand.danger : brand.fgSoft,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ]),
      const SizedBox(height: 4),
      Text(s.feeds.summary, style: soft),
      const SizedBox(height: 18),
      Wrap(spacing: 8, runSpacing: 8, children: [
        if (sellsPlans && user.plan == Plan.free)
          brand.accentShadow(
            enabled: true,
            child: TextButton(style: brand.button(brand.Tone.accent, brand.ButtonSize.sm), onPressed: _plans, child: const Text('See plans')),
          )
        else if (sellsPlans)
          TextButton.icon(
            style: brand.button(brand.Tone.quiet, brand.ButtonSize.sm),
            onPressed: () => openInBrowser(context, billingUrl),
            icon: const Icon(Icons.open_in_new_rounded, size: 16),
            label: const Text('Manage plan'),
          ),
        TextButton.icon(
          style: brand.button(brand.Tone.quiet, brand.ButtonSize.sm),
          onPressed: s.feeds.loading ? null : s.feeds.syncNow,
          icon: const Icon(Icons.sync_rounded, size: 16),
          label: const Text('Sync now'),
        ),
        TextButton(
          style: brand.button(brand.Tone.quiet, brand.ButtonSize.sm),
          onPressed: s.account.signOut,
          child: const Text('Sign out'),
        ),
      ]),
      const SizedBox(height: 20),
      const Divider(color: brand.line, height: 1),
      const SizedBox(height: 12),
      Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 12, runSpacing: 4, children: [
        Text('Deleting your account deletes everything in ListenJar Cloud.', style: soft),
        TextButton.icon(
          style: _dangerQuiet,
          onPressed: () => unawaited(deleteAccount(context)),
          icon: const Icon(Icons.delete_outline_rounded, size: 16),
          label: const Text('Delete account…'),
        ),
      ]),
    ]);
  }

  /// The Google account's picture, or the listener's initial without one.
  Widget _avatar(TextTheme text, User user) {
    const size = 40.0;
    final name = user.name.isEmpty ? user.email : user.name;
    final initial = Container(
      alignment: Alignment.center,
      color: brand.accent,
      child: Text(
        name.isEmpty ? '?' : name.characters.first.toUpperCase(),
        style: text.labelLarge!.copyWith(color: brand.white, height: 1),
      ),
    );
    return Container(
      width: size,
      height: size,
      foregroundDecoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: brand.line)),
      child: ClipOval(
        child: switch (user.pictureUrl) {
          null => initial,
          final url => Image.network(
            url,
            fit: BoxFit.cover,
            cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).round(),
            errorBuilder: (_, _, _) => initial,
            frameBuilder: (_, child, frame, sync) => sync || frame != null ? child : initial,
          ),
        },
      ),
    );
  }

  Widget _signIn(TextTheme text, Account account) {
    if (account.restoring) return Text('Signing in…', style: text.titleMedium);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SignInForm(account: account, describe: (error) => failure('Couldn’t sign in', error, other: 'Try again.')),
      if (account.signingIn == null && sellsPlans) ...[
        const SizedBox(height: 20),
        const Divider(color: brand.line, height: 1),
        const SizedBox(height: 16),
        Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 12, runSpacing: 8, children: [
          Text(
            'This device fetches videos from YouTube and uploads them; the plans pay for the storage.',
            style: text.bodySmall!.copyWith(color: brand.fgSoft),
          ),
          TextButton(
            style: brand.button(brand.Tone.quiet, brand.ButtonSize.sm),
            onPressed: () => _plans('ListenJar Cloud plans'),
            child: const Text('See plans'),
          ),
        ]),
      ],
    ]);
  }
}

/// A quiet button whose action can't be undone.
final _dangerQuiet = brand.button(brand.Tone.quiet, brand.ButtonSize.sm).copyWith(
  backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
  foregroundColor: const WidgetStatePropertyAll(brand.danger),
  overlayColor: const WidgetStatePropertyAll(Color(0xFFFBECEB)),
);

/// The confirming button of [deleteAccount]'s question: the danger colour,
/// a step darker on hover.
final _dangerSolid = brand.button(brand.Tone.ink, brand.ButtonSize.sm).copyWith(
  backgroundColor: WidgetStateProperty.resolveWith(
    (states) => switch (states) {
      _ when states.contains(WidgetState.disabled) => brand.danger.withValues(alpha: 0.6),
      _ when states.contains(WidgetState.hovered) => const Color(0xFFBD3B33),
      _ => brand.danger,
    },
  ),
  foregroundColor: const WidgetStatePropertyAll(brand.white),
);

/// Asks, saying what goes with the account, then deletes it (account.dart):
/// the server cancels the plan and deletes the feeds, their audio and
/// artwork, and every way in. Then this device forgets the Cloud shows and
/// what their sync kept, and is signed out. Nothing on this device that
/// isn't the account's (shows followed here, downloads, Up Next) changes.
Future<void> deleteAccount(BuildContext context) async {
  final s = Services.of(context);
  final user = s.account.user;
  if (user == null) return;
  final deleted = await showDialog<bool>(
    context: context,
    builder: (context) => _DeleteAccountDialog(account: s.account, user: user),
  );
  if (deleted != true) return;
  await s.feeds.forgetDeleted();
  await s.podcasts.forgetCloud();
  if (context.mounted) tell(context, 'Your ListenJar account is deleted.');
}

final class _DeleteAccountDialog extends StatefulWidget {
  const _DeleteAccountDialog({required this.account, required this.user});
  final Account account;
  final User user;

  @override
  State<_DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

final class _DeleteAccountDialogState extends State<_DeleteAccountDialog> {
  bool _deleting = false;
  String? _error;

  Future<void> _delete() async {
    setState(() {
      _deleting = true;
      _error = null;
    });
    try {
      await widget.account.deleteAccount();
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _deleting = false;
        _error = failure('Your account wasn’t deleted', e, other: 'Nothing was lost. Try again.');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final body = text.bodyMedium!;
    final soft = body.copyWith(color: brand.fgSoft);
    Widget point(String line) => Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.only(top: 8, right: 10),
          child: Container(width: 5, height: 5, decoration: const BoxDecoration(color: brand.danger, shape: BoxShape.circle)),
        ),
        Expanded(child: Text(line, style: soft)),
      ]),
    );
    return PopScope(
      canPop: !_deleting,
      child: AlertDialog(
        backgroundColor: brand.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(brand.radiusSheet)),
        title: Text('Delete your ListenJar account?', style: text.titleLarge),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text.rich(
                TextSpan(children: [
                  TextSpan(text: widget.user.email, style: body.copyWith(fontWeight: FontWeight.w600)),
                  const TextSpan(text: ' and everything in it go for good:'),
                ]),
                style: body,
              ),
              const SizedBox(height: 4),
              point('your podcasts in ListenJar Cloud, their RSS feeds and audio, so podcast apps stop getting new episodes'),
              point('your artwork, passkeys, password and connected Google'),
              point('your sign-in on every device, the website’s too'),
              if (widget.user.plan == Plan.paid) ...[
                const SizedBox(height: 12),
                Text('Your plan is cancelled now, with no refund for the time left.', style: body),
              ],
              const SizedBox(height: 12),
              Text(
                'Shows you follow on this device, your downloads and Up Next stay. This can’t be undone.',
                style: body.copyWith(fontWeight: FontWeight.w600),
              ),
              if (_error case final error?) ...[
                const SizedBox(height: 14),
                Text(error, style: body.copyWith(color: brand.danger)),
              ],
            ]),
          ),
        ),
        actions: [
          TextButton(
            style: brand.button(brand.Tone.quiet, brand.ButtonSize.sm),
            onPressed: _deleting ? null : () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: _dangerSolid,
            onPressed: _deleting ? null : _delete,
            child: Text(_deleting ? 'Deleting…' : 'Delete account'),
          ),
        ],
      ),
    );
  }
}

/// What failed, said as [what], and what the listener can do about it: check
/// their connection when the network failed, wait when ListenJar's server
/// did, and [other] otherwise.
String failure(String what, Object error, {required String other}) => switch (error) {
  SocketException() || HttpException() || TimeoutException() || CancelledException() || http.ClientException() =>
    '$what. Check your connection, then try again.',
  ApiStatusException(:final statusCode) when statusCode >= 500 =>
    '$what. Something went wrong on our side, so try again in a minute.',
  _ => '$what. $other',
};
