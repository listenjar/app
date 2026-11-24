// What's playing, on ink (DESIGN.md: ink carries the moments that sell
// listening): the mini player under every section, and Now Playing, which
// it opens. Now Playing holds the cover, the scrubber, skip and play, the
// speed, the sleep timer, Up Next, a video's chapters and the show notes.
import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/physics.dart' show Simulation;
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'backend/api.dart' show Plan;
import 'chapters.dart';
import 'library.dart';
import 'menu.dart';
import 'player.dart';
import 'shared_links.dart' show addVideoToOwnPodcast, ownPodcasts;
import 'theme.dart' as brand;
import 'ui.dart';

/// Opens Now Playing over the window, rising from the mini player.
Future<void> showNowPlaying(BuildContext context) => Navigator.of(context, rootNavigator: true).push(_NowPlayingRoute());

/// Now Playing's page: it rises from the mini player, and a swipe down
/// carries it under the finger, back down to the mini player when let go
/// low enough or flicked down, back up otherwise. A swipe up on the mini
/// player lifts it out the same way.
final class _NowPlayingRoute extends PageRoute<void> {
  @override
  Color? get barrierColor => null;
  @override
  String? get barrierLabel => null;
  @override
  bool get maintainState => true;
  @override
  Duration get transitionDuration => const Duration(milliseconds: 320);
  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 220);

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) => const NowPlaying();

  @override
  Widget buildTransitions(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation, Widget child) {
    // Under a finger, the page is wherever the finger put it.
    final Animation<double> position;
    if (navigator?.userGestureInProgress ?? false) {
      position = animation;
    } else if (MediaQuery.disableAnimationsOf(context)) {
      return FadeTransition(opacity: animation, child: child);
    } else {
      position = CurvedAnimation(parent: animation, curve: brand.easeOutExpo, reverseCurve: Curves.easeInCubic);
    }
    return SlideTransition(position: Tween(begin: const Offset(0, 1), end: Offset.zero).animate(position), child: child);
  }

  /// Pushes Now Playing at the bottom of the window, held by a swipe up
  /// out of the mini player; null if another gesture holds the navigator.
  static _NowPlayingRoute? lift(BuildContext context) {
    final nav = Navigator.of(context, rootNavigator: true);
    if (nav.userGestureInProgress) return null;
    final route = _NowPlayingRoute().._lifted = true;
    unawaited(nav.push(route));
    // The finger has it, not the rise push started.
    route.controller!.value = 0;
    route._grab();
    return route;
  }

  bool _swiping = false;

  /// Whether the swipe holding the page started at the mini player.
  bool _lifted = false;

  /// Whether a swipe holds the page.
  bool get swiping => _swiping;

  bool _grab() {
    final nav = navigator;
    if (nav == null || !isCurrent || nav.userGestureInProgress) return false;
    _swiping = true;
    nav.didStartUserGesture();
    return true;
  }

  /// The height the page travels: the window's.
  double get _height => navigator?.context.size?.height ?? 0;

  /// Moves the page down by [dy] logical pixels, up when negative, no higher
  /// than open; returns how much of [dy] it took. A swipe starts only
  /// going down.
  double swipe(double dy) {
    final height = _height;
    if (height <= 0) return 0;
    if (!_swiping && (dy <= 0 || !_grab())) return 0;
    final c = controller!;
    final before = c.value;
    c.value = (before - dy / height).clamp(0.0, 1.0);
    return (before - c.value) * height;
  }

  /// Lets the page go with the finger moving down at [velocity] logical
  /// pixels a second: a flick goes the way it points; a page let go a third
  /// of the way from where the swipe started goes on, anything else back.
  void release(double velocity) {
    if (!_swiping) return;
    _swiping = false;
    final nav = navigator!;
    final c = controller!;
    final height = _height;
    const flick = 400.0;
    final down = velocity > flick || (velocity > -flick && c.value < (_lifted ? 1 / 3 : 2 / 3));
    _lifted = false;
    if (down) {
      nav.pop();
      c.animateBack(0, duration: _settle(c.value * height, velocity), curve: Curves.easeOutCubic);
    } else {
      c.animateTo(1, duration: _settle((1 - c.value) * height, -velocity), curve: Curves.easeOutCubic);
    }
    // The page stays linear till it lands, so the curve doesn't jump it.
    if (!c.isAnimating) return nav.didStopUserGesture();
    late final AnimationStatusListener landed;
    landed = (status) {
      if (status.isAnimating) return;
      c.removeStatusListener(landed);
      nav.didStopUserGesture();
    };
    c.addStatusListener(landed);
  }

  /// How long [px] takes to cover leaving at [speed]: an ease out cubic
  /// starts at three times its average speed.
  static Duration _settle(double px, double speed) {
    final seconds = 3 * px / (speed < 1500 ? 1500 : speed);
    return Duration(milliseconds: (seconds * 1000).clamp(140, 360).round());
  }

  @override
  void dispose() {
    if (_swiping) navigator?.didStopUserGesture();
    super.dispose();
  }
}

