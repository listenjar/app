// Up Next: what plays after the episode playing, in order. Drag to
// reorder; swipe or ✕ to take one off.
import 'package:material_ui/material_ui.dart';

import 'now_playing.dart' show UpNextList;
import 'shell.dart';
import 'theme.dart' as brand;
import 'ui.dart';

final class QueuePage extends StatelessWidget {
  const QueuePage({super.key});

  @override
  Widget build(BuildContext context) {
    final s = Services.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([s.library, s.player]),
      builder: (context, _) {
        final current = s.player.current;
        final queue = s.library.queue;
        // Started on its show's page, the episode plays on into the show's next.
        final following = s.player.following;
        return PageBody(children: [
          pageTitle(context, 'Up Next', actions: [
            if (queue.isNotEmpty)
              TextButton(
                style: brand.button(brand.Tone.quiet, brand.ButtonSize.sm),
                onPressed: s.library.clearQueue,
                child: const Text('Clear'),
              ),
          ]),
          if (current != null) ...[
            sectionHeading(context, 'Now playing', top: 16),
            rowsPanel([EpisodeRow(episode: current, withShow: true)]),
          ],
          if (queue.isNotEmpty) ...[
            sectionHeading(context, 'Then · ${queue.length}', top: current == null ? 16 : 32),
            DecoratedBox(
              decoration: BoxDecoration(
                color: brand.white,
                borderRadius: BorderRadius.circular(brand.radiusTile + 4),
                boxShadow: const [brand.shadowSoft],
              ),
              child: const UpNextList(padding: EdgeInsets.all(6), shrinkWrap: true),
            ),
          ],
          if (following != null) ...[
            sectionHeading(
              context,
              '${queue.isEmpty ? 'Then' : 'After those'}, from ${following.podcastTitle}',
              top: current == null && queue.isEmpty ? 16 : 32,
            ),
            rowsPanel([EpisodeRow(episode: following)]),
          ] else if (queue.isEmpty) ...[
            sectionHeading(context, 'Then', top: current == null ? 16 : 32),
            const EmptyState(
              title: 'Nothing waiting',
              body: 'Choose “Play next” or “Play last” on any episode, and it waits here, in order. '
                'When an episode ends, the first one here plays.',
            ),
          ],
        ]);
      },
    );
  }
}
