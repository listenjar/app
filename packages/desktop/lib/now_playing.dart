// What's playing, on ink (DESIGN.md: ink carries the moments that sell
// listening): the mini player under every section, and Now Playing, which
// it opens. Now Playing holds the cover, the scrubber, skip and play, the
// speed, the sleep timer, Up Next and the show notes.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'library.dart';
import 'player.dart';
import 'theme.dart' as brand;
import 'ui.dart';

/// Opens Now Playing over the window, rising from the mini player.
Future<void> showNowPlaying(BuildContext context) => Navigator.of(context, rootNavigator: true).push(
  PageRouteBuilder<void>(
    opaque: true,
    transitionDuration: const Duration(milliseconds: 320),
    reverseTransitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (_, _, _) => const NowPlaying(),
    transitionsBuilder: (context, animation, _, child) {
      if (MediaQuery.disableAnimationsOf(context)) return FadeTransition(opacity: animation, child: child);
      final curved = CurvedAnimation(parent: animation, curve: brand.easeOutExpo, reverseCurve: Curves.easeInCubic);
      return SlideTransition(
        position: Tween(begin: const Offset(0, 1), end: Offset.zero).animate(curved),
        child: child,
      );
    },
  ),
);

/// The icon for a skip of [d], when Material has one with that number.
IconData _skipIcon(Duration d, {required bool forward}) => switch ((d.inSeconds, forward)) {
  (5, false) => Icons.replay_5_rounded,
  (10, false) => Icons.replay_10_rounded,
  (30, false) => Icons.replay_30_rounded,
  (5, true) => Icons.forward_5_rounded,
  (10, true) => Icons.forward_10_rounded,
  (30, true) => Icons.forward_30_rounded,
  (_, false) => Icons.replay_rounded,
  (_, true) => Icons.forward_rounded,
};

String speedLabel(double speed) {
  final text = speed.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  return '$text×';
}

// The mini player.

