// Downloads: what's on this device to play offline, and what's on its way,
// with the space it takes.
import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import 'library.dart';
import 'plans.dart' show formatBytes;
import 'shell.dart';
import 'storage_page.dart';
import 'theme.dart' as brand;
import 'ui.dart';

final class DownloadsPage extends StatelessWidget {
  const DownloadsPage({super.key, this.pushed = false});

  /// Opened from Library on a phone, with a way back.
  final bool pushed;

  @override
  Widget build(BuildContext context) {
    final s = Services.of(context);
    final page = ListenableBuilder(
      listenable: s.library,
      builder: (context, _) {
        final all = s.library.downloads();
        final done = all.where((e) => e.downloaded).toList();
        final going = all.where((e) => !e.downloaded).toList();
        var bytes = 0;
        for (final e in done) {
          final file = s.library.downloadFile(e);
          if (file != null && file.existsSync()) bytes += file.lengthSync();
        }
        return PageBody(children: [
          if (pushed) backButton(context, 'Library'),
          pageTitle(context, 'Downloads', actions: [
            if (done.any((e) => e.played))
              TextButton(
                style: brand.button(brand.Tone.quiet, brand.ButtonSize.sm),
                onPressed: () async {
                  for (final e in done.where((e) => e.played)) {
                    await s.downloads.delete(e);
                  }
                },
                child: const Text('Delete played'),
              ),
            TextButton(
              style: brand.button(brand.Tone.quiet, brand.ButtonSize.sm),
              onPressed: () => Navigator.of(context).push(pageRoute(const StoragePage(back: 'Downloads'))),
              child: const Text('Storage'),
            ),
          ]),
          if (done.isNotEmpty)
            Text(
              '${done.length} ${done.length == 1 ? 'episode' : 'episodes'} · ${formatBytes(bytes)} on this device',
              style: Theme.of(context).textTheme.bodySmall!.copyWith(color: brand.fgSoft),
            ),
          if (all.isEmpty) ...[
            const SizedBox(height: 16),
            EmptyState(
              title: 'Nothing downloaded',
              body: 'Download an episode to play it without a connection. '
                '${Platform.isIOS || Platform.isAndroid ? 'Downloads carry on while the app is in the background.' : 'Downloads carry on while Listenjar is open.'} '
                'Shows can download their new episodes on their own, from each show’s menu or in Settings.',
            ),
          ],
          if (going.isNotEmpty) ...[
            sectionHeading(context, 'Downloading', top: 20),
            rowsPanel([for (final e in going) EpisodeRow(episode: e, withShow: true, trailing: _cancel(context, e))]),
          ],
          if (done.isNotEmpty) ...[
            sectionHeading(context, 'On this device', top: going.isEmpty ? 20 : 32),
            rowsPanel([for (final e in done) EpisodeRow(episode: e, withShow: true)]),
          ],
        ]);
      },
    );
    return pushed ? Scaffold(body: SafeArea(child: page)) : page;
  }

  Widget _cancel(BuildContext context, PodcastEpisode e) => IconButton(
    tooltip: e.downloadState == DownloadState.failed ? 'Remove' : 'Cancel',
    onPressed: () => unawaited(Services.of(context).downloads.delete(e)),
    icon: const Icon(Icons.close_rounded, size: 20, color: brand.fgSoft),
  );
}
