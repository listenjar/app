// A show: its cover, who makes it and what it's about, Follow, and every
// episode, newest first, filtered to the unplayed or the downloaded and
// searchable by title and show notes. Opened
// from the library, search or an episode; a show looked at from search is
// in the library unfollowed until the listener follows it.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import 'library.dart';
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
      listenable: Listenable.merge([s.library, s.podcasts]),
      builder: (context, _) {
        final show = s.library.podcast(widget.podcastId);
        if (show == null) {
          return PageBody(children: [
            backButton(context, 'Back'),
            const EmptyState(title: 'This show is gone', body: 'It was removed from your library.'),
          ]);
        }
        final episodes = s.library.episodes(show.id, filter: _filter, oldestFirst: _oldestFirst, query: _query.text);
        final query = _query.text.trim();
        return PageBody(children: [
          if (Navigator.of(context).canPop()) backButton(context, 'Back'),
          _header(context, show),
          if (show.refreshError case final error?) ...[
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
                  EpisodeFilter.all => 'This feed lists no episodes with audio.',
                  EpisodeFilter.unplayed => 'You’ve heard every episode.',
                  EpisodeFilter.downloaded => 'No episodes downloaded.',
                },
                style: Theme.of(context).textTheme.bodyMedium!.copyWith(color: brand.fgSoft),
              ),
            )
          else ...[
            rowsPanel([for (final e in episodes.take(_shown)) EpisodeRow(episode: e)]),
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
        if (show.followed)
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
        if (show.kind == PodcastKind.rss)
          Tooltip(
            message: 'Check for new episodes',
            child: IconButton(
              onPressed: s.podcasts.refreshing.contains(show.id) ? null : () => unawaited(s.podcasts.refresh(show)),
              icon: s.podcasts.refreshing.contains(show.id)
                ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2, color: brand.accent))
                : const Icon(Icons.refresh_rounded, color: brand.fgSoft),
            ),
          ),
        MenuAnchor(
          style: menuStyle,
          menuChildren: [
            if (show.followed && show.kind == PodcastKind.rss)
              MenuItemButton(
                leadingIcon: Icon(show.autoDownload ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded, size: 18, color: brand.fgSoft),
                onPressed: () => s.library.setAutoDownload(show.id, !show.autoDownload),
                child: Text('Download new episodes', style: text.bodyMedium),
              ),
            menuItem(context, Icons.done_all_rounded, 'Mark all as played', () => s.library.setAllPlayed(show.id, true)),
            menuItem(context, Icons.playlist_add_rounded, 'Add unplayed to Up Next', () {
              s.library.playLast([for (final e in s.library.episodes(show.id, filter: EpisodeFilter.unplayed, oldestFirst: true)) e.id]);
            }),
            if (show.kind == PodcastKind.rss)
              menuItem(context, Icons.link_rounded, 'Copy feed link', () => unawaited(copyText(context, show.feedUrl, 'Feed link copied.'))),
            if (show.link case final link? when Uri.tryParse(link)?.hasScheme ?? false)
              menuItem(context, Icons.open_in_new_rounded, show.isYouTube ? 'Open on YouTube' : 'Open website', () {
                unawaited(launchUrl(Uri.parse(link), mode: LaunchMode.externalApplication));
              }),
            if (show.followed && show.cloudFeedId == null)
              menuItem(context, Icons.remove_circle_outline_rounded, show.isYouTube ? 'Remove from Library' : 'Unfollow', () => _unfollow(context, show)),
          ],
          builder: (context, menu, _) => IconButton(
            tooltip: 'More',
            onPressed: () => menu.isOpen ? menu.close() : menu.open(),
            icon: const Icon(Icons.more_horiz_rounded, color: brand.fgSoft),
          ),
        ),
      ]),
      if (show.cloudFeedId != null) ...[
        const SizedBox(height: 12),
        Text(
          'One of your ListenJar feeds. Manage it in ListenJar Cloud.',
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
    if (MediaQuery.sizeOf(context).width < 640) {
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
        title: Text(show.isYouTube ? 'Remove “${show.title}”?' : 'Unfollow “${show.title}”?', style: text.titleLarge),
        content: Text(
          [
            show.isYouTube ? 'It leaves your library.' : 'Its new episodes stop arriving.',
            if (downloaded > 0) downloaded == 1 ? 'Its download is deleted from this device.' : 'Its $downloaded downloads are deleted from this device.',
          ].join(' '),
          style: text.bodyMedium!.copyWith(color: brand.fgSoft),
        ),
        actions: [
          TextButton(style: brand.button(brand.Tone.quiet, brand.ButtonSize.sm), onPressed: () => Navigator.pop(context, false), child: const Text('Keep it')),
          TextButton(
            style: brand.button(brand.Tone.ink, brand.ButtonSize.sm),
            onPressed: () => Navigator.pop(context, true),
            child: Text(show.isYouTube ? 'Remove' : 'Unfollow'),
          ),
        ],
      ),
    );
    if (sure != true || !context.mounted) return;
    final navigator = Navigator.of(context);
    await s.podcasts.unfollow(show);
    if (navigator.canPop()) navigator.pop();
  }
}