final class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key, required this.wide});
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final s = Services.of(context);
    return ListenableBuilder(
      listenable: s.player,
      builder: (context, _) {
        final e = s.player.current;
        return AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: brand.easeOutExpo,
          alignment: Alignment.topCenter,
          child: e == null ? const SizedBox(width: double.infinity) : _bar(context, s, e),
        );
      },
    );
  }

  Widget _bar(BuildContext context, Services s, PodcastEpisode e) {
    final text = Theme.of(context).textTheme;
    final player = s.player;
    final settings = s.library.settings;
    final open = Navigation.of(context).openNowPlaying;
    final title = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(e.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.titleMedium!.copyWith(color: brand.snow, fontSize: 14.5)),
      const SizedBox(height: 2),
      Text(
        player.problem ?? e.from,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: text.bodySmall!.copyWith(color: player.problem != null ? brand.dangerOnInk : brand.snowSoft, fontSize: 12.5, height: 1.3),
      ),
    ]);
    final play = _InkPlay(player: player, size: wide ? 44 : 40);
    final content = wide
      ? Row(children: [
          Artwork(url: e.artwork, title: e.podcastTitle, size: 48, radius: 10),
          const SizedBox(width: 14),
          Expanded(child: title),
          const SizedBox(width: 16),
          _inkIcon(_skipIcon(settings.skipBack, forward: false), 'Back ${settings.skipBack.inSeconds} seconds', player.rewind),
          const SizedBox(width: 6),
          play,
          const SizedBox(width: 6),
          _inkIcon(_skipIcon(settings.skipForward, forward: true), 'Forward ${settings.skipForward.inSeconds} seconds', player.fastForward),
          const SizedBox(width: 18),
          _SpeedButton(player: player, compact: true),
          _SleepButton(player: player, compact: true),
          _inkIcon(Icons.keyboard_arrow_up_rounded, 'Now Playing', () async => open()),
        ])
      : Row(children: [
          Artwork(url: e.artwork, title: e.podcastTitle, size: 44, radius: 9),
          const SizedBox(width: 12),
          Expanded(child: title),
          _inkIcon(_skipIcon(settings.skipBack, forward: false), 'Back ${settings.skipBack.inSeconds} seconds', player.rewind),
          play,
        ]);
    return Padding(
      padding: wide ? const EdgeInsets.fromLTRB(16, 0, 16, 14) : const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: DecoratedBox(
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(20), boxShadow: const [brand.shadowFloat]),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: brand.inkSurface(
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                onTap: open,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Padding(padding: EdgeInsets.fromLTRB(10, wide ? 10 : 8, 10, wide ? 8 : 6), child: content),
                  _ThinProgress(player: player),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Widget _inkIcon(IconData icon, String tip, Future<void> Function() onPressed, {double size = 24}) => IconButton(
  tooltip: tip,
  onPressed: () => unawaited(onPressed()),
  style: IconButton.styleFrom(foregroundColor: brand.snow, hoverColor: brand.inkTile),
  icon: Icon(icon, size: size),
);

final class _InkPlay extends StatelessWidget {
  const _InkPlay({required this.player, required this.size});
  final Player player;
  final double size;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: player.playing ? 'Pause (Space)' : 'Play (Space)',
    waitDuration: const Duration(milliseconds: 500),
    child: SizedBox.square(
      dimension: size,
      child: IconButton(
        padding: EdgeInsets.zero,
        style: IconButton.styleFrom(backgroundColor: brand.white, foregroundColor: brand.ink, hoverColor: brand.paperDeep, shape: const CircleBorder()),
        onPressed: () => unawaited(player.toggle()),
        icon: player.loading
          ? SizedBox.square(dimension: size * 0.4, child: const CircularProgressIndicator(strokeWidth: 2.2, color: brand.ink))
          : Icon(player.playing ? Icons.pause_rounded : Icons.play_arrow_rounded, size: size * 0.6),
      ),
    ),
  );
}

/// The mini player's bottom edge, filling as the episode plays.
final class _ThinProgress extends StatelessWidget {
  const _ThinProgress({required this.player});
  final Player player;

  @override
  Widget build(BuildContext context) => StreamBuilder<Duration>(
    stream: player.positionStream,
    builder: (context, snapshot) {
      final total = player.duration;
      final at = snapshot.data ?? player.current?.position ?? Duration.zero;
      final value = total == null || total == Duration.zero ? 0.0 : (at.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
      return SizedBox(
        height: 3,
        child: LinearProgressIndicator(value: value, color: brand.accentLight, backgroundColor: brand.inkTile),
      );
    },
  );
}

// Now Playing.

final class NowPlaying extends StatelessWidget {
  const NowPlaying({super.key});

  @override
  Widget build(BuildContext context) {
    final s = Services.of(context);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.of(context).maybePop(),
      },
      child: playerKeys(
        player: s.player,
        back: const SingleActivator(LogicalKeyboardKey.arrowLeft),
        forward: const SingleActivator(LogicalKeyboardKey.arrowRight),
        child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: brand.ink,
          body: brand.inkSurface(
            child: SafeArea(
              child: ListenableBuilder(
                listenable: Listenable.merge([s.player, s.library]),
                builder: (context, _) {
                  final e = s.player.current;
                  if (e == null) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (context.mounted) Navigator.of(context).maybePop();
                    });
                    return const SizedBox.expand();
                  }
                  return LayoutBuilder(
                    builder: (context, box) => box.maxWidth >= 900
                      ? _wide(context, s, e, box)
                      : _narrow(context, s, e, box),
                  );
                },
              ),
            ),
          ),
        ),
        ),
      ),
    );
  }

  Widget _topBar(BuildContext context, PodcastEpisode e) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
    child: Row(children: [
      IconButton(
        tooltip: 'Close (Esc)',
        onPressed: () => Navigator.of(context).maybePop(),
        style: IconButton.styleFrom(foregroundColor: brand.snow, hoverColor: brand.inkTile),
        icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 30),
      ),
      const Spacer(),
      Text('Now Playing', style: Theme.of(context).textTheme.labelLarge!.copyWith(color: brand.snowSoft, fontSize: 13)),
      const Spacer(),
      EpisodeMenu(episode: e, showLink: true, color: brand.snow),
    ]),
  );

  Widget _identity(BuildContext context, PodcastEpisode e, {required TextAlign align}) {
    final text = Theme.of(context).textTheme;
    final cross = align == TextAlign.center ? CrossAxisAlignment.center : CrossAxisAlignment.start;
    return Column(crossAxisAlignment: cross, children: [
      Text(e.title, textAlign: align, maxLines: 3, overflow: TextOverflow.ellipsis, style: text.titleLarge!.copyWith(color: brand.snow, fontSize: 22, height: 1.2)),
      const SizedBox(height: 8),
      InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () {
          final navigation = Navigation.of(context);
          Navigator.of(context).maybePop();
          navigation.openShow(e.podcastId);
        },
        child: Text(e.from, textAlign: align, style: text.bodyMedium!.copyWith(color: brand.accentLight, fontWeight: FontWeight.w600)),
      ),
    ]);
  }

  Widget _controls(BuildContext context, Services s) {
    final player = s.player;
    final settings = s.library.settings;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      _Scrubber(player: player),
      const SizedBox(height: 12),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        _inkIcon(_skipIcon(settings.skipBack, forward: false), 'Back ${settings.skipBack.inSeconds} seconds', player.rewind, size: 34),
        const SizedBox(width: 22),
        _InkPlay(player: player, size: 72),
        const SizedBox(width: 22),
        _inkIcon(_skipIcon(settings.skipForward, forward: true), 'Forward ${settings.skipForward.inSeconds} seconds', player.fastForward, size: 34),
      ]),
      const SizedBox(height: 20),
      Wrap(alignment: WrapAlignment.center, spacing: 8, runSpacing: 8, children: [
        _SpeedButton(player: player),
        _SleepButton(player: player),
        _UpNextButton(library: s.library),
      ]),
      if (player.problem case final problem?) ...[
        const SizedBox(height: 16),
        Text(problem, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall!.copyWith(color: brand.dangerOnInk)),
      ],
    ]);
  }

  /// The cover, [width] wide: square, or a YouTube video's 16:9 frame.
  Widget _cover(PodcastEpisode e, double width) =>
    Artwork(url: e.artwork, title: e.podcastTitle, size: width, height: e.youtubeId == null ? null : width * 9 / 16, radius: 24);

  Widget _notes(BuildContext context, Services s, PodcastEpisode e) => ShowNotes(html: s.library.description(e.id), episode: e, onInk: true);

  Widget _narrow(BuildContext context, Services s, PodcastEpisode e, BoxConstraints box) {
    final cover = (box.maxWidth - 64).clamp(160.0, 420.0).toDouble();
    return Column(children: [
      _topBar(context, e),
      Expanded(
        child: ListView(padding: const EdgeInsets.fromLTRB(28, 12, 28, 40), children: [
          Center(
            child: DecoratedBox(
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(24), boxShadow: const [brand.shadowFloat]),
              child: _cover(e, cover),
            ),
          ),
          const SizedBox(height: 28),
          _identity(context, e, align: TextAlign.center),
          const SizedBox(height: 22),
          _controls(context, s),
          const SizedBox(height: 36),
          Text('Show notes', style: Theme.of(context).textTheme.titleLarge!.copyWith(color: brand.snow)),
          const SizedBox(height: 12),
          _notes(context, s, e),
        ]),
      ),
    ]);
  }

  Widget _wide(BuildContext context, Services s, PodcastEpisode e, BoxConstraints box) {
    return Column(children: [
      _topBar(context, e),
      Expanded(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(56, 8, 56, 32),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              flex: 5,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 480),
                  child: LayoutBuilder(builder: (context, column) {
                    // The cover takes what the title and every control
                    // leave, so all of them fit without scrolling.
                    final cover = (column.maxHeight - 390).clamp(140.0, 400.0).toDouble();
                    return SingleChildScrollView(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(minHeight: column.maxHeight),
                        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                          DecoratedBox(
                            decoration: BoxDecoration(borderRadius: BorderRadius.circular(24), boxShadow: const [brand.shadowFloat]),
                            child: _cover(e, e.youtubeId == null ? cover : (cover * 16 / 9).clamp(0, column.maxWidth).toDouble()),
                          ),
                          const SizedBox(height: 28),
                          _identity(context, e, align: TextAlign.center),
                          const SizedBox(height: 20),
                          _controls(context, s),
                        ]),
                      ),
                    );
                  }),
                ),
              ),
            ),
            const SizedBox(width: 48),
            Expanded(
              flex: 4,
              child: DecoratedBox(
                decoration: BoxDecoration(color: brand.inkTile, borderRadius: BorderRadius.circular(brand.radiusCard)),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(brand.radiusCard),
                  child: ListView(padding: const EdgeInsets.all(28), children: [
                    Text('Show notes', style: Theme.of(context).textTheme.titleLarge!.copyWith(color: brand.snow)),
                    const SizedBox(height: 14),
                    _notes(context, s, e),
                  ]),
                ),
              ),
            ),
          ]),
        ),
      ),
    ]);
  }
}

