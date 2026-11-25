// A show, on its sleeve (sleeve.dart): its artwork, who makes it and what
// it's about, play, Follow, and every episode, newest first, filtered to the unplayed or the downloaded and
// searchable by title and show notes. Opened
// from the library, search or an episode; a show looked at from search is
// in the library unfollowed until the listener follows it. A podcast of the
// listener's own is filled from Search instead. Every show opens here,
// whatever the plan: on one with ListenJar Cloud, a YouTube playlist,
// channel or podcast of the listener's own is a classic podcast ListenJar
// hosts, and its page also says how its uploads go (hosted_feed.dart). One
// with nothing uploaded yet isn't in the library, and opens by its feed.
import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import 'artwork.dart' show UnreadablePicture, artworkExtensions;
import 'backend/api.dart' show Feed, Plan, SourceKind;
import 'cloud.dart' show ListenIn, StorageFullNotice, failure, removeCloudFeed;
import 'hosted_feed.dart';
import 'library.dart';
import 'menu.dart';
import 'net.dart';
import 'plans.dart' show showPlans;
import 'shared_links.dart' show OwnPodcast;
import 'sync.dart' show PlanLimit;
import 'shell.dart';
import 'sleeve.dart';
import 'theme.dart' as brand;
import 'ui.dart';

final class ShowPage extends StatefulWidget {
  const ShowPage({super.key, required int this.podcastId}) : feedId = null;

  /// A ListenJar feed with nothing uploaded yet, so no show in the library:
  /// its page, which becomes the show's once the first upload lands.
  const ShowPage.feed({super.key, required String this.feedId}) : podcastId = null;

  final int? podcastId;
  final String? feedId;

  @override
  State<ShowPage> createState() => _ShowPageState();
}

final class _ShowPageState extends State<ShowPage> {
  EpisodeFilter _filter = EpisodeFilter.all;
  bool _oldestFirst = false;
  bool _aboutOpen = false;
  final _query = TextEditingController();
  final _queryFocus = FocusNode();

  /// Long back catalogues show this many at first.
  static const _page = 100;
  int _shown = _page;

  /// The show's ListenJar feed's episodes, while it has one.
  FeedEpisodes? _hosted;