/// Lets a swipe down past the top of a scroll view carry Now Playing down,
/// and a swipe back up lift it before the content scrolls.
final class _SwipePhysics extends ScrollPhysics {
  const _SwipePhysics(this.route, {super.parent});
  final _NowPlayingRoute route;

  @override
  _SwipePhysics applyTo(ScrollPhysics? ancestor) => _SwipePhysics(route, parent: buildParent(ancestor));

  // Content that fits still swipes the page.
  @override
  bool shouldAcceptUserOffset(ScrollMetrics position) => true;

  @override
  double applyPhysicsToUserOffset(ScrollMetrics position, double offset) {
    if (offset > 0) {
      // Down: the content scrolls back to its top, then the page follows.
      final room = position.pixels > position.minScrollExtent ? position.pixels - position.minScrollExtent : 0.0;
      if (offset > room) offset = room + (offset - room - route.swipe(offset - room));
    } else {
      // Up: the page goes back up, then the content scrolls.
      offset -= route.swipe(offset);
    }
    return super.applyPhysicsToUserOffset(position, offset);
  }

  @override
  Simulation? createBallisticSimulation(ScrollMetrics position, double velocity) {
    if (!route.swiping) return super.createBallisticSimulation(position, velocity);
    route.release(-velocity);
    return super.createBallisticSimulation(position, 0);
  }
}

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
      child: _Lift(child: DecoratedBox(
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(20), boxShadow: const [brand.shadowFloat]),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: brand.inkSurface(
            child: Material(
              type: MaterialType.transparency,
              // The seek strip sits over the bar's bottom edge, above the
              // InkWell, so a click or drag there seeks instead of opening
              // Now Playing.
              child: Stack(children: [
                InkWell(
                  onTap: open,
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Padding(padding: EdgeInsets.fromLTRB(10, wide ? 10 : 8, 10, wide ? 8 : 6), child: content),
                    const SizedBox(height: _SeekLine.rest),
                  ]),
                ),
                Positioned(left: 0, right: 0, bottom: 0, height: _SeekLine.reach, child: _SeekLine(player: player)),
              ]),
            ),
          ),
        ),
      )),
    );
  }
}

/// A swipe up on the mini player lifts Now Playing out of it under the
/// finger, for any pointer: it opens when let go a third of the way up or
/// flicked up, and goes back down otherwise.
final class _Lift extends StatefulWidget {
  const _Lift({required this.child});
  final Widget child;

  @override
  State<_Lift> createState() => _LiftState();
}

final class _LiftState extends State<_Lift> {
  _NowPlayingRoute? _route;

  void _update(DragUpdateDetails d) {
    if (_route == null && d.delta.dy < 0) _route = _NowPlayingRoute.lift(context);
    _route?.swipe(d.delta.dy);
  }

  void _release(double velocity) {
    _route?.release(velocity);
    _route = null;
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    onVerticalDragUpdate: _update,
    onVerticalDragEnd: (d) => _release(d.primaryVelocity ?? 0),
    onVerticalDragCancel: () => _release(0),
    child: widget.child,
  );
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

/// The mini player's bottom edge, filling as the episode plays. Click or drag
/// it to seek: on hover it thickens, shades up to the pointer and shows the
/// time there.
final class _SeekLine extends StatefulWidget {
  const _SeekLine({required this.player});
  final Player player;

  /// The line's thickness at rest and under the pointer.
  static const rest = 3.0;
  static const active = 6.0;

  /// How far above the bar's bottom edge the strip takes the pointer.
  static const reach = 14.0;