/// The scrubber: drag to seek, the time gone and the time left.
final class _Scrubber extends StatefulWidget {
  const _Scrubber({required this.player});
  final Player player;

  @override
  State<_Scrubber> createState() => _ScrubberState();
}

final class _ScrubberState extends State<_Scrubber> {
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final time = text.bodySmall!.copyWith(color: brand.snowSoft, fontSize: 12.5, fontFeatures: const [FontFeature.tabularFigures()]);
    return StreamBuilder<Duration>(
      stream: widget.player.positionStream,
      builder: (context, snapshot) {
        final total = widget.player.duration ?? Duration.zero;
        final at = snapshot.data ?? widget.player.current?.position ?? Duration.zero;
        final ms = total.inMilliseconds.toDouble();
        final value = _dragging ?? (ms == 0 ? 0.0 : at.inMilliseconds.clamp(0, ms).toDouble());
        final shown = Duration(milliseconds: value.round());
        return Column(children: [
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 4,
              activeTrackColor: brand.accentLight,
              inactiveTrackColor: brand.inkLine,
              thumbColor: brand.white,
              overlayColor: brand.accentLight.withValues(alpha: 0.16),
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
              trackShape: const RoundedRectSliderTrackShape(),
            ),
            child: Slider(
              value: value,
              max: ms == 0 ? 1 : ms,
              onChanged: ms == 0 ? null : (v) => setState(() => _dragging = v),
              onChangeEnd: (v) {
                setState(() => _dragging = null);
                unawaited(widget.player.seek(Duration(milliseconds: v.round())));
              },
              semanticFormatterCallback: (v) => clock(Duration(milliseconds: v.round())),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(children: [
              Text(clock(shown), style: time),
              const Spacer(),
              Text(total == Duration.zero ? '--:--' : '-${clock(total - shown)}', style: time),
            ]),
          ),
        ]);
      },
    );
  }
}

