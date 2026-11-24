// Library: every show the listener follows, as covers, newest episode
// first, with how many episodes they haven't heard. OPML in and out lives
// here, and on phones the way to Downloads and Settings.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';
import 'package:share_plus/share_plus.dart';

import 'downloads_page.dart';
import 'home_page.dart' show unplayedLabel;
import 'library.dart';
import 'settings_page.dart';
import 'shell.dart';
import 'theme.dart' as brand;
import 'ui.dart';

final class LibraryPage extends StatelessWidget {
  const LibraryPage({super.key});

  @override
  Widget build(BuildContext context) {
    final s = Services.of(context);
    final wide = MediaQuery.sizeOf(context).width >= wideWidth;
    return ListenableBuilder(
      listenable: Listenable.merge([s.library, s.podcasts]),
      builder: (context, _) {
        final shows = s.library.podcasts;
        return PageBody(maxWidth: 1100, children: [
          pageTitle(context, 'Library', actions: [
            if (!wide) ...[
              IconButton(
                tooltip: 'Downloads',
                onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const DownloadsPage(pushed: true))),
                icon: const Icon(Icons.download_rounded, color: brand.fgSoft),
              ),
              IconButton(
                tooltip: 'Settings',
                onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SettingsPage(pushed: true))),
                icon: const Icon(Icons.tune_rounded, color: brand.fgSoft),
              ),
            ],
            const OpmlMenu(),
          ]),
          if (shows.isEmpty) ...[
            const SizedBox(height: 16),
            EmptyState(
              title: 'Nothing followed yet',
              body: 'Shows you follow collect here, with their new episodes counted. Search for one, or paste its RSS link into search.',
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
              '${shows.length} ${shows.length == 1 ? 'show' : 'shows'}',
              style: Theme.of(context).textTheme.bodySmall!.copyWith(color: brand.fgSoft),
            ),
            const SizedBox(height: 20),
            LayoutBuilder(
              builder: (context, box) {
                final columns = (box.maxWidth / 190).floor().clamp(2, 6);
                const gap = 20.0;
                final tile = (box.maxWidth - gap * (columns - 1)) / columns;
                return Wrap(spacing: gap, runSpacing: 26, children: [
                  for (final show in shows) _ShowTile(show: show, size: tile, refreshing: s.podcasts.refreshing.contains(show.id)),
                ]);
              },
            ),
          ],
        ]);
      },
    );
  }
}

final class _ShowTile extends StatefulWidget {
  const _ShowTile({required this.show, required this.size, required this.refreshing});
  final Podcast show;
  final double size;
  final bool refreshing;

  @override
  State<_ShowTile> createState() => _ShowTileState();
}

final class _ShowTileState extends State<_ShowTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final show = widget.show;
    final text = Theme.of(context).textTheme;
    final count = unplayedLabel(show);
    return SizedBox(
      width: widget.size,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: () => Navigation.of(context).openShow(show.id),
          child: Semantics(
            button: true,
            label: '${show.title}${count.isEmpty ? '' : ', $count unplayed'}',
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
                child: Stack(children: [
                  Artwork(url: show.artworkUrl, title: show.title, size: widget.size, radius: 18),
                  if (count.isNotEmpty)
                    Positioned(
                      top: 10,
                      right: 10,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(color: brand.accent, borderRadius: BorderRadius.circular(99)),
                        child: Text(
                          count,
                          style: text.labelSmall!.copyWith(color: brand.white, fontWeight: FontWeight.w700, fontFeatures: const [FontFeature.tabularFigures()]),
                        ),
                      ),
                    ),
                  if (show.isYouTube || show.cloudFeedId != null)
                    Positioned(
                      left: 10,
                      bottom: 10,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(color: const Color(0xD90A0B0F), borderRadius: BorderRadius.circular(99)),
                        child: Text(
                          show.isYouTube ? 'YouTube' : 'ListenJar',
                          style: text.labelSmall!.copyWith(color: brand.snow, fontSize: 11, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                ]),
              ),
              const SizedBox(height: 10),
              Text(show.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: text.titleMedium!.copyWith(fontSize: 14.5, height: 1.25)),
              const SizedBox(height: 2),
              Text(
                widget.refreshing
                  ? 'Checking…'
                  : (show.refreshError != null ? 'Couldn’t refresh' : (show.author.isEmpty ? ' ' : show.author)),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.bodySmall!.copyWith(fontSize: 12.5, color: show.refreshError != null ? brand.danger : brand.fgSoft),
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
  Widget build(BuildContext context) => MenuAnchor(
    style: menuStyle,
    alignmentOffset: const Offset(-200, 0),
    menuChildren: [
      menuItem(context, Icons.file_upload_outlined, 'Import OPML…', () => unawaited(importOpml(context))),
      menuItem(context, Icons.file_download_outlined, 'Export OPML…', () => unawaited(exportOpml(context))),
    ],
    builder: (context, menu, _) => IconButton(
      tooltip: 'Import or export',
      onPressed: () => menu.isOpen ? menu.close() : menu.open(),
      icon: const Icon(Icons.more_horiz_rounded, color: brand.fgSoft),
    ),
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
