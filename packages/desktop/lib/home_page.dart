// Listen Now: where the listener left off, then what's new from the shows
// they follow. Before they follow anything, it shows how to start.
import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'library.dart';
import 'marks.dart';
import 'shell.dart';
import 'theme.dart' as brand;
import 'ui.dart';

final class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final s = Services.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([s.library, s.podcasts]),
      builder: (context, _) {
        final library = s.library;
        final current = s.player.current?.id;
        final started = library.inProgress().where((e) => e.id != current).take(6).toList();
        final latest = library.latest(limit: 60).where((e) => e.id != current && !e.started).toList();
        final following = library.podcasts.isNotEmpty;
        return RefreshIndicator(
          color: brand.accent,
          onRefresh: () => s.podcasts.refreshAll(force: true),
          child: PageBody(children: [
            pageTitle(context, 'Listen Now', actions: [
              if (following) _RefreshButton(refreshing: s.podcasts.refreshingAll, onPressed: () => s.podcasts.refreshAll(force: true)),
            ]),
            if (!following) ...[
              const SizedBox(height: 16),
              const _Welcome(),
            ],
            if (started.isNotEmpty) ...[
              sectionHeading(context, 'Continue listening', top: 20),
              rowsPanel([for (final e in started) EpisodeRow(episode: e, withShow: true)]),
            ],
            if (following) ...[
              sectionHeading(
                context,
                'New episodes',
                top: started.isEmpty ? 20 : 36,
                action: latest.length > 1
                  ? TextButton(
                      style: brand.button(brand.Tone.quiet, brand.ButtonSize.sm),
                      onPressed: () => library.playLast([for (final e in latest.take(20)) e.id]),
                      child: const Text('Add all to Up Next'),
                    )
                  : null,
              ),
              if (latest.isEmpty)
                Text(
                  s.podcasts.refreshingAll ? 'Checking your shows for new episodes…' : 'You’re all caught up.',
                  style: Theme.of(context).textTheme.bodyMedium!.copyWith(color: brand.fgSoft),
                )
              else
                rowsPanel([for (final e in latest) EpisodeRow(episode: e, withShow: true)]),
            ],
          ]),
        );
      },
    );
  }
}

final class _RefreshButton extends StatelessWidget {
  const _RefreshButton({required this.refreshing, required this.onPressed});
  final bool refreshing;
  final Future<void> Function() onPressed;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: refreshing ? 'Checking for new episodes…' : 'Check for new episodes',
    child: IconButton(
      onPressed: refreshing ? null : () => unawaited(onPressed()),
      style: IconButton.styleFrom(hoverColor: brand.paperDeep),
      icon: refreshing
        ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2, color: brand.accent))
        : const GlyphIcon(Glyphs.sync, color: brand.fgSoft),
    ),
  );
}

/// The first run: a podcast player that's free, and the ways in.
final class _Welcome extends StatelessWidget {
  const _Welcome();

  @override
  Widget build(BuildContext context) {
    final navigation = Navigation.of(context);
    final text = Theme.of(context).textTheme;
    return brand.panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Your podcasts, all in one place', style: text.titleLarge!.copyWith(fontSize: 24)),
        const SizedBox(height: 10),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Text(
            'Find a show, paste any podcast’s RSS link, or play a YouTube video as an episode. '
            'Following, downloading and listening are free, with no account.',
            style: text.bodyMedium!.copyWith(color: brand.fgSoft),
          ),
        ),
        const SizedBox(height: 22),
        Wrap(spacing: 10, runSpacing: 10, children: [
          brand.accentShadow(
            enabled: true,
            child: TextButton.icon(
              style: brand.button(brand.Tone.accent),
              onPressed: () => navigation.openSearch(),
              icon: const GlyphIcon(Glyphs.search, size: 20),
              label: const Text('Find a podcast'),
            ),
          ),
          TextButton.icon(
            style: brand.button(brand.Tone.quiet),
            onPressed: () => navigation.openSearch(youtube: true),
            icon: const GlyphIcon(Glyphs.video, size: 20),
            label: const Text('Search YouTube'),
          ),
        ]),
      ]),
    );
  }
}

/// An unplayed count, for show tiles.
String unplayedLabel(Podcast p) => p.unplayed == 0 ? '' : (p.unplayed > 99 ? '99+' : '${p.unplayed}');