/// A pill on ink: the speed chip's shape (DESIGN.md "Chips and tags").
Widget _pill(BuildContext context, {required IconData icon, required String label, required bool active, required VoidCallback onTap, bool compact = false}) {
  final text = Theme.of(context).textTheme;
  if (compact) {
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        foregroundColor: active ? brand.accentLight : brand.snow,
        minimumSize: const Size(0, 36),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: text.labelLarge!.copyWith(fontSize: 13, fontFeatures: const [FontFeature.tabularFigures()]),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(icon, size: 18), const SizedBox(width: 6), Text(label)]),
    );
  }
  return TextButton(
    onPressed: onTap,
    style: TextButton.styleFrom(
      backgroundColor: active ? brand.accent : brand.inkTile,
      foregroundColor: active ? brand.white : brand.snow,
      minimumSize: const Size(0, 38),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      shape: StadiumBorder(side: BorderSide(color: active ? brand.accent : brand.inkLine)),
      textStyle: text.labelLarge!.copyWith(fontSize: 13.5, fontFeatures: const [FontFeature.tabularFigures()]),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(icon, size: 18), const SizedBox(width: 7), Text(label)]),
  );
}

final class _SpeedButton extends StatelessWidget {
  const _SpeedButton({required this.player, this.compact = false});
  final Player player;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final speed = player.speed;
    return MenuAnchor(
      style: menuStyle,
      menuChildren: [
        for (final s in speeds)
          MenuItemButton(
            leadingIcon: Icon(Icons.check_rounded, size: 18, color: (s - speed).abs() < 0.01 ? brand.accent : const Color(0x00000000)),
            onPressed: () => unawaited(player.setSpeed(s)),
            child: Text(
              s == 1.0 ? '1× · Normal' : speedLabel(s),
              style: Theme.of(context).textTheme.bodyMedium!.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
            ),
          ),
      ],
      builder: (context, menu, _) => Tooltip(
        message: 'Playback speed',
        child: _pill(
          context,
          icon: Icons.speed_rounded,
          label: speedLabel(speed),
          active: (speed - 1).abs() > 0.01,
          compact: compact,
          onTap: () => menu.isOpen ? menu.close() : menu.open(),
        ),
      ),
    );
  }
}

