// Storage: the space downloads take on this device, show by show, and the
// listener's rules for it, after Telegram's Storage Usage: a ring of the
// shows taking the most, rows to pick shows to delete, a maximum size, and
// how long played and unplayed downloads stay. downloads.dart's
// tidyDownloads applies the rules.
import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'downloads.dart' show tidyDownloads;
import 'library.dart';
import 'plans.dart' show formatBytes;
import 'settings_page.dart' show settingChoice;
import 'shell.dart';
import 'theme.dart' as brand;
import 'ui.dart';

/// The ring's colours, in a fixed order by size: the dataviz skill's
/// categorical slots 1 to 5, validated on white (scripts/validate_palette.js:
/// adjacent pairs pass for colour-blind and full-colour readers; aqua,
/// yellow and magenta sit under 3:1, so the rows below name every part).
const _series = [Color(0xFF2A78D6), Color(0xFFEB6834), Color(0xFF1BAF7A), Color(0xFFEDA100), Color(0xFFE87BA4)];

/// Shows past the fifth, folded into one part.
const _other = Color(0xFFC3C2B7);

/// A part left out of a deletion.
const _unpicked = brand.paperDeep;

/// Maximum sizes to pick from; null for no limit.
const _limits = <int?>[2000000000, 5000000000, 10000000000, 25000000000, null];

const _played = <Duration?>[null, Duration.zero, Duration(days: 1), Duration(days: 7)];
const _unplayed = <Duration?>[null, Duration(days: 7), Duration(days: 30), Duration(days: 90)];

/// The bytes finished downloads take on this device.
int storedBytes(Library library) {
  var bytes = 0;
  for (final d in library.storedDownloads()) {
    bytes += _bytes(library, d.episode);
  }
  return bytes;
}

int _bytes(Library library, PodcastEpisode episode) {
  final file = library.downloadFile(episode);
  if (file == null || !file.existsSync()) return 0;
  return file.lengthSync();
}

/// A part of the ring: one show, or the shows past the fifth.
typedef _Part = ({int key, String title, Color color, int bytes, int shows, List<PodcastEpisode> episodes});

/// Downloads by show, largest first, the sixth on folded into "other shows".
List<_Part> _parts(Library library) {
  final byShow = <int, ({String title, int bytes, List<PodcastEpisode> episodes})>{};
  for (final d in library.storedDownloads()) {
    final e = d.episode;
    final was = byShow[e.podcastId];
    byShow[e.podcastId] = (
      title: was?.title ?? e.podcastTitle,
      bytes: (was?.bytes ?? 0) + _bytes(library, e),
      episodes: [...?was?.episodes, e],
    );
  }
  final shows = byShow.entries.toList()..sort((a, b) => b.value.bytes.compareTo(a.value.bytes));
  final parts = <_Part>[
    for (final (i, show) in shows.take(_series.length).indexed)
      (key: show.key, title: show.value.title, color: _series[i], bytes: show.value.bytes, shows: 1, episodes: show.value.episodes),
  ];
  final rest = shows.skip(_series.length).toList();
  if (rest.isNotEmpty) {
    parts.add((
      key: -1,
      title: rest.length == 1 ? rest.single.value.title : '${rest.length} other shows',
      color: _other,
      bytes: rest.fold(0, (sum, show) => sum + show.value.bytes),
      shows: rest.length,
      episodes: [for (final show in rest) ...show.value.episodes],
    ));
  }
  return parts;
}

final class StoragePage extends StatefulWidget {
  const StoragePage({super.key, required this.back});

  /// The page it was opened from, for the back button.
  final String back;

  @override
  State<StoragePage> createState() => _StoragePageState();
}

final class _StoragePageState extends State<StoragePage> {
  /// Parts the listener unticked, by key.
  final _left = <int>{};

  /// The stop the slider is on while it moves.
  int? _dragging;