  @override
  State<_SeekLine> createState() => _SeekLineState();
}

final class _SeekLineState extends State<_SeekLine> {
  final _bubble = OverlayPortalController();

  /// Where the pointer is along the line, 0 to 1, while it hovers.
  double? _hover;

  /// Where a drag has the head, 0 to 1, until it lets go.
  double? _drag;

  Duration? get _total {
    final total = widget.player.duration;
    return total == null || total == Duration.zero ? null : total;
  }

  double _fraction(Offset local) {
    final width = (context.findRenderObject()! as RenderBox).size.width;
    return width == 0 ? 0 : (local.dx / width).clamp(0.0, 1.0);
  }

  Duration _at(Duration total, double fraction) => Duration(milliseconds: (total.inMilliseconds * fraction).round());

  void _point(double? fraction) {
    setState(() => _hover = fraction);
    if (fraction != null || _drag != null) {
      _bubble.show();
    } else {
      _bubble.hide();
    }
  }

  void _seek(double fraction) {
    final total = _total;
    if (total != null) unawaited(widget.player.seek(_at(total, fraction)));
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<Duration>(
    stream: widget.player.positionStream,
    builder: (context, snapshot) {
      final total = _total;
      final at = snapshot.data ?? widget.player.current?.position ?? Duration.zero;
      final played = _drag ?? (total == null ? 0.0 : (at.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0));
      final hot = total != null && (_hover != null || _drag != null);
      final line = Align(
        alignment: Alignment.bottomCenter,
        child: AnimatedContainer(
          duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 160),
          curve: brand.easeOutExpo,
          height: hot ? _SeekLine.active : _SeekLine.rest,
          child: CustomPaint(
            size: Size.infinite,
            painter: _SeekPainter(
              played: played,
              pointer: _drag == null ? _hover : null,
              marks: total == null ? const [] : [for (final c in widget.player.chapters.skip(1)) c.start.inMilliseconds / total.inMilliseconds],
            ),
          ),
        ),
      );
      if (total == null) return line;
      return Semantics(
        slider: true,
        label: 'Seek',
        value: clock(_at(total, played)),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onHover: (e) => _point(_fraction(e.localPosition)),
          onExit: (_) => _point(null),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) => _seek(_fraction(d.localPosition)),
            onHorizontalDragStart: (d) {
              setState(() => _drag = _fraction(d.localPosition));
              _bubble.show();
            },
            onHorizontalDragUpdate: (d) => setState(() => _drag = _fraction(d.localPosition)),
            onHorizontalDragEnd: (_) {
              final to = _drag;
              setState(() => _drag = null);
              if (to != null) _seek(to);
              if (_hover == null) _bubble.hide();
            },
            onHorizontalDragCancel: () {
              setState(() => _drag = null);
              if (_hover == null) _bubble.hide();
            },
            child: OverlayPortal(
              controller: _bubble,
              overlayChildBuilder: (overlayContext) => _timeBubble(overlayContext, total, _drag ?? _hover),
              child: line,
            ),
          ),
        ),
      );
    },
  );

  /// The time under the pointer, floating just above the line.
  Widget _timeBubble(BuildContext overlayContext, Duration total, double? fraction) {
    final box = context.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (fraction == null || box == null || overlay == null || !box.attached) return const SizedBox.shrink();
    final origin = box.localToGlobal(Offset.zero, ancestor: overlay);
    final x = origin.dx + box.size.width * fraction;
    final at = _at(total, fraction);
    final chapters = widget.player.chapters;
    final chapter = chapterAt(chapters, at);
    final bottom = overlay.size.height - (origin.dy + box.size.height - _SeekLine.active - 6);
    final style = Theme.of(context).textTheme.labelMedium!.copyWith(
      color: brand.ink,
      fontSize: 12,
      fontWeight: FontWeight.w600,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Positioned(
      left: x,
      bottom: bottom,
      child: IgnorePointer(
        child: FractionalTranslation(
          translation: const Offset(-0.5, 0),
          child: DecoratedBox(
            decoration: BoxDecoration(color: brand.white, borderRadius: BorderRadius.circular(7), boxShadow: const [brand.shadowFloat]),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 280),
                child: Text(
                  chapter < 0 ? clock(at) : '${clock(at)} · ${chapters[chapter].title}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: style,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _SeekPainter extends CustomPainter {
  _SeekPainter({required this.played, required this.pointer, required this.marks});
  final double played;
  final double? pointer;

  /// Where chapters start, 0 to 1: cut out of the line.
  final List<double> marks;

  @override
  void paint(Canvas canvas, Size size) {
    if (marks.isNotEmpty) canvas.saveLayer(Offset.zero & size, Paint());
    canvas.drawRect(Offset.zero & size, Paint()..color = brand.inkTile);
    final p = pointer;
    if (p != null && p > played) {
      canvas.drawRect(Rect.fromLTRB(size.width * played, 0, size.width * p, size.height), Paint()..color = brand.snow.withValues(alpha: 0.22));
    }
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width * played, size.height), Paint()..color = brand.accentLight);
    if (marks.isEmpty) return;
    final cut = Paint()..blendMode = BlendMode.clear;
    for (final mark in marks) {
      canvas.drawRect(Rect.fromLTWH(size.width * mark - 1, 0, 2, size.height), cut);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SeekPainter old) => old.played != played || old.pointer != pointer || !listEquals(old.marks, marks);
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

  /// Now Playing's route, when it's on one that swipes.
  static _NowPlayingRoute? _route(BuildContext context) => switch (ModalRoute.of(context)) {
    final _NowPlayingRoute route => route,
    _ => null,
  };

  /// The physics for a scroll view that swipes the page down past its top,
  /// under a finger, a pen or two fingers on a trackpad.
  static ScrollPhysics? _physics(BuildContext context) => switch (_route(context)) {
    final route? => _SwipePhysics(route),
    _ => null,
  };

  /// Lets a drag of [devices] (any, if null) on [child] carry the page.
  static Widget _grip(BuildContext context, Widget child, {Set<PointerDeviceKind>? devices}) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    supportedDevices: devices,
    onVerticalDragUpdate: (d) => _route(context)?.swipe(d.delta.dy),
    onVerticalDragEnd: (d) => _route(context)?.release(d.primaryVelocity ?? 0),
    onVerticalDragCancel: () => _route(context)?.release(0),
    child: child,
  );

  /// A mouse doesn't scroll by dragging, so it carries the page from the
  /// player too: the cover, the title and the controls. Not the show notes,
  /// where it selects text.
  static Widget _mouseGrip(BuildContext context, Widget child) => _grip(context, child, devices: const {PointerDeviceKind.mouse});

  // The top bar is the page's handle, for any pointer.
  Widget _topBar(BuildContext context, PodcastEpisode e) => _grip(
    context,
    Padding(
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
      if (episodeUrl(e) case final url?)
        Builder(
          builder: (context) => IconButton(
            tooltip: e.youtubeId == null ? 'Share' : 'Share YouTube link',
            onPressed: () => unawaited(shareLink(context, url, title: e.title)),
            style: IconButton.styleFrom(foregroundColor: brand.snow, hoverColor: brand.inkTile),
            icon: Icon(Icons.adaptive.share, size: 22),
          ),
        ),
      EpisodeMenu(episode: e, showLink: true, tone: MenuTone.ink),
    ]),
    ),
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
        if (player.current case final e? when e.youtubeId != null) _AddVideoButton(episode: e),
      ]),
      if (player.problem case final problem?) ...[
        const SizedBox(height: 16),
        Text(problem, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall!.copyWith(color: brand.dangerOnInk)),
      ],
    ]);
  }

  /// The cover, [width] wide: square, or a video's 16:9 frame.
  Widget _cover(PodcastEpisode e, double width) =>
    Artwork(url: e.cover, fallbackUrl: e.coverFallback, title: e.podcastTitle, size: width, height: e.widescreen ? width * 9 / 16 : null, radius: 24);

  Widget _notes(BuildContext context, Services s, PodcastEpisode e) => ShowNotes(html: s.library.description(e.id), episode: e, onInk: true);

  Widget _narrow(BuildContext context, Services s, PodcastEpisode e, BoxConstraints box) {
    final cover = (box.maxWidth - 64).clamp(160.0, 420.0).toDouble();
    return Column(children: [
      _topBar(context, e),
      Expanded(
        child: ListView(physics: _physics(context), padding: const EdgeInsets.fromLTRB(28, 12, 28, 40), children: [
          _mouseGrip(context, Column(children: [
            DecoratedBox(
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(24), boxShadow: const [brand.shadowFloat]),
              child: _cover(e, cover),
            ),
            const SizedBox(height: 28),
            _identity(context, e, align: TextAlign.center),
            const SizedBox(height: 22),
            _controls(context, s),
          ])),
          if (s.player.chapters case final chapters when chapters.isNotEmpty) ...[
            const SizedBox(height: 36),
            Text('Chapters', style: Theme.of(context).textTheme.titleLarge!.copyWith(color: brand.snow)),
            const SizedBox(height: 8),
            _ChapterList(player: s.player, chapters: chapters),
          ],
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
                      physics: _physics(context),
                      child: _mouseGrip(context, ConstrainedBox(
                        constraints: BoxConstraints(minHeight: column.maxHeight),
                        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                          DecoratedBox(
                            decoration: BoxDecoration(borderRadius: BorderRadius.circular(24), boxShadow: const [brand.shadowFloat]),
                            child: _cover(e, e.widescreen ? (cover * 16 / 9).clamp(0, column.maxWidth).toDouble() : cover),
                          ),
                          const SizedBox(height: 28),
                          _identity(context, e, align: TextAlign.center),
                          const SizedBox(height: 20),
                          _controls(context, s),
                        ]),
                      )),
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
                  child: _SidePanel(key: ValueKey(e.id), player: s.player, notes: _notes(context, s, e)),
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
        final chapters = ms == 0 ? const <Chapter>[] : widget.player.chapters;
        return Column(children: [
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 4,
              activeTrackColor: brand.accentLight,
              inactiveTrackColor: brand.inkLine,
              thumbColor: brand.white,
              overlayColor: brand.accentLight.withValues(alpha: 0.16),
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
              trackShape: chapters.isEmpty
                ? const RoundedRectSliderTrackShape()
                : _ChapterTrack([for (final c in chapters.skip(1)) c.start.inMilliseconds / ms]),
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
              Expanded(
                child: chapters.isEmpty
                  ? const SizedBox.shrink()
                  : _ChapterNav(player: widget.player, chapters: chapters, at: shown),
              ),
              Text(total == Duration.zero ? '--:--' : '-${clock(total - shown)}', style: time),
            ]),
          ),
        ]);
      },
    );
  }
}