final class _SleepButton extends StatefulWidget {
  const _SleepButton({required this.player, this.compact = false});
  final Player player;
  final bool compact;

  @override
  State<_SleepButton> createState() => _SleepButtonState();
}

final class _SleepButtonState extends State<_SleepButton> {
  @override
  Widget build(BuildContext context) {
    final player = widget.player;
    final sleep = player.sleep;
    final label = switch (sleep) {
      SleepAt(:final at) => clock(at.difference(DateTime.now()) + const Duration(milliseconds: 999)),
      SleepAtEnd() => 'End of episode',
      null => widget.compact ? '' : 'Sleep timer',
    };
    final text = Theme.of(context).textTheme.bodyMedium;
    return MenuAnchor(
      style: menuStyle,
      menuChildren: [
        if (sleep is SleepAt) ...[
          MenuItemButton(
            onPressed: () => player.extendSleep(const Duration(minutes: 5)),
            child: Text('5 more minutes', style: text),
          ),
          const Divider(height: 9, color: brand.line),
        ],
        for (final minutes in const [5, 10, 15, 30, 45, 60, 90])
          MenuItemButton(
            onPressed: () => player.setSleep(SleepAt(DateTime.now().add(Duration(minutes: minutes)), Duration(minutes: minutes))),
            child: Text(minutes < 60 ? 'In $minutes minutes' : (minutes == 60 ? 'In 1 hour' : 'In 1 hour 30 minutes'), style: text),
          ),
        MenuItemButton(
          onPressed: () => player.setSleep(const SleepAtEnd()),
          child: Text('At the end of this episode', style: text),
        ),
        if (sleep != null) ...[
          const Divider(height: 9, color: brand.line),
          MenuItemButton(
            onPressed: () => player.setSleep(null),
            child: Text('Turn off', style: text),
          ),
        ],
      ],
      builder: (context, menu, _) => Tooltip(
        message: 'Sleep timer',
        child: _pill(
          context,
          icon: sleep == null ? Icons.bedtime_outlined : Icons.bedtime_rounded,
          label: label,
          active: sleep != null,
          compact: widget.compact,
          onTap: () => menu.isOpen ? menu.close() : menu.open(),
        ),
      ),
    );
  }
}

final class _UpNextButton extends StatelessWidget {
  const _UpNextButton({required this.library});
  final Library library;

