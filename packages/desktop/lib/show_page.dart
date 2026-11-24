// A show: its cover, who makes it and what it's about, Follow, and every
// episode, newest first, filtered to the unplayed or the downloaded and
// searchable by title and show notes. Opened
// from the library, search or an episode; a show looked at from search is
// in the library unfollowed until the listener follows it. A podcast of the
// listener's own on this device is filled from Search instead, and moves to
// ListenJar Cloud from here.
import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import 'artwork.dart' show artworkExtensions;
import 'cloud.dart' show CloudShowPage, failure, moveToCloud;
import 'library.dart';
import 'menu.dart';
import 'plans.dart' show showPlans;
import 'shared_links.dart' show LocalOwn;
import 'shell.dart';
import 'theme.dart' as brand;
import 'ui.dart';

final class ShowPage extends StatefulWidget {
  const ShowPage({super.key, required this.podcastId});
  final int podcastId;

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

  @override
  void dispose() {
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
        final show = s.library.podcast(widget.podcastId);
        // One of the listener's ListenJar feeds: its page says how each
        // episode syncs, and manages the feed.
        if (show?.cloudFeedId case final id? when s.feeds.feeds.any((f) => f.id == id)) return CloudShowPage(feedId: id);
        if (show == null) {
          return PageBody(children: [
            backButton(context, 'Back'),
            const EmptyState(title: 'This show is gone', body: 'It was removed from your library.'),
          ]);
        }
        final episodes = s.library.episodes(show.id, filter: _filter, oldestFirst: _oldestFirst, query: _query.text);
        final query = _query.text.trim();
        final videos = show.fromYouTube || episodes.any((e) => e.videoId != null);
        return PageBody(children: [
          if (Navigator.of(context).canPop()) backButton(context, 'Back'),
          _header(context, show),
          if (s.podcasts.paused(show)) ...[
            const SizedBox(height: 16),
            _paused(context),
          ] else if (show.refreshError case final error?) ...[
            const SizedBox(height: 16),
            problem(context, 'Couldn’t refresh this show: $error'),
          ],
          const SizedBox(height: 28),
          _toolbar(context, show, episodes),
          const SizedBox(height: 12),
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
                  EpisodeFilter.all when show.isOwn => 'Add videos: search YouTube or paste a video link, and it’s added here.',
                  EpisodeFilter.all => 'This feed lists no episodes with audio.',
                  EpisodeFilter.unplayed => 'You’ve heard every episode.',
                  EpisodeFilter.downloaded => 'No episodes downloaded.',
                },
                style: Theme.of(context).textTheme.bodyMedium!.copyWith(color: brand.fgSoft),
              ),
            )
          else ...[
            rowsPanel([
              for (final e in episodes.take(_shown))
                EpisodeRow(
                  episode: e,
                  thumbnail: videos,
                  trailing: !show.isOwn ? null : IconButton(
                    tooltip: 'Remove episode',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => s.library.removeEpisode(e.id),
                    icon: const Icon(Icons.close_rounded, size: 17, color: brand.fgFaint),
                  ),
                ),
            ]),
            if (episodes.length > _shown)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Center(
                  child: TextButton(
                    style: brand.button(brand.Tone.quiet, brand.ButtonSize.sm),
                    onPressed: () => setState(() => _shown += _page),
                    child: Text('Show ${(episodes.length - _shown).clamp(0, _page)} more'),
                  ),
                ),
              ),
          ],
        ]);
      },
    );
  }

  /// A playlist or channel here without a plan: what it has still plays,
  /// and new videos wait until there's a plan again.
  Widget _paused(BuildContext context) {
    final signedIn = Services.of(context).account.user != null;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
      decoration: BoxDecoration(color: brand.mist, borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        const Icon(Icons.pause_circle_outline_rounded, size: 18, color: brand.accent),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            'New videos are paused: following playlists and channels takes a plan. Everything here still plays.',
            style: Theme.of(context).textTheme.bodySmall!.copyWith(color: brand.fg),
          ),
        ),
        const SizedBox(width: 8),
        TextButton(
          style: brand.button(brand.Tone.quiet, brand.ButtonSize.sm),
          onPressed: signedIn
            ? () => unawaited(showPlans(context, title: 'Keep getting new videos'))
            : Navigation.of(context).openSettings,
          child: Text(signedIn ? 'See plans' : 'Sign in'),
        ),
      ]),
    );
  }

  Widget _header(BuildContext context, Podcast show) {
    final s = Services.of(context);
    final text = Theme.of(context).textTheme;
    final narrow = MediaQuery.sizeOf(context).width < 640;
    final cover = narrow ? 128.0 : 200.0;
    final about = show.description.replaceAll(RegExp(r'<[^>]+>'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    final info = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(show.title, style: text.headlineMedium!.copyWith(fontSize: narrow ? 26 : 34, height: 1.1)),
      if (show.author.isNotEmpty) ...[
        const SizedBox(height: 8),
        Text(show.author, style: text.bodyMedium!.copyWith(color: brand.fgSoft, fontWeight: FontWeight.w600)),
      ],
      const SizedBox(height: 18),
      Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        if (show.isOwn)
          brand.accentShadow(
            enabled: true,
            child: TextButton.icon(
              style: brand.button(brand.Tone.accent, brand.ButtonSize.sm),
              onPressed: () => Navigation.of(context).openSearch(youtube: true, into: LocalOwn(show).id),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Add videos'),
            ),
          )
        else if (show.followed)
          TextButton.icon(
            style: brand.button(brand.Tone.quiet, brand.ButtonSize.sm),
            onPressed: show.cloudFeedId != null ? null : () => _unfollow(context, show),
            icon: const Icon(Icons.check_rounded, size: 18),
            label: const Text('Following'),
          )
        else
          brand.accentShadow(
            enabled: true,
            child: TextButton.icon(
              style: brand.button(brand.Tone.accent, brand.ButtonSize.sm),
              onPressed: () => s.podcasts.followShow(show),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: Text(show.isYouTube ? 'Add to Library' : 'Follow'),
            ),
          ),
        if (show.refreshes)
          Tooltip(
            message: 'Check for new episodes',
            child: IconButton(
              onPressed: s.podcasts.refreshing.contains(show.id) ? null : () => unawaited(s.podcasts.refresh(show)),
              icon: s.podcasts.refreshing.contains(show.id)
                ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2, color: brand.accent))
                : const Icon(Icons.refresh_rounded, color: brand.fgSoft),
            ),
          ),
        Dropdown(
          align: MenuAlign.end,
          items: [
            if (show.followed && show.kind == PodcastKind.rss) ...[
              MenuEntry(
                'Download new episodes',
                checked: show.autoDownload,
                onPressed: () => s.library.setAutoDownload(show.id, !show.autoDownload),
              ),
              const MenuDivider(),
            ],
            if (show.isOwn) ...[
              MenuEntry('Change artwork', icon: Icons.image_outlined, onPressed: () => unawaited(_pickArtwork(context, show))),
              const MenuDivider(),
            ],
            MenuEntry('Mark all as played', icon: Icons.done_all_rounded, onPressed: () => s.library.setAllPlayed(show.id, true)),
            MenuEntry('Add unplayed to Up Next', icon: Icons.playlist_add_rounded, onPressed: () {
              s.library.playLast([for (final e in s.library.episodes(show.id, filter: EpisodeFilter.unplayed, oldestFirst: true)) e.id]);
            }),
            if (show.kind == PodcastKind.rss)
              MenuEntry('Copy feed link', icon: Icons.link_rounded, onPressed: () => unawaited(copyText(context, show.feedUrl, 'Feed link copied.'))),
            if (show.link case final link? when Uri.tryParse(link)?.hasScheme ?? false)
              MenuEntry(show.fromYouTube ? 'Open on YouTube' : 'Open website', icon: Icons.open_in_new_rounded, onPressed: () {
                unawaited(launchUrl(Uri.parse(link), mode: LaunchMode.externalApplication));
              }),
            if ((show.kind == PodcastKind.youtubeFeed && show.followed) || show.isOwn)
              MenuEntry('Move to ListenJar Cloud', icon: Icons.cloud_upload_outlined, onPressed: () => unawaited(moveToCloud(context, show))),
            if (show.followed && show.cloudFeedId == null) ...[
              const MenuDivider(),
              MenuEntry(
                show.isOwn ? 'Delete podcast' : show.isYouTube ? 'Remove from Library' : 'Unfollow',
                icon: Icons.remove_circle_outline_rounded,
                danger: true,
                onPressed: () => _unfollow(context, show),
              ),
            ],
          ],
          builder: (context, menu) => MoreButton(menu: menu),
        ),
      ]),
      if (show.kind == PodcastKind.youtubeFeed || show.isOwn) ...[
        const SizedBox(height: 12),
        Text(
          'On this device: its videos stream from YouTube as you play them, and nothing is downloaded or uploaded. '
            'Only this app has it.',
          style: text.bodySmall!.copyWith(color: brand.fgSoft),
        ),
      ],
      if (show.cloudFeedId != null) ...[
        const SizedBox(height: 12),
        Text(
          'One of your ListenJar feeds. Sign in, in Settings, to manage it.',
          style: text.bodySmall!.copyWith(color: brand.fgSoft),
        ),
      ],
    ]);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (narrow) ...[
        Artwork(url: show.artworkUrl, title: show.title, size: cover),
        const SizedBox(height: 20),
        info,
      ] else
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          DecoratedBox(
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(22), boxShadow: const [brand.shadowSoft]),
            child: Artwork(url: show.artworkUrl, title: show.title, size: cover, radius: 22),
          ),
          const SizedBox(width: 28),
          Expanded(child: info),
        ]),
      if (about.isNotEmpty) ...[
        const SizedBox(height: 20),
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
                  style: text.bodyMedium!.copyWith(color: brand.fgSoft),
                ),
              ),
            ),
          ),
        ),
      ],
    ]);
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
          backgroundColor: on ? brand.accent : brand.white,
          foregroundColor: on ? brand.white : brand.fg,
          minimumSize: const Size(0, 32),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          shape: StadiumBorder(side: BorderSide(color: on ? brand.accent : brand.line)),
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
          style: brand.button(brand.Tone.quiet, brand.ButtonSize.sm).copyWith(
            backgroundColor: WidgetStateProperty.fromMap({WidgetState.hovered: brand.paperDeep, WidgetState.any: const Color(0x00000000)}),
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
            color: brand.white,
            shape: StadiumBorder(side: BorderSide(color: focused ? brand.accent.withValues(alpha: 0.6) : brand.line, width: focused ? 1.5 : 1)),
          ),
          child: Row(children: [
            Icon(Icons.search_rounded, size: 18, color: focused ? brand.accent : brand.fgSoft),
            const SizedBox(width: 8),
            Expanded(
              child: CallbackShortcuts(
                bindings: {const SingleActivator(LogicalKeyboardKey.escape): clear},
                child: TextField(
                  controller: _query,
                  focusNode: _queryFocus,
                  onChanged: (_) => setState(() => _shown = _page),
                  style: text.bodyMedium!.copyWith(height: 1.2),
                  cursorColor: brand.accent,
                  decoration: InputDecoration(
                    isCollapsed: true,
                    border: InputBorder.none,
                    hintText: 'Search episodes',
                    hintStyle: text.bodyMedium!.copyWith(color: brand.fgSoft, height: 1.2),
                  ),
                ),
              ),
            ),
            if (_query.text.isNotEmpty)
              IconButton(
                tooltip: 'Clear',
                visualDensity: VisualDensity.compact,
                iconSize: 16,
                onPressed: () {
                  clear();
                  _queryFocus.requestFocus();
                },
                icon: const Icon(Icons.close_rounded, color: brand.fgSoft),
              )
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

  /// Makes a picture the listener picks the artwork of [show], a podcast of
  /// their own on this device.
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