/// The slider's track, cut where each chapter after the first starts.
final class _ChapterTrack extends RoundedRectSliderTrackShape {
  const _ChapterTrack(this.marks);

  /// Where the chapters start, 0 to 1 along the track.
  final List<double> marks;

  /// The cut's width.
  static const _gap = 3.0;

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 2,
  }) {
    final track = getPreferredRect(parentBox: parentBox, offset: offset, sliderTheme: sliderTheme, isEnabled: isEnabled, isDiscrete: isDiscrete);
    final canvas = context.canvas;
    // Cut through to what's under the slider, not painted over in a colour.
    canvas.saveLayer(track.inflate(additionalActiveTrackHeight + 2), Paint());
    super.paint(
      context,
      offset,
      parentBox: parentBox,
      sliderTheme: sliderTheme,
      enableAnimation: enableAnimation,
      textDirection: textDirection,
      thumbCenter: thumbCenter,
      secondaryOffset: secondaryOffset,
      isDiscrete: isDiscrete,
      isEnabled: isEnabled,
      additionalActiveTrackHeight: additionalActiveTrackHeight,
    );
    final cut = Paint()..blendMode = BlendMode.clear;
    for (final mark in marks) {
      final x = textDirection == TextDirection.rtl ? track.right - track.width * mark : track.left + track.width * mark;
      canvas.drawRect(Rect.fromLTRB(x - _gap / 2, track.top - additionalActiveTrackHeight - 2, x + _gap / 2, track.bottom + additionalActiveTrackHeight + 2), cut);
    }
    canvas.restore();
  }
}