  @override
  Widget build(BuildContext context) {
    final s = Services.of(context);
    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: s.library,
          builder: (context, _) {
            final settings = s.library.settings;
            final parts = _parts(s.library);
            final total = parts.fold(0, (sum, p) => sum + p.bytes);
            void set(PlayerSettings next) {
              s.library.updateSettings(next);
              unawaited(tidyDownloads(s.library, s.downloads));
            }

            return PageBody(maxWidth: 720, children: [
              backButton(context, widget.back),
              pageTitle(context, 'Storage'),
              const SizedBox(height: 12),
              if (parts.isEmpty)
                const EmptyState(
                  title: 'Nothing downloaded',
                  body: 'Downloaded episodes show here with the space they take, show by show.',
                )
              else
                _overview(context, parts, total),
              sectionHeading(context, 'Maximum size'),
              _limit(context, settings, total, set),
              sectionHeading(context, 'Delete on their own'),
              rowsPanel([
                settingChoice(
                  context,
                  'Played episodes',
                  'A download goes this long after you finish the episode.',
                  settings.removePlayedAfter,
                  _played,
                  (v) => switch (v) {
                    null => 'Keep',
                    Duration.zero => 'Right away',
                    final d => 'After ${_period(d)}',
                  },
                  (v) => set(settings.copyWith(removePlayedAfter: v)),
                ),
                settingChoice(
                  context,
                  'Unplayed for',
                  'A download goes once you haven’t played it for this long.',
                  settings.removeUnplayedAfter,
                  _unplayed,
                  (v) => switch (v?.inDays) {
                    null => 'Keep',
                    7 => '1 week',
                    30 => '1 month',
                    final days => '${days ~/ 30} months',
                  },
                  (v) => set(settings.copyWith(removeUnplayedAfter: v)),
                ),
              ]),
              const SizedBox(height: 12),
              _caption(context, 'The episode playing and Up Next always stay.'),
            ]);
          },
        ),
      ),
    );
  }

  Widget _caption(BuildContext context, String text, {TextAlign? align}) => Text(
    text,
    textAlign: align,
    style: Theme.of(context).textTheme.bodySmall!.copyWith(color: brand.fgSoft),
  );

  Widget _panel(Widget child) => DecoratedBox(
    decoration: BoxDecoration(
      color: brand.white,
      borderRadius: BorderRadius.circular(brand.radiusTile + 4),
      boxShadow: const [brand.shadowSoft],
    ),
    child: child,
  );

  Widget _overview(BuildContext context, List<_Part> parts, int total) {
    final text = Theme.of(context).textTheme;
    final picked = [for (final p in parts) if (!_left.contains(p.key)) p];
    final pickedBytes = picked.fold(0, (sum, p) => sum + p.bytes);
    final all = picked.length == parts.length;
    final episodes = parts.fold(0, (sum, p) => sum + p.episodes.length);
    final shows = parts.fold(0, (sum, p) => sum + p.shows);
    return _panel(Padding(
      padding: const EdgeInsets.fromLTRB(6, 24, 6, 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Center(
          child: SizedBox.square(
            dimension: 176,
            child: CustomPaint(
              painter: _Ring([
                for (final p in parts) (total == 0 ? 0.0 : p.bytes / total, _left.contains(p.key) ? _unpicked : p.color),
              ]),
              child: Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(
                    formatBytes(all ? total : pickedBytes),
                    style: text.titleLarge!.copyWith(fontSize: 26, fontFeatures: const [FontFeature.tabularFigures()]),
                  ),
                  const SizedBox(height: 2),
                  Text(all ? 'downloaded' : 'picked', style: text.bodySmall!.copyWith(color: brand.fgSoft)),
                ]),
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        _caption(
          context,
          '$episodes ${episodes == 1 ? 'episode' : 'episodes'} from $shows ${shows == 1 ? 'show' : 'shows'} on this device.',
          align: TextAlign.center,
        ),
        const SizedBox(height: 16),
        const Divider(height: 1, thickness: 1, indent: 12, endIndent: 12, color: brand.line),
        for (final (i, p) in parts.indexed) ...[
          if (i > 0) const Divider(height: 1, thickness: 1, indent: 56, endIndent: 12, color: brand.line),
          _partRow(context, p, total),
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 10, 8, 8),
          child: TextButton(
            style: brand.button(brand.Tone.quiet).copyWith(
              foregroundColor: WidgetStateProperty.fromMap({WidgetState.disabled: brand.fgFaint, WidgetState.any: brand.danger}),
            ),
            onPressed: picked.isEmpty ? null : () => unawaited(_delete(context, picked)),
            child: Text(
              all ? 'Delete all downloads · ${formatBytes(total)}' : 'Delete picked · ${formatBytes(pickedBytes)}',
              style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: _caption(context, 'Episodes stay in their shows and download again any time.', align: TextAlign.center),
        ),
      ]),
    ));
  }

  Widget _partRow(BuildContext context, _Part p, int total) {
    final text = Theme.of(context).textTheme;
    final on = !_left.contains(p.key);
    final share = total == 0 ? 0.0 : p.bytes / total * 100;
    final figures = text.bodySmall!.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
    void toggle() => setState(() => on ? _left.add(p.key) : _left.remove(p.key));
    return Semantics(
      checked: on,
      label: '${p.title}, ${formatBytes(p.bytes)}',
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: toggle,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 6, 12, 6),
          child: Row(children: [
            Checkbox(
              value: on,
              onChanged: (_) => toggle(),
              activeColor: brand.accent,
              checkColor: brand.white,
              side: const BorderSide(color: brand.fgFaint, width: 1.5),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
            ),
            const SizedBox(width: 6),
            DecoratedBox(
              decoration: BoxDecoration(color: p.color, shape: BoxShape.circle),
              child: const SizedBox.square(dimension: 10),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(p.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.titleMedium!.copyWith(fontSize: 15)),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 44,
              child: Text(share < 1 ? '<1%' : '${share.round()}%', textAlign: TextAlign.right, style: figures.copyWith(color: brand.fgSoft)),
            ),
            SizedBox(width: 72, child: Text(formatBytes(p.bytes), textAlign: TextAlign.right, style: figures)),
          ]),
        ),
      ),
    );
  }

  Future<void> _delete(BuildContext context, List<_Part> picked) async {
    final s = Services.of(context);
    final text = Theme.of(context).textTheme;
    final playing = s.library.nowPlaying;
    final episodes = [for (final p in picked) ...p.episodes];
    final going = [for (final e in episodes) if (e.id != playing) e];
    final bytes = picked.fold(0, (sum, p) => sum + p.bytes);
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: brand.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(brand.radiusSheet)),
        title: Text(
          going.length == 1 ? 'Delete 1 download?' : 'Delete ${going.length} downloads?',
          style: text.titleLarge,
        ),
        content: Text(
          [
            'About ${formatBytes(bytes)} leaves this device. The episodes stay in their shows to download again.',
            if (going.length < episodes.length) 'The episode playing stays.',
          ].join(' '),
          style: text.bodyMedium!.copyWith(color: brand.fgSoft),
        ),
        actions: [
          TextButton(style: brand.button(brand.Tone.quiet, brand.ButtonSize.sm), onPressed: () => Navigator.pop(context, false), child: const Text('Keep them')),
          TextButton(
            style: brand.button(brand.Tone.ink, brand.ButtonSize.sm),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (sure != true) return;
    for (final e in going) {
      await s.downloads.delete(e);
    }
    if (mounted) setState(_left.clear);
  }

  Widget _limit(BuildContext context, PlayerSettings settings, int total, void Function(PlayerSettings) set) {
    final text = Theme.of(context).textTheme;
    final at = _dragging ?? _stop(settings.storageLimit);
    final limit = _limits[at];
    final over = limit == null ? 0 : total - limit;
    String label(int? bytes) => bytes == null ? 'No limit' : formatBytes(bytes);
    // The track runs this far in from each side, so the stops' names sit
    // under its ticks.
    const inset = 12.0;
    return _panel(Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 4,
            activeTrackColor: brand.accent,
            inactiveTrackColor: brand.paperDeep,
            activeTickMarkColor: brand.white,
            inactiveTickMarkColor: brand.fgFaint,
            thumbColor: brand.accent,
            overlayColor: brand.accent.withValues(alpha: 0.12),
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 9),
            trackShape: const RoundedRectSliderTrackShape(),
            showValueIndicator: ShowValueIndicator.never,
          ),
          child: Slider(
            value: at.toDouble(),
            max: (_limits.length - 1).toDouble(),
            divisions: _limits.length - 1,
            padding: const EdgeInsets.symmetric(horizontal: inset, vertical: 14),
            onChanged: (v) => setState(() => _dragging = v.round()),
            onChangeEnd: (v) {
              setState(() => _dragging = null);
              set(settings.copyWith(storageLimit: _limits[v.round()]));
            },
            semanticFormatterCallback: (v) => label(_limits[v.round()]),
          ),
        ),
        SizedBox(
          height: 20,
          child: LayoutBuilder(builder: (context, box) {
            final step = (box.maxWidth - 2 * inset) / (_limits.length - 1);
            const width = 80.0;
            return Stack(clipBehavior: Clip.none, children: [
              for (final (i, stop) in _limits.indexed)
                Positioned(
                  left: i == 0 ? 0 : i == _limits.length - 1 ? null : inset + step * i - width / 2,
                  right: i == _limits.length - 1 ? 0 : null,
                  width: width,
                  child: Text(
                    label(stop),
                    textAlign: i == 0 ? TextAlign.left : i == _limits.length - 1 ? TextAlign.right : TextAlign.center,
                    style: text.bodySmall!.copyWith(
                      fontSize: 13,
                      color: i == at ? brand.fg : brand.fgSoft,
                      fontWeight: i == at ? FontWeight.w600 : null,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
            ]);
          }),
        ),
        const SizedBox(height: 14),
        _caption(context, switch (limit) {
          null => 'Pick a size, and once downloads pass it, the ones you haven’t played for the longest go first.',
          _ when over > 0 => 'Downloads take ${formatBytes(over)} more than this: the ones you haven’t played for the longest go first, until the rest fit.',
          _ => 'Once downloads pass this, the ones you haven’t played for the longest go first.',
        }),
      ]),
    ));
  }

  /// The stop [limit] is on, or the closest.
  int _stop(int? limit) {
    if (limit == null) return _limits.length - 1;
    var best = 0;
    for (final (i, stop) in _limits.indexed) {
      if (stop != null && (stop - limit).abs() < (_limits[best]! - limit).abs()) best = i;
    }
    return best;
  }
}