  @override
  Widget build(BuildContext context) {
    final count = library.queue.length;
    return _pill(
      context,
      icon: Icons.queue_music_rounded,
      label: count == 0 ? 'Up Next' : 'Up Next · $count',
      active: false,
      onTap: () => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: brand.paper,
        showDragHandle: true,
        constraints: const BoxConstraints(maxWidth: 720),
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(brand.radiusSheet))),
        builder: (context) => ListenableBuilder(
          listenable: library,
          builder: (context, _) {
            final empty = library.queue.isEmpty;
            final header = Padding(
              padding: const EdgeInsets.fromLTRB(28, 0, 16, 4),
              child: Row(children: [
                Text('Up Next', style: Theme.of(context).textTheme.titleLarge),
                const Spacer(),
                if (!empty)
                  TextButton(
                    style: brand.button(brand.Tone.quiet, brand.ButtonSize.sm),
                    onPressed: library.clearQueue,
                    child: const Text('Clear'),
                  ),
              ]),
            );
            // Empty, the sheet is only as tall as what it says.
            if (empty) {
              return Column(mainAxisSize: MainAxisSize.min, children: [
                header,
                const UpNextList(padding: EdgeInsets.fromLTRB(16, 0, 16, 28)),
              ]);
            }
            return FractionallySizedBox(
              heightFactor: 0.75,
              child: Column(children: [
                header,
                const Expanded(child: UpNextList(padding: EdgeInsets.fromLTRB(16, 0, 16, 24))),
              ]),
            );
          },
        ),
      ),
    );
  }
}

/// Up Next as a reorderable list: drag to reorder, swipe or ✕ to remove.
final class UpNextList extends StatelessWidget {
  const UpNextList({super.key, this.padding = EdgeInsets.zero, this.shrinkWrap = false});
  final EdgeInsets padding;
  final bool shrinkWrap;

  @override
  Widget build(BuildContext context) {
    final library = Services.of(context).library;
    return ListenableBuilder(
      listenable: library,
      builder: (context, _) {
        final queue = library.queue;
        if (queue.isEmpty) {
          return Padding(
            padding: padding.add(const EdgeInsets.all(12)),
            child: Text(
              'Nothing up next. Choose “Play next” or “Play last” on any episode, and it waits here, in order.',
              style: Theme.of(context).textTheme.bodyMedium!.copyWith(color: brand.fgSoft),
            ),
          );
        }
        return ReorderableListView.builder(
          padding: padding,
          shrinkWrap: shrinkWrap,
          physics: shrinkWrap ? const NeverScrollableScrollPhysics() : null,
          buildDefaultDragHandles: false,
          itemCount: queue.length,
          onReorderItem: library.reorder,
          proxyDecorator: (child, _, _) => Material(
            color: brand.white,
            elevation: 0,
            borderRadius: BorderRadius.circular(14),
            shadowColor: const Color(0x00000000),
            child: DecoratedBox(
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), boxShadow: const [brand.shadowSoft]),
              child: child,
            ),
          ),
          itemBuilder: (context, i) {
            final e = queue[i];
            return Dismissible(
              key: ValueKey(e.id),
              direction: DismissDirection.endToStart,
              onDismissed: (_) => library.dequeue(e.id),
              background: Container(
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 24),
                decoration: BoxDecoration(color: const Color(0x14D4483F), borderRadius: BorderRadius.circular(14)),
                child: const Icon(Icons.playlist_remove_rounded, color: brand.danger),
              ),
              child: Row(children: [
                ReorderableDragStartListener(
                  index: i,
                  child: const MouseRegion(
                    cursor: SystemMouseCursors.grab,
                    child: Padding(padding: EdgeInsets.all(8), child: Icon(Icons.drag_indicator_rounded, color: brand.fgFaint)),
                  ),
                ),
                Expanded(
                  child: EpisodeRow(
                    episode: e,
                    withShow: true,
                    trailing: IconButton(
                      tooltip: 'Remove from Up Next',
                      onPressed: () => library.dequeue(e.id),
                      icon: const Icon(Icons.close_rounded, size: 20, color: brand.fgSoft),
                    ),
                  ),
                ),
              ]),
            );
          },
        );
      },
    );
  }
}