/// The chapter at [at], between the scrubber's times, with the previous and
/// next chapter on either side.
final class _ChapterNav extends StatelessWidget {
  const _ChapterNav({required this.player, required this.chapters, required this.at});
  final Player player;
  final List<Chapter> chapters;
  final Duration at;

  @override
  Widget build(BuildContext context) {
    final i = chapterAt(chapters, at);
    final style = Theme.of(context).textTheme.labelLarge!.copyWith(color: brand.snow, fontSize: 13);
    Widget skip(IconData icon, String tip, Future<void> Function()? onPressed) => IconButton(
      tooltip: tip,
      onPressed: onPressed == null ? null : () => unawaited(onPressed()),
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 32, height: 32),
      style: IconButton.styleFrom(foregroundColor: brand.snowSoft, disabledForegroundColor: brand.inkLine, hoverColor: brand.inkTile),
      icon: Icon(icon, size: 20),
    );
    return Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      skip(Icons.chevron_left_rounded, 'Previous chapter', i < 0 ? null : player.previousChapter),
      Flexible(
        child: Semantics(
          label: i < 0 ? null : 'Chapter ${i + 1} of ${chapters.length}',
          child: Text(i < 0 ? '' : chapters[i].title, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: style),
        ),
      ),
      skip(Icons.chevron_right_rounded, 'Next chapter', i + 1 < chapters.length ? player.nextChapter : null),
    ]);
  }
}

