// Library: every show the listener follows, as covers, newest episode
// first, with how many episodes they haven't heard. The listener's
// ListenJar Cloud feeds are shows here like any other, each saying what its
// sync is doing, and one with nothing uploaded yet waits here too.
// Podcasts of the listener's own start here; OPML in and out lives here,
// and on phones the way to Downloads and Settings.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';
import 'package:share_plus/share_plus.dart';

import 'backend/api.dart' show Feed;
import 'cloud.dart';
import 'downloads_page.dart';
import 'home_page.dart' show unplayedLabel;
import 'library.dart';
import 'links.dart' show kindLabel;
import 'menu.dart';
import 'settings_page.dart';
import 'shell.dart';
import 'sync.dart' show FeedPhase;
import 'theme.dart' as brand;
import 'ui.dart';

final class LibraryPage extends StatelessWidget {
  const LibraryPage({super.key});

  @override
  Widget build(BuildContext context) {
    final s = Services.of(context);
    final wide = MediaQuery.sizeOf(context).width >= wideWidth;
    return ListenableBuilder(
      listenable: Listenable.merge([s.library, s.podcasts, s.feeds, s.account]),
      builder: (context, _) {
        final shows = s.library.podcasts;
        final feeds = {for (final f in s.feeds.feeds) f.id: f};
        // Feeds with no RSS yet aren't followed; they wait, first, until
        // their first episode is uploaded.
        final followed = {for (final p in shows) ?p.cloudFeedId};
        final pending = [for (final f in s.feeds.feeds) if (!followed.contains(f.id)) f];
        final count = shows.length + pending.length;
        return PageBody(maxWidth: 1100, children: [
          pageTitle(context, 'Library', actions: [
            if (wide)
              TextButton.icon(
                style: brand.button(brand.Tone.quiet, brand.ButtonSize.sm),
                onPressed: () => unawaited(createPodcast(context)),
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('New podcast'),
              )
            else ...[
              IconButton(
                tooltip: 'New podcast',
                onPressed: () => unawaited(createPodcast(context)),
                icon: const Icon(Icons.add_rounded, color: brand.fgSoft),
              ),
              IconButton(
                tooltip: 'Downloads',
                onPressed: () => Navigator.of(context).push(pageRoute(const DownloadsPage(pushed: true))),
                icon: const Icon(Icons.download_rounded, color: brand.fgSoft),
              ),
              IconButton(
                tooltip: 'Settings',
                onPressed: () => Navigator.of(context).push(pageRoute(const SettingsPage(pushed: true))),
                icon: const Icon(Icons.tune_rounded, color: brand.fgSoft),
              ),
            ],
            const OpmlMenu(),
          ]),
          if (s.account.user != null && s.feeds.storageFull) ...[const SizedBox(height: 8), const StorageFullNotice(), const SizedBox(height: 16)],
          if (s.feeds.feedsError case final error? when s.account.user != null) ...[
            const SizedBox(height: 8),
            problem(context, failure('Couldn’t load your ListenJar podcasts', error, other: 'Sync again in Settings.'), error),
            const SizedBox(height: 16),
          ],
          if (count == 0) ...[
            const SizedBox(height: 16),
            EmptyState(
              title: 'Nothing here yet',
              body: 'Shows you follow collect here, with their new episodes counted, and so do podcasts you make from YouTube videos. '
                'Search for a show, or paste its RSS link into search.',
              actions: [
                brand.accentShadow(
                  enabled: true,
                  child: TextButton(
                    style: brand.button(brand.Tone.accent),
                    onPressed: () => Navigation.of(context).openSearch(),
                    child: const Text('Find a podcast'),
                  ),
                ),
                TextButton(
                  style: brand.button(brand.Tone.quiet),
                  onPressed: () => importOpml(context),
                  child: const Text('Import from another app'),
                ),
              ],
            ),
          ] else ...[
            Text(
              '$count ${count == 1 ? 'show' : 'shows'}',
              style: Theme.of(context).textTheme.bodySmall!.copyWith(color: brand.fgSoft),
            ),
            const SizedBox(height: 20),
            LayoutBuilder(
              builder: (context, box) {
                final columns = (box.maxWidth / 190).floor().clamp(2, 6);
                const gap = 20.0;
                final tile = (box.maxWidth - gap * (columns - 1)) / columns;
                return Wrap(spacing: gap, runSpacing: 26, children: [
                  for (final feed in pending) _feedTile(context, feed, tile),
                  for (final show in shows) _showTile(context, show, feeds[show.cloudFeedId], tile),
                ]);
              },
            ),
          ],
        ]);
      },
    );
  }

