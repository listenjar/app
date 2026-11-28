// Listenjar Cloud inside the one player: the signed-in listener's own
// Listenjar feeds (account.dart) and how each syncs from this device
// (feeds.dart, sync.dart) through the Listenjar API (public.yaml) and its
// oasmith client in lib/backend (`moon run app:codegen`). There is no
// Cloud section and no Cloud page: a feed is a show like any other, in the
// Library (library_page.dart) and on its show page (show_page.dart), which
// also says how its uploads go (hosted_feed.dart). Library makes podcasts
// of the listener's own, where the plan says; Search (search_page.dart)
// adds YouTube links and videos to them; Settings holds the account
// (AccountPanel).
import 'dart:async';

import 'package:cancellation_token/cancellation_token.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'account.dart';
import 'backend/api.dart';
import 'feeds.dart';
import 'menu.dart';
import 'net.dart';
import 'plans.dart';
import 'podcast_apps.dart';
import 'shared_links.dart' show newOwnPodcast;
import 'sign_in_form.dart';
import 'sync.dart';
import 'theme.dart' as brand;
import 'ui.dart' show Navigation, Services, tell;

/// Makes a podcast of the listener's own, named by them, and opens it to
/// fill from Search. Asks them to sign in or pick a plan first if they need
/// to.
Future<void> createPodcast(BuildContext context) async {
  final navigation = Navigation.of(context);
  final made = await newOwnPodcast(context);
  if (made?.feed case final feed?) navigation.openFeed(feed.id);
  if (made?.show case final show?) navigation.openShow(show.id);
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
      'Listenjar stops following it. Its episodes leave your podcast app, and their audio is deleted.',
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

/// The podcast apps this device can open feeds in, asked once.
final podcastApps = installedPodcastApps();

/// "Listen in", a group in a show's More menu: the podcast apps on this
/// device in [apps], then copying the link. Until the feed's first episode
/// is uploaded it has no RSS, so the group says it waits.
List<Widget> listenIn(BuildContext context, Feed feed, List<PodcastApp> apps) {
  Widget icon(String asset) => ClipRRect(
    borderRadius: BorderRadius.circular(5),
    child: Image.asset(asset, width: 18, height: 18, filterQuality: FilterQuality.medium),
  );
  final rss = feed.rssUrl;
  return [
    const MenuHeader('Listen in'),
    if (rss == null)
      const MenuEntry('Ready once the first episode is uploaded')
    else ...[
      for (final app in apps)
        MenuEntry(app.web ? '${app.title} (web)' : app.title, leading: icon(app.icon), onPressed: () => openInPodcastApp(app, rss)),
      MenuEntry('Copy feed link', leading: icon(podcastAppIcon('rss')), onPressed: () async {
        await Clipboard.setData(ClipboardData(text: rss));
        if (context.mounted) tell(context, 'Feed link copied. Add it to your podcast app as a podcast by URL.');
      }),
    ],
  ];
}

/// What syncing is doing with a feed, in a line, and whether it failed.
(String, bool) feedStatus(Feed feed, FeedSync? sync) {
  String episodes(int n) => n == 1 ? '1 episode' : '$n episodes';
  switch (sync) {
    case FeedSync(phase: FeedPhase.failed, error: PlanLimit(storageFull: true), :final waiting):
      return (waiting > 0 ? 'Storage full · $waiting waiting to upload' : 'Storage full', true);
    case FeedSync(phase: FeedPhase.failed, error: PlanLimit()):
      return ('Paused: takes a 10 GB or 100 GB plan', true);
    case FeedSync(phase: FeedPhase.failed, :final error) when unreachable(error):
      return ('Offline · syncs when you’re back online', false);
    case FeedSync(phase: FeedPhase.upToDate, :final elsewhere, episodes: final count) when elsewhere.isNotEmpty:
      return ([if (count > 0) episodes(count), '${elsewhere.length} uploading from another device'].join(' · '), false);
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
  FeedSync(phase: FeedPhase.failed, :final error) when unreachable(error) => ('Offline', false),
  FeedSync(phase: FeedPhase.failed) => ('Couldn’t sync', true),
  FeedSync(phase: FeedPhase.scanning) => ('Checking YouTube…', false),
  FeedSync(phase: FeedPhase.syncing, :final stage?, :final fraction?) => ('$stage ${(fraction * 100).floor()}%', false),
  FeedSync(phase: FeedPhase.syncing, :final queued) => ('Syncing · $queued to go', false),
  FeedSync(phase: FeedPhase.upToDate, :final elsewhere) when elsewhere.isNotEmpty => ('Uploading on another device', false),
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
            onPressed: () => manageBilling(context),
            child: Text('Move to ${bigger.name.replaceFirst('Listenjar ', '')}'),
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

/// Settings' Listenjar Cloud: how to sign in, while nobody is; then who is,
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
      if (limit != null) ...[
        const SizedBox(height: 4),
        Text('Only YouTube audio counts. Classic podcasts play from their publishers and don’t use your storage.', style: soft),
        const SizedBox(height: 4),
        Text('Your library, classic podcasts too, is the same on every device you sign in on.', style: soft),
      ],
      const SizedBox(height: 4),
      Text(s.feeds.summary, style: soft),
      const SizedBox(height: 18),
      Wrap(spacing: 8, runSpacing: 8, children: [
        if (user.plan == Plan.free)
          brand.accentShadow(
            enabled: true,
            child: TextButton(style: brand.button(brand.Tone.accent, brand.ButtonSize.sm), onPressed: _plans, child: const Text('See plans')),
          )
        else
          TextButton.icon(
            style: brand.button(brand.Tone.quiet, brand.ButtonSize.sm),
            onPressed: () => manageBilling(context),
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
        Text('Deleting your account deletes everything in Listenjar Cloud.', style: soft),
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
      if (account.signingIn == null) ...[
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
            onPressed: () => _plans('Listenjar Cloud plans'),
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
  if (context.mounted) tell(context, 'Your Listenjar account is deleted.');
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
        title: Text('Delete your Listenjar account?', style: text.titleLarge),
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
              point('your podcasts in Listenjar Cloud, their RSS feeds and audio, so podcast apps stop getting new episodes'),
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
/// their connection when the network failed, wait when Listenjar's server
/// did, and [other] otherwise.
String failure(String what, Object error, {required String other}) => switch (error) {
  CancelledException() => '$what. Check your connection, then try again.',
  _ when unreachable(error) => '$what. Check your connection, then try again.',
  ApiStatusException(:final statusCode) when statusCode >= 500 =>
    '$what. Something went wrong on our side, so try again in a minute.',
  _ => '$what. $other',
};