/// A video's chapters: where each starts and what it is, the one playing
/// marked. Choosing one plays from there.
final class _ChapterList extends StatelessWidget {
  const _ChapterList({required this.player, required this.chapters});
  final Player player;
  final List<Chapter> chapters;

  Future<void> _play(Chapter chapter) async {
    await player.seek(chapter.start);
    if (!player.playing) await player.play();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return StreamBuilder<int>(
      stream: player.positionStream.map((p) => chapterAt(chapters, p)).distinct(),
      initialData: chapterAt(chapters, player.position),
      builder: (context, snapshot) {
        final playing = snapshot.data ?? -1;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final (i, c) in chapters.indexed)
            Semantics(
              button: true,
              selected: i == playing,
              child: Material(
                type: MaterialType.transparency,
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  hoverColor: brand.inkTile,
                  onTap: () => unawaited(_play(c)),
                  child: Ink(
                    decoration: BoxDecoration(
                      color: i == playing ? brand.inkLine : brand.inkLine.withValues(alpha: 0),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      SizedBox(
                        width: 64,
                        child: Text(
                          clock(c.start),
                          style: text.bodyMedium!.copyWith(
                            color: i == playing ? brand.accentLight : brand.snowSoft,
                            fontWeight: FontWeight.w600,
                            height: 1.45,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          c.title,
                          style: text.bodyMedium!.copyWith(
                            color: brand.snow,
                            fontWeight: i == playing ? FontWeight.w600 : FontWeight.w400,
                            height: 1.45,
                          ),
                        ),
                      ),
                    ]),
                  ),
                ),
              ),
            ),
        ]);
      },
    );
  }
}

/// Beside the player on a wide window: the show notes, and a video's
/// chapters in a tab before them.
final class _SidePanel extends StatefulWidget {
  const _SidePanel({super.key, required this.player, required this.notes});
  final Player player;
  final Widget notes;

  @override
  State<_SidePanel> createState() => _SidePanelState();
}

final class _SidePanelState extends State<_SidePanel> {
  bool _notes = false;