  /// A show, saying what its ListenJar feed's sync is doing when it has one.
  Widget _showTile(BuildContext context, Podcast show, Feed? feed, double size) {
    final s = Services.of(context);
    final sync = feed == null ? null : s.feeds.statusOf(feed);
    final status = feed == null ? null : feedTileStatus(feed, sync, playable: true);
    final unplayed = unplayedLabel(show);
    return _ShowTile(
      key: ValueKey('show ${show.id}'),
      title: show.title,
      artworkUrl: show.artworkUrl,
      size: size,
      count: unplayed,
      badge: show.isYouTube ? (Icons.smart_display_outlined, 'YouTube') : null,
      semantics: '${show.title}${unplayed.isEmpty ? '' : ', $unplayed unplayed'}${status == null ? '' : ', ${status.$1}'}',
      subtitle: switch (status) {
        final st? => st,
        _ when s.podcasts.refreshing.contains(show.id) => ('Checking…', false),
        _ when s.podcasts.paused(show) => ('New videos paused', false),
        _ when show.refreshError != null => ('Couldn’t refresh', true),
        _ when show.author.isNotEmpty => (show.author, false),
        _ when feed != null => (feed.source == null ? 'Your podcast' : kindLabel(feed.source!.kind), false),
        _ => (' ', false),
      },
      fraction: sync?.phase == FeedPhase.syncing ? sync?.fraction : null,
      onTap: () => Navigation.of(context).openShow(show.id),
    );
  }

  /// A ListenJar feed with no episode published yet.
  Widget _feedTile(BuildContext context, Feed feed, double size) {
    final sync = Services.of(context).feeds.statusOf(feed);
    final status = feedTileStatus(feed, sync, playable: false)!;
    return _ShowTile(
      key: ValueKey('feed ${feed.id}'),
      title: feed.title,
      artworkUrl: feed.imageUrl,
      size: size,
      count: '',
      badge: null,
      semantics: '${feed.title}, ${status.$1}',
      subtitle: status,
      fraction: sync?.phase == FeedPhase.syncing ? sync?.fraction : null,
      onTap: () => Navigation.of(context).openFeed(feed.id),
    );
  }
}

final class _ShowTile extends StatefulWidget {
  const _ShowTile({
    super.key,
    required this.title,
    required this.artworkUrl,
    required this.size,
    required this.count,
    required this.badge,
    required this.semantics,
    required this.subtitle,
    required this.fraction,
    required this.onTap,
  });
  final String title;
  final String? artworkUrl;
  final double size;

  /// Unplayed episodes, or empty.
  final String count;

  /// A single YouTube video kept as a show, rather than a podcast.
  final (IconData, String)? badge;
  final String semantics;

  /// The line under the title, and whether it says something went wrong.
  final (String, bool) subtitle;

  /// How far the episode syncing now has got.
  final double? fraction;
  final VoidCallback onTap;

  @override
  State<_ShowTile> createState() => _ShowTileState();
}