  FeedEpisodes? _hostedFor(Feed? feed) {
    if (feed?.id == _hosted?.feedId) return _hosted;
    _hosted?.dispose();
    final s = Services.of(context);
    _hosted = feed == null ? null : (FeedEpisodes(feedId: feed.id, feeds: s.feeds, podcasts: s.podcasts)..addListener(_changed));
    return _hosted;
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _hosted?.dispose();
    _query.dispose();
    _queryFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = Services.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([s.library, s.podcasts, s.feeds, s.account]),
      builder: (context, _) {
        final show = switch (widget.podcastId) {
          final id? => s.library.podcast(id),
          null => s.library.podcasts.where((p) => p.cloudFeedId == widget.feedId).firstOrNull,
        };
        final feedId = show?.cloudFeedId ?? widget.feedId;
        final feed = feedId == null ? null : s.feeds.feeds.where((f) => f.id == feedId).firstOrNull;
        final hosted = _hostedFor(feed);
        if (show == null && feed == null) {
          return PageBody(children: [
            backButton(context, 'Back'),
            const EmptyState(title: 'This show is gone', body: 'It was removed from your library.'),
          ]);
        }
        final own = feed != null ? feed.source == null : show!.isOwn;
        final episodes = show == null
          ? const <PodcastEpisode>[]
          : s.library.episodes(show.id, filter: _filter, oldestFirst: _oldestFirst, query: _query.text);
        final query = _query.text.trim();
        final videos = feed != null || show!.fromYouTube || episodes.any((e) => e.videoId != null);
        const p = brand.Palette.ink;
        final page = SleevePage(
          artwork: feed?.imageUrl ?? show?.artworkUrl,
          title: show?.title ?? feed!.title,
          info: _info(context, show, feed, own),
          actions: [
            if (show?.link case final link? when Uri.tryParse(link)?.hasScheme ?? false)
              Builder(
                builder: (context) => GlassIcon(
                  icon: Icons.adaptive.share,
                  tooltip: 'Share',
                  size: 21,
                  onPressed: () => unawaited(shareLink(context, link, title: show!.title)),
                ),
              ),
            glassMore(_menu(context, show, feed, own)),
          ],
          children: [
            if (feed != null && s.feeds.storageFull) ...[const StorageFullNotice(), const SizedBox(height: 16)],
            if (show != null && s.podcasts.paused(show)) ...[
              _paused(context),
              const SizedBox(height: 16),
            ] else if (show?.refreshError case final error? when !s.podcasts.offline) ...[
              problem(context, 'Couldn’t refresh this show: $error'),
              const SizedBox(height: 16),
            ],
            if (hosted?.loadError case final error? when !unreachable(error)) ...[
              problem(context, failure('Couldn’t load the uploads on their way', error, other: 'Try again in a minute.'), error),
              const SizedBox(height: 16),
            ],
            if (hosted?.removeError case final error?) ...[
              problem(context, failure('Couldn’t remove that episode', error, other: 'Try again.'), error),
              const SizedBox(height: 16),
            ],
            if (hosted != null && hosted.onTheWay.isNotEmpty) ...[
              OnTheWay(episodes: hosted, own: own),
              const SizedBox(height: 28),
            ],
            if (show != null) ...[
              _toolbar(context, show, episodes),
              const SizedBox(height: 12),
            ],
            if (episodes.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text(
                  switch (_filter) {
                    _ when query.isNotEmpty => switch (_filter) {
                      EpisodeFilter.all => 'No episodes match “$query”.',
                      EpisodeFilter.unplayed => 'No unplayed episodes match “$query”.',
                      EpisodeFilter.downloaded => 'No downloaded episodes match “$query”.',
                    },
                    EpisodeFilter.all when own => 'Add videos: search YouTube or paste a video link, and it’s added here.',
                    EpisodeFilter.all when show == null => 'Its videos arrive here as they upload.',
                    EpisodeFilter.all => 'This feed lists no episodes with audio.',
                    EpisodeFilter.unplayed => 'You’ve heard every episode.',
                    EpisodeFilter.downloaded => 'No episodes downloaded.',
                  },
                  style: Theme.of(context).textTheme.bodyMedium!.copyWith(color: p.fgSoft),
                ),
              )
            else ...[
              rowsPanel([
                for (final e in episodes.take(_shown))
                  EpisodeRow(
                    episode: e,
                    thumbnail: videos,
                    trailing: !own ? null : IconButton(
                      tooltip: 'Remove episode',
                      visualDensity: VisualDensity.compact,
                      onPressed: switch (hosted) {
                        null => () => s.library.removeEpisode(e.id),
                        final h => switch (h.of(e)) {
                          final up? when !h.removing.contains(up.id) => () => unawaited(h.remove(up)),
                          _ => null,
                        },
                      },
                      icon: Icon(Icons.close_rounded, size: 17, color: p.fgFaint),
                    ),
                  ),
              ]),
              if (episodes.length > _shown)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Center(
                    child: TextButton(
                      style: brand.button(brand.Tone.quietOnInk, brand.ButtonSize.sm),
                      onPressed: () => setState(() => _shown += _page),
                      child: Text('Show ${(episodes.length - _shown).clamp(0, _page)} more'),
                    ),
                  ),
                ),
            ],
          ],
        );
        return show == null ? page : Shown(show: show.id, child: page);
      },
    );
  }

  /// A playlist or channel here without a plan: what it has still plays,
  /// and new videos wait until there's a plan again.
  Widget _paused(BuildContext context) {
    final signedIn = Services.of(context).account.user != null;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
      decoration: BoxDecoration(color: brand.inkTile, borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        const Icon(Icons.pause_circle_outline_rounded, size: 18, color: brand.accentLight),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            'New videos are paused: following playlists and channels takes a plan. Everything here still plays.',
            style: Theme.of(context).textTheme.bodySmall!.copyWith(color: brand.snow),
          ),
        ),
        const SizedBox(width: 8),
        TextButton(
          style: brand.button(brand.Tone.quietOnInk, brand.ButtonSize.sm),
          onPressed: signedIn
            ? () => unawaited(showPlans(context, title: 'Keep getting new videos'))
            : Navigation.of(context).openSettings,
          child: Text(signedIn ? 'See plans' : 'Sign in'),
        ),
      ]),
    );
  }

  /// What sits under the hero (beside the artwork on a wide window): who
  /// makes it, its title, play and the show's actions, and what it's about.
  /// [feed] is the show's ListenJar feed, when it has one; [show] is null
  /// for a feed with nothing uploaded yet.
  Widget _info(BuildContext context, Podcast? show, Feed? feed, bool own) {
    final s = Services.of(context);
    final text = Theme.of(context).textTheme;
    final wide = MediaQuery.sizeOf(context).width >= wideWidth;
    final about = (show?.description ?? '').replaceAll(RegExp(r'<[^>]+>'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    final newest = show == null
      ? null
      : s.library.episodes(show.id, filter: EpisodeFilter.unplayed).firstOrNull ?? s.library.episodes(show.id).firstOrNull;
    final refreshing = show != null && s.podcasts.refreshing.contains(show.id);
    // Signed out, a ListenJar feed's show stays and plays, but the feed
    // isn't there to manage.
    final note = show?.cloudFeedId != null && feed == null ? 'One of your ListenJar feeds. Sign in, in Settings, to manage it.' : null;
    final author = own ? 'Podcast of your own' : show?.author ?? '';
    final video = switch (feed?.source) {
      final source? when source.kind == SourceKind.video && s.account.user?.plan == Plan.paid => source.url,
      _ => null,
    };
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (author.isNotEmpty) ...[
        Text(
          author,
          style: text.bodyMedium!.copyWith(color: brand.snowSoft, fontSize: 14, fontWeight: FontWeight.w600, height: 1.3),
        ),
        const SizedBox(height: 6),
      ],
      Text(
        show?.title ?? feed!.title,
        style: text.headlineMedium!.copyWith(color: brand.snow, fontSize: wide ? 40 : 28, height: wide ? 1.08 : 1.1),
      ),
      const SizedBox(height: 20),
      Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
        if (newest != null) PlayPill(episode: newest),
        if (own)
          SleeveCircle(
            icon: Icons.add_rounded,
            tooltip: 'Add videos',
            onPressed: () => Navigation.of(context).openSearch(youtube: true, into: feed?.id ?? OwnPodcast.show(show!).id),
          )
        else if (show == null)
          const SizedBox.shrink()
        else if (show.followed)
          SleeveCircle(
            icon: Icons.check_rounded,
            tooltip: show.cloudFeedId != null ? 'Following' : 'Following · Unfollow',
            onPressed: show.cloudFeedId != null ? null : () => _unfollow(context, show),
          )
        else
          SleeveCircle(
            icon: Icons.add_rounded,
            tooltip: show.isYouTube ? 'Add to Library' : 'Follow',
            onPressed: () => s.podcasts.followShow(show),
          ),
        if (show?.refreshes ?? false)
          SleeveCircle(
            icon: Icons.refresh_rounded,
            tooltip: 'Check for new episodes',
            busy: refreshing,
            onPressed: () => unawaited(s.podcasts.refresh(show!)),
          ),
        if (feed != null) ListenIn(feed: feed, onInk: true),
        if (feed != null && video != null) AddToPodcast(feed: feed, url: video),
      ]),
      if (s.podcasts.offline) ...[
        const SizedBox(height: 16),
        const OfflineLine(),
      ] else if (feed != null) ...[
        const SizedBox(height: 16),
        FeedSyncLine(feed: feed),
      ],
      if (note != null) ...[
        const SizedBox(height: 16),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Text(note, style: text.bodySmall!.copyWith(color: brand.snowSoft)),
        ),
      ],
      if (about.isNotEmpty) ...[
        const SizedBox(height: 16),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: GestureDetector(
            onTap: () => setState(() => _aboutOpen = !_aboutOpen),
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: AnimatedSize(
                duration: const Duration(milliseconds: 200),
                curve: brand.easeOutExpo,
                alignment: Alignment.topCenter,
                child: Text(
                  about,
                  maxLines: _aboutOpen ? null : 3,
                  overflow: _aboutOpen ? null : TextOverflow.ellipsis,
                  style: text.bodyMedium!.copyWith(color: brand.snowSoft),
                ),
              ),
            ),
          ),
        ),
      ],
    ]);
  }

  /// The show's more menu, in the glass cluster at the top right.
  List<Widget> _menu(BuildContext context, Podcast? show, Feed? feed, bool own) {
    final s = Services.of(context);
    final link = feed?.source?.url ?? show?.link;
    return [
      if (show != null && show.followed && show.kind == PodcastKind.rss) ...[
        MenuEntry(
          'Download new episodes',
          checked: show.autoDownload,
          onPressed: () => s.library.setAutoDownload(show.id, !show.autoDownload),
        ),
        const MenuDivider(),
      ],
      if (own) ...[
        MenuEntry('Change artwork', icon: Icons.image_outlined, onPressed: () {
          unawaited(feed != null ? _uploadArtwork(context, feed) : _pickArtwork(context, show!));
        }),
        const MenuDivider(),
      ],
      if (show != null) ...[
        MenuEntry('Mark all as played', icon: Icons.done_all_rounded, onPressed: () => s.library.setAllPlayed(show.id, true)),
        MenuEntry('Add unplayed to Up Next', icon: Icons.playlist_add_rounded, onPressed: () {
          s.library.playLast([for (final e in s.library.episodes(show.id, filter: EpisodeFilter.unplayed, oldestFirst: true)) e.id]);
        }),
        if (show.kind == PodcastKind.rss)
          MenuEntry('Copy feed link', icon: Icons.link_rounded, onPressed: () => unawaited(copyText(context, show.feedUrl, 'Feed link copied.'))),
      ],
      if (link case final link? when !own && (Uri.tryParse(link)?.hasScheme ?? false))
        MenuEntry(feed?.source != null || (show?.fromYouTube ?? false) ? 'Open on YouTube' : 'Open website', icon: Icons.open_in_new_rounded, onPressed: () {
          unawaited(launchUrl(Uri.parse(link), mode: LaunchMode.externalApplication));
        }),
      if (feed != null)
        MenuEntry('Sync now', icon: Icons.sync_rounded, onPressed: s.feeds.loading ? null : s.feeds.syncNow),
      if (feed != null) ...[
        const MenuDivider(),
        MenuEntry(
          own ? 'Delete podcast' : 'Remove',
          icon: Icons.remove_circle_outline_rounded,
          danger: true,
          onPressed: () => unawaited(removeCloudFeed(context, feed)),
        ),
      ] else if (show != null && show.followed && show.cloudFeedId == null) ...[
        const MenuDivider(),
        MenuEntry(
          show.isOwn ? 'Delete podcast' : show.isYouTube ? 'Remove from Library' : 'Unfollow',
          icon: Icons.remove_circle_outline_rounded,
          danger: true,
          onPressed: () => _unfollow(context, show),
        ),
      ],
    ];
  }

  Widget _toolbar(BuildContext context, Podcast show, List<PodcastEpisode> episodes) {
    final text = Theme.of(context).textTheme;
    Widget chip(EpisodeFilter filter, String label) {
      final on = _filter == filter;
      return TextButton(
        onPressed: () => setState(() {
          _filter = filter;
          _shown = _page;
        }),
        style: TextButton.styleFrom(
          backgroundColor: on ? brand.accent : brand.inkTile,
          foregroundColor: on ? brand.white : brand.snow,
          minimumSize: const Size(0, 32),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          shape: StadiumBorder(side: BorderSide(color: on ? brand.accent : brand.inkLine)),
          textStyle: text.labelLarge!.copyWith(fontSize: 13),
        ),
        child: Text(label),
      );
    }

    final chips = Wrap(spacing: 8, runSpacing: 8, children: [
      chip(EpisodeFilter.all, 'All'),
      chip(EpisodeFilter.unplayed, show.unplayed == 0 ? 'Unplayed' : 'Unplayed · ${show.unplayed}'),
      chip(EpisodeFilter.downloaded, 'Downloaded'),
    ]);
    final sort = Tooltip(
        message: _oldestFirst ? 'Oldest first' : 'Newest first',
        child: TextButton.icon(
          style: brand.button(brand.Tone.quietOnInk, brand.ButtonSize.sm).copyWith(
            backgroundColor: WidgetStateProperty.fromMap({WidgetState.hovered: brand.inkTile, WidgetState.any: brand.inkTile.withAlpha(0)}),
          ),
          onPressed: () => setState(() => _oldestFirst = !_oldestFirst),
          icon: Icon(_oldestFirst ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded, size: 16),
          label: Text(_oldestFirst ? 'Oldest' : 'Newest'),
        ),
      );
    // The page's own width, not the window's: beside the sidebar, a mid-size
    // window leaves the chips too little room and they stack one per line.
    return LayoutBuilder(builder: (context, constraints) {
      if (constraints.maxWidth < 680) {
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _searchField(context),
          const SizedBox(height: 12),
          Row(children: [Expanded(child: chips), sort]),
        ]);
      }
      return Row(children: [
        Expanded(child: chips),
        const SizedBox(width: 12),
        SizedBox(width: 240, child: _searchField(context)),
        const SizedBox(width: 4),
        sort,
      ]);
    });
  }

  /// Narrows the episodes to those whose title or show notes hold every word typed.
  Widget _searchField(BuildContext context) {
    final text = Theme.of(context).textTheme;
    void clear() => setState(() {
      _query.clear();
      _shown = _page;
    });
    return ListenableBuilder(
      listenable: _queryFocus,
      builder: (context, _) {
        final focused = _queryFocus.hasFocus;
        return AnimatedContainer(
          duration: brand.quick,
          curve: brand.easeOutExpo,
          height: 34,
          padding: const EdgeInsets.only(left: 12, right: 2),
          decoration: ShapeDecoration(
            color: brand.inkTile,
            shape: StadiumBorder(side: BorderSide(color: focused ? brand.accentLight.withValues(alpha: 0.7) : brand.inkLine, width: focused ? 1.5 : 1)),
          ),
          child: Row(children: [
            Icon(Icons.search_rounded, size: 18, color: focused ? brand.accentLight : brand.snowSoft),
            const SizedBox(width: 8),
            Expanded(
              child: CallbackShortcuts(
                bindings: {const SingleActivator(LogicalKeyboardKey.escape): clear},
                child: TextField(
                  controller: _query,
                  focusNode: _queryFocus,
                  // A tap anywhere else puts the keyboard away; Flutter only
                  // does that for a mouse on a phone, not a finger.
                  onTapOutside: (_) => _queryFocus.unfocus(),
                  onChanged: (_) => setState(() => _shown = _page),
                  style: text.bodyMedium!.copyWith(color: brand.snow, height: 1.2),
                  cursorColor: brand.accentLight,
                  decoration: InputDecoration(
                    isCollapsed: true,
                    border: InputBorder.none,
                    hintText: 'Search episodes',
                    hintStyle: text.bodyMedium!.copyWith(color: brand.snowSoft, height: 1.2),
                  ),
                ),
              ),
            ),
            if (_query.text.isNotEmpty)
              // Part of the field: clearing keeps the keyboard up.
              TextFieldTapRegion(child: IconButton(
                tooltip: 'Clear',
                visualDensity: VisualDensity.compact,
                iconSize: 16,
                onPressed: () {
                  clear();
                  _queryFocus.requestFocus();
                },
                icon: const Icon(Icons.close_rounded, color: brand.snowSoft),
              ))
            else
              const SizedBox(width: 10),
          ]),
        );
      },
    );
  }

  Future<void> _unfollow(BuildContext context, Podcast show) async {
    final s = Services.of(context);
    final text = Theme.of(context).textTheme;
    final downloaded = s.library.episodes(show.id, filter: EpisodeFilter.downloaded).length;
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: brand.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(brand.radiusSheet)),
        title: Text(
          show.isOwn ? 'Delete “${show.title}”?' : show.isYouTube ? 'Remove “${show.title}”?' : 'Unfollow “${show.title}”?',
          style: text.titleLarge,
        ),
        content: Text(
          [
            show.isOwn
              ? 'It and its videos leave your library, with where you are in each.'
              : show.isYouTube ? 'It leaves your library.' : 'Its new episodes stop arriving.',
            if (downloaded > 0) downloaded == 1 ? 'Its download is deleted from this device.' : 'Its $downloaded downloads are deleted from this device.',
          ].join(' '),
          style: text.bodyMedium!.copyWith(color: brand.fgSoft),
        ),
        actions: [
          TextButton(style: brand.button(brand.Tone.quiet, brand.ButtonSize.sm), onPressed: () => Navigator.pop(context, false), child: const Text('Keep it')),
          TextButton(
            style: brand.button(brand.Tone.ink, brand.ButtonSize.sm),
            onPressed: () => Navigator.pop(context, true),
            child: Text(show.isOwn ? 'Delete' : show.isYouTube ? 'Remove' : 'Unfollow'),
          ),
        ],
      ),
    );
    if (sure != true || !context.mounted) return;
    final navigator = Navigator.of(context);
    await s.podcasts.unfollow(show);
    if (navigator.canPop()) navigator.pop();
  }

  /// Makes a picture the listener picks the artwork of [feed], a podcast of
  /// their own ListenJar hosts: uploaded, and in the feed once it's up.
  Future<void> _uploadArtwork(BuildContext context, Feed feed) async {
    final feeds = Services.of(context).feeds;
    final file = await openFile(acceptedTypeGroups: const [
      XTypeGroup(label: 'Pictures', extensions: artworkExtensions, uniformTypeIdentifiers: ['public.image']),
    ]);
    if (file == null || !context.mounted) return;
    tell(context, 'Uploading the artwork…');
    try {
      await feeds.setArtwork(feed, await file.readAsBytes());
      if (context.mounted) tell(context, 'Artwork changed.');
    } catch (e) {
      if (!context.mounted) return;
      tell(context, switch (e) {
        UnreadablePicture() || PlanLimit() => '$e',
        _ => failure('Couldn’t change the artwork', e, other: 'Try another picture.'),
      });
    }
  }

  /// Makes a picture the listener picks the artwork of [show], a podcast of
  /// their own in the library.
  Future<void> _pickArtwork(BuildContext context, Podcast show) async {
    final podcasts = Services.of(context).podcasts;
    final file = await openFile(acceptedTypeGroups: const [
      XTypeGroup(label: 'Pictures', extensions: artworkExtensions, uniformTypeIdentifiers: ['public.image']),
    ]);
    if (file == null) return;
    try {
      await podcasts.setOwnArtwork(show, await file.readAsBytes());
    } catch (e) {
      if (context.mounted) tell(context, failure('Couldn’t change the artwork', e, other: 'Try another picture.'));
    }
  }
}