  @override
  Widget build(BuildContext context) {
    final chapters = widget.player.chapters;
    final heading = Theme.of(context).textTheme.titleLarge!;
    if (chapters.isEmpty) {
      return ListView(padding: const EdgeInsets.all(28), children: [
        Text('Show notes', style: heading.copyWith(color: brand.snow)),
        const SizedBox(height: 14),
        widget.notes,
      ]);
    }
    Widget tab(String label, bool selected, bool notes) => Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        hoverColor: brand.inkTile,
        onTap: () => setState(() => _notes = notes),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Text(label, style: heading.copyWith(color: selected ? brand.snow : brand.snowFaint)),
        ),
      ),
    );
    return ListView(padding: const EdgeInsets.fromLTRB(20, 24, 20, 28), children: [
      Row(children: [
        tab('Chapters', !_notes, false),
        const SizedBox(width: 8),
        tab('Show notes', _notes, true),
      ]),
      const SizedBox(height: 12),
      if (_notes)
        Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: widget.notes)
      else
        _ChapterList(player: widget.player, chapters: chapters),
    ]);
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
    return Dropdown(
      tone: MenuTone.ink,
      items: [
        for (final s in speeds)
          MenuEntry(
            s == 1.0 ? '1× · Normal' : speedLabel(s),
            checked: (s - speed).abs() < 0.01,
            tabular: true,
            onPressed: () => unawaited(player.setSpeed(s)),
          ),
      ],
      builder: (context, menu) => Tooltip(
        message: 'Playback speed',
        child: _pill(
          context,
          icon: Icons.speed_rounded,
          label: speedLabel(speed),
          active: (speed - 1).abs() > 0.01,
          compact: compact,
          onTap: menu.toggle,
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
    return Dropdown(
      tone: MenuTone.ink,
      items: [
        if (sleep is SleepAt) ...[
          MenuEntry('5 more minutes', icon: Icons.more_time_rounded, onPressed: () => player.extendSleep(const Duration(minutes: 5))),
          const MenuDivider(),
        ],
        const MenuHeader('Stop playing'),
        for (final minutes in const [5, 10, 15, 30, 45, 60, 90])
          MenuEntry(
            minutes < 60 ? 'In $minutes minutes' : (minutes == 60 ? 'In 1 hour' : 'In 1 hour 30 minutes'),
            checked: sleep is SleepAt && sleep.length == Duration(minutes: minutes),
            tabular: true,
            onPressed: () => player.setSleep(SleepAt(DateTime.now().add(Duration(minutes: minutes)), Duration(minutes: minutes))),
          ),
        MenuEntry('At the end of this episode', checked: sleep is SleepAtEnd, onPressed: () => player.setSleep(const SleepAtEnd())),
        if (sleep != null) ...[
          const MenuDivider(),
          MenuEntry('Turn off', icon: Icons.timer_off_outlined, onPressed: () => player.setSleep(null)),
        ],
      ],
      builder: (context, menu) => Tooltip(
        message: 'Sleep timer',
        child: _pill(
          context,
          icon: sleep == null ? Icons.bedtime_outlined : Icons.bedtime_rounded,
          label: label,
          active: sleep != null,
          compact: widget.compact,
          onTap: menu.toggle,
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

/// Where a YouTube video that's playing can stay: in the library, free and
/// on this device; or as an episode of one of the listener's own podcasts,
/// on this device or in ListenJar Cloud.
final class _AddVideoButton extends StatefulWidget {
  const _AddVideoButton({required this.episode});
  final PodcastEpisode episode;

  @override
  State<_AddVideoButton> createState() => _AddVideoButtonState();
}

final class _AddVideoButtonState extends State<_AddVideoButton> {
  bool _busy = false;

  Future<void> _run(Future<void> Function(BuildContext context) action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action(context);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Services.of(context);
    final e = widget.episode;
    final url = 'https://www.youtube.com/watch?v=${e.youtubeId}';
    return ListenableBuilder(
      listenable: Listenable.merge([s.library, s.account, s.feeds]),
      builder: (context, _) {
        final show = s.library.podcast(e.podcastId);
        final kept = show?.followed ?? false;
        final user = s.account.user;
        final planned = user != null && user.plan != Plan.free;
        return Dropdown(
        tone: MenuTone.ink,
        items: [
          MenuEntry(
            kept ? 'In your Library' : 'Add to Library',
            icon: Icons.library_add_outlined,
            checked: kept ? true : null,
            onPressed: kept || show == null
              ? null
              : () {
                  s.podcasts.followShow(show);
                  tell(context, 'Added “${e.title}” to your library.');
                },
          ),
          const MenuDivider(),
          if (planned) ...[
            const MenuHeader('Add to a podcast of yours'),
            for (final own in ownPodcasts(context))
              MenuEntry(
                own.title,
                icon: own.icon,
                onPressed: () => unawaited(_run((c) => addVideoToOwnPodcast(c, url, own, title: e.title))),
              ),
            MenuEntry('New podcast…', icon: Icons.add_rounded, onPressed: () => unawaited(_run((c) => addVideoToOwnPodcast(c, url, null, title: e.title)))),
          ] else
            MenuEntry(
              'Add to a podcast of yours…',
              icon: Icons.playlist_add_rounded,
              onPressed: () => unawaited(_run((c) => addVideoToOwnPodcast(c, url, null))),
            ),
        ],
        builder: (context, menu) => Tooltip(
          message: 'Keep this video',
          child: _pill(
            context,
            icon: kept ? Icons.library_add_check_outlined : Icons.library_add_outlined,
            label: _busy ? 'Adding…' : 'Add video',
            active: false,
            onTap: () {
              if (_busy) return;
              menu.isOpen ? menu.close() : menu.open();
            },
          ),
        ),
        );
      },
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