String _period(Duration d) => switch (d.inDays) {
  1 => 'a day',
  7 => 'a week',
  30 => 'a month',
  final days when days % 30 == 0 => '${days ~/ 30} months',
  final days when days % 7 == 0 => '${days ~/ 7} weeks',
  final days => '$days days',
};

/// The ring: each part an arc in its colour, a 2px gap of the panel's white
/// between neighbours.
final class _Ring extends CustomPainter {
  _Ring(this.parts);

  /// Each part's share of the whole, and its colour.
  final List<(double, Color)> parts;

  static const _width = 18.0;
  static const _gap = 2.0;

  @override
  void paint(Canvas canvas, Size size) {
    final radius = size.shortestSide / 2 - _width / 2;
    final rect = Rect.fromCircle(center: size.center(Offset.zero), radius: radius);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _width;
    final drawn = [for (final p in parts) if (p.$1 > 0) p];
    if (drawn.length == 1) {
      canvas.drawCircle(rect.center, radius, paint..color = drawn.single.$2);
      return;
    }
    // The gap is 2px at the ring's middle.
    final gap = _gap / radius;
    var start = -math.pi / 2;
    for (final (share, color) in drawn) {
      final sweep = share * 2 * math.pi;
      if (sweep > gap) canvas.drawArc(rect, start + gap / 2, sweep - gap, false, paint..color = color);
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(_Ring old) =>
    old.parts.length != parts.length || [for (final (i, p) in parts.indexed) p != old.parts[i]].any((changed) => changed);
}