final class _ShowTileState extends State<_ShowTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final (subtitle, failed) = widget.subtitle;
    return SizedBox(
      width: widget.size,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Semantics(
            button: true,
            label: widget.semantics,
            excludeSemantics: true,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              AnimatedContainer(
                duration: brand.quick,
                curve: brand.easeOutExpo,
                transform: Matrix4.translationValues(0, _hover ? -3 : 0, 0),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  boxShadow: [_hover ? brand.shadowFloat : brand.shadowSoft],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: Stack(children: [
                    Artwork(url: widget.artworkUrl, title: widget.title, size: widget.size, radius: 18),
                    if (widget.count.isNotEmpty)
                      Positioned(
                        top: 10,
                        right: 10,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(color: brand.accent, borderRadius: BorderRadius.circular(99)),
                          child: Text(
                            widget.count,
                            style: text.labelSmall!.copyWith(color: brand.white, fontWeight: FontWeight.w700, fontFeatures: const [FontFeature.tabularFigures()]),
                          ),
                        ),
                      ),
                    if (widget.badge case (final icon, final label))
                      Positioned(
                        left: 10,
                        bottom: 10,
                        child: Container(
                          padding: const EdgeInsets.fromLTRB(7, 3, 8, 3),
                          decoration: BoxDecoration(color: const Color(0xD90A0B0F), borderRadius: BorderRadius.circular(99)),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Icon(icon, size: 12, color: brand.snow),
                            const SizedBox(width: 4),
                            Text(label, style: text.labelSmall!.copyWith(color: brand.snow, fontSize: 11, fontWeight: FontWeight.w600)),
                          ]),
                        ),
                      ),
                    if (widget.fraction case final fraction?)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: LinearProgressIndicator(value: fraction, minHeight: 3, color: brand.accent, backgroundColor: const Color(0x66FFFFFF)),
                      ),
                  ]),
                ),
              ),
              const SizedBox(height: 10),
              Text(widget.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: text.titleMedium!.copyWith(fontSize: 14.5, height: 1.25)),
              const SizedBox(height: 2),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.bodySmall!.copyWith(fontSize: 12.5, color: failed ? brand.danger : brand.fgSoft),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Moving subscriptions between podcast apps: OPML in and out.
final class OpmlMenu extends StatelessWidget {
  const OpmlMenu({super.key});

  @override
  Widget build(BuildContext context) => Dropdown(
    align: MenuAlign.end,
    items: [
      MenuEntry('Import OPML…', icon: Icons.file_upload_outlined, onPressed: () => unawaited(importOpml(context))),
      MenuEntry('Export OPML…', icon: Icons.file_download_outlined, onPressed: () => unawaited(exportOpml(context))),
    ],
    builder: (context, menu) => MoreButton(menu: menu, tooltip: 'Import or export'),
  );
}

const _opml = XTypeGroup(label: 'OPML', extensions: ['opml', 'xml'], uniformTypeIdentifiers: ['public.xml', 'public.data'], mimeTypes: ['text/x-opml', 'text/xml', 'application/xml']);

Future<void> importOpml(BuildContext context) async {
  final podcasts = Services.of(context).podcasts;
  final file = await openFile(acceptedTypeGroups: const [_opml]);
  if (file == null || !context.mounted) return;
  tell(context, 'Importing your shows…');
  try {
    final (followed, failed) = await podcasts.importOpml(utf8.decode(await file.readAsBytes(), allowMalformed: true));
    if (!context.mounted) return;
    tell(context, [
      'Followed $followed ${followed == 1 ? 'show' : 'shows'}.',
      if (failed > 0) '$failed couldn’t be read.',
    ].join(' '));
    unawaited(podcasts.refreshAll(force: true));
  } catch (e) {
    if (context.mounted) tell(context, 'Couldn’t import that file: $e');
  }
}

Future<void> exportOpml(BuildContext context) async {
  final podcasts = Services.of(context).podcasts;
  final data = XFile.fromData(utf8.encode(podcasts.exportOpml()), mimeType: 'text/x-opml', name: 'ListenJar.opml');
  // Phones have no save dialog: the share sheet saves to Files or Drive,
  // or hands the file to another podcast app.
  if (Platform.isAndroid || Platform.isIOS) {
    final box = context.findRenderObject() as RenderBox?;
    await SharePlus.instance.share(ShareParams(
      files: [data],
      fileNameOverrides: const ['ListenJar.opml'],
      sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
    ));
    return;
  }
  final where = await getSaveLocation(suggestedName: 'ListenJar.opml', acceptedTypeGroups: const [_opml]);
  if (where == null) return;
  await data.saveTo(where.path);
  if (context.mounted) tell(context, 'Exported your shows.');
}
