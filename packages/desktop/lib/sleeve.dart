// A show's sleeve (apps/desktop/DESIGN.md, "The Record Sleeve, Folding Into
// Glass"). At rest its artwork leads: full-bleed at the top of a phone,
// large beside the title on a wide window, on the core's ink lit by a glow
// in the artwork's own colour; a few glass controls float over it. As the
// finger pushes the page up past the title, those controls fold into a
// glass title bar, by the distance the finger moves (the Finger Rule), and
// pulling back down unfolds them; let go and the fold settles at the
// finger's own speed.
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'library.dart';
import 'menu.dart';
import 'shell.dart' show Shown, wideWidth;
import 'theme.dart' as brand;
import 'ui.dart';
import 'zoom.dart' show ZoomTarget;

// The sleeve's light.

/// What a show's artwork lends its page: the colour of its glow, and
/// whether its top is light enough that clear glass would lose its icons.
typedef Sample = ({Color glow, bool lightTop});

/// The authored violet of a lettered cover, for a show without artwork.
const _lettered = Color(0xFF6A55F0);

final _samples = <String, Sample>{};

/// [artwork]'s sample if it's been taken; a second visit opens on it.
Sample? sampled(String? artwork) => _samples[artwork ?? ''];

/// Samples [artwork] once: its most vivid hue, lifted by [brand.glow];
/// and the brightness of its top fifth, where the controls float.
Future<Sample> sample(String? artwork) async {
  if (sampled(artwork) case final s?) return s;
  final provider = _provider(artwork);
  final read = provider == null ? null : await _read(provider);
  return _samples[artwork ?? ''] = (
    glow: brand.glow(read?.vivid ?? (provider == null ? _lettered : brand.accent)),
    lightTop: (read?.topLuminance ?? 0) > 0.6,
  );
}

ImageProvider? _provider(String? url) => switch (url) {
  final u? when u.startsWith('file:') => FileImage(File.fromUri(Uri.parse(u))),
  final u? when u.isNotEmpty => NetworkImage(u),
  _ => null,
};

/// The artwork at 20×20: the average of its most colourful hue (twelve
/// 30° buckets, each pixel weighted by its saturation away from black and
/// white), null when it's greyscale; and its top fifth's luminance.
Future<({Color? vivid, double topLuminance})?> _read(ImageProvider provider) async {
  const side = 20;
  final stream = ResizeImage(provider, width: side, height: side, policy: ResizeImagePolicy.exact)
    .resolve(ImageConfiguration.empty);
  final loaded = Completer<ui.Image?>();
  final listener = ImageStreamListener(
    (info, _) {
      if (!loaded.isCompleted) loaded.complete(info.image.clone());
      info.dispose();
    },
    onError: (_, _) {
      if (!loaded.isCompleted) loaded.complete(null);
    },
  );
  stream.addListener(listener);
  final image = await loaded.future;
  stream.removeListener(listener);
  if (image == null) return null;
  try {
    final bytes = await image.toByteData();
    if (bytes == null) return null;
    final weight = List.filled(12, 0.0);
    final r = List.filled(12, 0.0), g = List.filled(12, 0.0), b = List.filled(12, 0.0);
    var top = 0.0;
    for (var i = 0; i < side * side; i++) {
      final c = Color.fromARGB(255, bytes.getUint8(i * 4), bytes.getUint8(i * 4 + 1), bytes.getUint8(i * 4 + 2));
      if (i < side * side ~/ 5) top += c.computeLuminance();
      final hsl = HSLColor.fromColor(c);
      final w = hsl.saturation * (1 - (hsl.lightness - 0.5).abs() * 2);
      if (w <= 0.05) continue;
      final bucket = (hsl.hue ~/ 30) % 12;
      weight[bucket] += w;
      r[bucket] += c.r * w;
      g[bucket] += c.g * w;
      b[bucket] += c.b * w;
    }
    final best = List.generate(12, (i) => i).reduce((a, c) => weight[c] > weight[a] ? c : a);
    final total = weight[best];
    return (
      vivid: total < 1 ? null : Color.from(alpha: 1, red: r[best] / total, green: g[best] / total, blue: b[best] / total),
      topLuminance: top / (side * side ~/ 5),
    );
  } finally {
    image.dispose();
  }
}

/// Glass over ink, where there's no picture under the controls: a white
/// lift instead of a dark tint, or they'd read as holes.
const _glassOnInk = Color(0x1FFFFFFF);

// The page.

/// A sleeve page: [info] (kicker, title, actions) under the hero on a
/// phone, beside the artwork on a wide window, then [children], all on ink.
/// [actions] float at the top right, beside back.
final class SleevePage extends StatefulWidget {
  const SleevePage({
    super.key,
    required this.artwork,
    required this.title,
    required this.info,
    required this.children,
    this.actions = const [],
  });

  final String? artwork;

  /// Names the lettered cover, and the title bar once folded.
  final String title;
  final Widget info;
  final List<Widget> children;
  final List<Widget> actions;

  @override
  State<SleevePage> createState() => _SleevePageState();
}

final class _SleevePageState extends State<SleevePage> with TickerProviderStateMixin {
  /// How far the finger has to push for the title bar to fold in whole.
  static const _travel = 48.0;
  static const _spring = SpringDescription(mass: 1, stiffness: 420, damping: 41);

  late final _fold = AnimationController(vsync: this);
  late final _light = AnimationController(vsync: this, duration: brand.toneSpeed);
  final _scroll = ScrollController();
  final _infoKey = GlobalKey();
  final _stackKey = GlobalKey();

  Color _glow = brand.accent;
  bool _lightTop = false;

  /// The finger's speed, in pixels a second up the page, for the settle.
  double _velocity = 0;
  Duration? _lastUpdate;

  @override
  void initState() {
    super.initState();
    _sample();
  }

  @override
  void didUpdateWidget(SleevePage old) {
    super.didUpdateWidget(old);
    if (old.artwork != widget.artwork) _sample();
  }

  /// The glow fades in from its own colour at alpha 0 (the Opaque Fade
  /// Rule), at once when this artwork was sampled before.
  void _sample() {
    if (sampled(widget.artwork) case final s?) {
      _glow = s.glow;
      _lightTop = s.lightTop;
      _light.value = 1;
      return;
    }
    unawaited(sample(widget.artwork).then((s) {
      if (!mounted) return;
      setState(() {
        _glow = s.glow;
        _lightTop = s.lightTop;
      });
      unawaited(_light.forward(from: 0));
    }));
  }

  @override
  void dispose() {
    _fold.dispose();
    _light.dispose();
    _scroll.dispose();
    super.dispose();
  }

  bool get _wide => MediaQuery.sizeOf(context).width >= wideWidth;

  /// Just under the status bar, or a Mac's window buttons (shell.dart's
  /// windowInsets).
  double _controlsTop() => MediaQuery.paddingOf(context).top + (_wide ? 16 : 6);

  /// Where the controls end, from the top of the page.
  double _controlsBottom() => _controlsTop() + 44;

  /// How far [SleevePage.info] still is below the controls: negative once
  /// the page's title is under them.
  double _infoBelowControls() {
    final info = _infoKey.currentContext?.findRenderObject() as RenderBox?;
    final stack = _stackKey.currentContext?.findRenderObject() as RenderBox?;
    if (info == null || stack == null || !info.attached) return double.infinity;
    return info.localToGlobal(Offset.zero, ancestor: stack).dy - _controlsBottom();
  }

  /// The Finger Rule: the fold moves by the distance the content moves.
  bool _onScroll(ScrollNotification n) {
    if (n.depth != 0) return false;
    switch (n) {
      case ScrollUpdateNotification(:final scrollDelta?):
        final now = SchedulerBinding.instance.currentSystemFrameTimeStamp;
        if (_lastUpdate case final last? when now > last) {
          final instant = scrollDelta / ((now - last).inMicroseconds / 1e6);
          _velocity = _velocity * 0.4 + instant * 0.6;
        }
        _lastUpdate = now;
        final below = _infoBelowControls();
        var fold = _fold.value + scrollDelta / _travel;
        // Nothing under the controls yet: the bar only folds out, and it's
        // gone once the title is a whole travel below them.
        if (below > 0) fold = math.min(fold, _fold.value);
        if (below > _travel || n.metrics.pixels <= n.metrics.minScrollExtent) fold = 0;
        _fold.stop();
        _fold.value = fold.clamp(0, 1);
      case ScrollEndNotification():
        _lastUpdate = null;
        final v = _velocity;
        _velocity = 0;
        final fold = _fold.value;
        if (fold == 0 || fold == 1) break;
        var target = v > 40 ? 1.0 : v < -40 ? 0.0 : fold.roundToDouble();
        if (_infoBelowControls() > 0) target = 0;
        unawaited(_fold.animateWith(SpringSimulation(_spring, fold, target, v / _travel)));
      default:
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => Shown(
    onInk: true,
    child: AnnotatedRegion<SystemUiOverlayStyle>(
    value: SystemUiOverlayStyle.light,
    child: Material(
      color: brand.ink,
      child: brand.Surface(
        palette: brand.Palette.ink,
        child: NotificationListener<ScrollNotification>(
          onNotification: _onScroll,
          child: Stack(key: _stackKey, children: [
            _glowLayer(),
            Positioned.fill(child: _page()),
            Positioned(left: 0, right: 0, top: 0, child: _chrome()),
          ]),
        ),
      ),
    ),
    ),
  );

  /// The artwork's light on the ink, scrolling with the page: one wide
  /// glow from behind the artwork (DESIGN.md "The Glow-Not-Border Rule"),
  /// in a box tall enough that it fades out before any edge.
  Widget _glowLayer() => AnimatedBuilder(
    animation: Listenable.merge([_scroll, _light]),
    builder: (context, _) {
      final offset = _scroll.hasClients ? _scroll.offset : 0.0;
      final light = brand.easeOutExpo.transform(_light.value);
      final size = MediaQuery.sizeOf(context);
      // The page runs on under the sidebar's glass, and the glow with it.
      final left = MediaQuery.paddingOf(context).left;
      final width = size.width - left;
      // Behind the artwork: the wide header's, or the foot of the hero.
      final (cx, cy, r) = _wide
        ? (left + width * 0.3, _controlsBottom() + 140, math.min(width * 0.75, 760.0))
        : (size.width / 2, math.min(size.width, size.height * 0.7) + 40, size.width * 0.95);
      final height = cy + r + 24;
      return Positioned(
        left: 0,
        right: 0,
        top: -offset,
        height: height,
        child: IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(cx / size.width * 2 - 1, cy / height * 2 - 1),
                radius: r / math.min(size.width, height),
                colors: [
                  _glow.withValues(alpha: brand.glowAlpha * light),
                  _glow.withValues(alpha: brand.glowAlpha * light * 0.35),
                  _glow.withValues(alpha: 0),
                ],
                stops: const [0, 0.45, 1],
              ),
            ),
          ),
        ),
      );
    },
  );

  Widget _page() {
    final left = MediaQuery.paddingOf(context).left;
    final gutter = _wide ? ((MediaQuery.sizeOf(context).width - left) * 0.04).clamp(16.0, 40.0) : 16.0;
    final info = KeyedSubtree(key: _infoKey, child: widget.info);
    Widget column(Widget child) => Center(
      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 960), child: child),
    );
    return Scrollbar(
      controller: _scroll,
      child: ListView(
        controller: _scroll,
        keyboardDismissBehavior: switch (defaultTargetPlatform) {
          TargetPlatform.iOS || TargetPlatform.android => ScrollViewKeyboardDismissBehavior.onDrag,
          _ => ScrollViewKeyboardDismissBehavior.manual,
        },
        padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom + 40),
        children: [
          if (_wide)
            Padding(
              padding: EdgeInsets.fromLTRB(left + gutter, _controlsBottom() + 12, gutter, 0),
              child: column(_header(info)),
            )
          else ...[
            _hero(),
            Padding(padding: const EdgeInsets.fromLTRB(16, 20, 16, 0), child: info),
          ],
          Padding(
            padding: EdgeInsets.fromLTRB(left + gutter, _wide ? 40 : 32, gutter, 0),
            child: column(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: widget.children)),
          ),
        ],
      ),
    );
  }

  /// A phone's hero: the artwork as wide as the screen, under the status
  /// bar, its lower quarter fading out, so the ink and the glow behind it
  /// carry on with no edge.
  Widget _hero() {
    final size = MediaQuery.sizeOf(context);
    final height = math.min(size.width, size.height * 0.7);
    return ZoomTarget(
      child: SizedBox(
      height: height,
      child: ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (rect) => const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFFFFFFF), Color(0xFFFFFFFF), Color(0x00FFFFFF)],
          stops: [0, 0.72, 1],
        ).createShader(rect),
        child: _Picture(url: widget.artwork, title: widget.title, letter: height * 0.42),
      ),
      ),
    );
  }

  /// A wide window's header: the artwork large beside [info], lit from
  /// behind by its glow. It gives way before the title does: 240px with
  /// room, down to 160px.
  Widget _header(Widget info) => LayoutBuilder(
    builder: (context, constraints) {
      final art = (constraints.maxWidth * 0.3).clamp(160.0, 240.0);
      return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            boxShadow: const [BoxShadow(color: Color(0x80000000), offset: Offset(0, 24), blurRadius: 48, spreadRadius: -12)],
          ),
          child: ZoomTarget(child: Artwork(url: widget.artwork, title: widget.title, size: art, radius: 18)),
        ),
        const SizedBox(width: 32),
        Expanded(child: info),
      ]);
    },
  );

  /// The floating controls, and the glass title bar they fold into.
  Widget _chrome() => AnimatedBuilder(
    animation: _fold,
    builder: (context, _) {
      final fold = _fold.value;
      final side = _wide ? 24.0 : 16.0;
      // Clear of the sidebar floating over the page's left.
      final left = MediaQuery.paddingOf(context).left + side;
      final top = _controlsTop();
      // Over the phone's hero the controls float on the picture; on a wide
      // window, on ink.
      final glass = _wide ? _glassOnInk : _lightTop ? brand.glassDark : brand.glassClear;
      final canPop = Navigator.of(context).canPop();
      final text = Theme.of(context).textTheme;
      return SizedBox(
        height: top + 52,
        child: Stack(children: [
          // From the sidebar's edge: glass never sits on glass.
          if (fold > 0)
            Positioned(
              left: MediaQuery.paddingOf(context).left,
              top: 0,
              right: 0,
              bottom: 0,
              child: Opacity(
                opacity: fold,
                child: Glass(
                  tint: brand.glassDark,
                  bottom: BorderSide(color: brand.inkLine.withValues(alpha: brand.inkLine.a * ((fold - 0.75) * 4).clamp(0, 1))),
                ),
              ),
            ),
          if (fold > 0)
            Positioned(
              left: left + 60,
              right: side + 60 + 44.0 * math.max(0, widget.actions.length - 1),
              top: top,
              height: 44,
              child: Opacity(
                opacity: fold,
                child: Center(
                  child: Text(
                    widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.titleMedium!.copyWith(color: brand.snow, fontSize: 17, fontWeight: FontWeight.w700, letterSpacing: -0.34),
                  ),
                ),
              ),
            ),
          if (canPop)
            Positioned(
              left: left,
              top: top,
              child: _GlassControl(
                glass: 1 - fold,
                tint: glass,
                shape: const CircleBorder(),
                child: GlassIcon(icon: Icons.chevron_left_rounded, tooltip: 'Back', onPressed: () => Navigator.of(context).maybePop()),
              ),
            ),
          if (widget.actions.isNotEmpty)
            Positioned(
              right: side,
              top: top,
              child: _GlassControl(
                glass: 1 - fold,
                tint: glass,
                shape: const StadiumBorder(),
                child: Row(mainAxisSize: MainAxisSize.min, children: widget.actions),
              ),
            ),
        ]),
      );
    },
  );
}

/// The artwork filling its box, or its lettered cover.
final class _Picture extends StatelessWidget {
  const _Picture({required this.url, required this.title, required this.letter});
  final String? url;
  final String title;
  final double letter;

  @override
  Widget build(BuildContext context) {
    final lettered = ColoredBox(
      color: _lettered,
      child: Center(
        child: Text(
          title.trim().isEmpty ? '?' : title.trim().characters.first.toUpperCase(),
          style: TextStyle(color: brand.white, fontWeight: FontWeight.w700, fontSize: letter, height: 1),
        ),
      ),
    );
    final provider = _provider(url);
    if (provider == null) return lettered;
    final width = (MediaQuery.sizeOf(context).width * MediaQuery.devicePixelRatioOf(context)).round();
    return Image(
      image: ResizeImage(provider, width: width, policy: ResizeImagePolicy.fit),
      fit: BoxFit.cover,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => lettered,
      frameBuilder: (_, child, frame, sync) => AnimatedOpacity(
        opacity: sync || frame != null ? 1 : 0,
        duration: brand.toneSpeed,
        curve: brand.easeOutExpo,
        child: child,
      ),
    );
  }
}

/// A glass surface (DESIGN.md "Glass Vocabulary"): [tint] over a 16px
/// blur at saturation 150%, with a hairline.
final class Glass extends StatelessWidget {
  const Glass({super.key, required this.tint, this.shape, this.bottom});
  final Color tint;

  /// A control's outline; null for a bar, which spans the page.
  final ShapeBorder? shape;
  final BorderSide? bottom;

  @override
  Widget build(BuildContext context) {
    final glass = BackdropFilter(
      filter: ui.ImageFilter.compose(
        outer: ui.ImageFilter.blur(sigmaX: brand.glassBlur / 2, sigmaY: brand.glassBlur / 2),
        inner: const ui.ColorFilter.matrix(_saturate150),
      ),
      child: DecoratedBox(
        decoration: shape == null
          ? BoxDecoration(color: tint, border: bottom == null ? null : Border(bottom: bottom!))
          : ShapeDecoration(color: tint, shape: _outlined(shape!)),
      ),
    );
    return shape == null ? ClipRect(child: glass) : ClipPath(clipper: ShapeBorderClipper(shape: shape!), child: glass);
  }

  static ShapeBorder _outlined(ShapeBorder shape) => switch (shape) {
    CircleBorder() => const CircleBorder(side: BorderSide(color: brand.inkLine)),
    StadiumBorder() => const StadiumBorder(side: BorderSide(color: brand.inkLine)),
    _ => shape,
  };
}

/// Saturation 150%, as the web's `backdrop-saturate-150`.
const _saturate150 = <double>[
  1.3936, -0.3576, -0.0360, 0, 0,
  -0.1064, 1.1424, -0.0360, 0, 0,
  -0.1064, -0.3576, 1.4640, 0, 0,
  0, 0, 0, 1, 0,
];

/// A floating control whose own glass fades out as it joins the title bar
/// (DESIGN.md "The One Layer of Glass Rule").
final class _GlassControl extends StatelessWidget {
  const _GlassControl({required this.glass, required this.tint, required this.shape, required this.child});
  final double glass;
  final Color tint;
  final ShapeBorder shape;
  final Widget child;

  @override
  Widget build(BuildContext context) => Stack(children: [
    if (glass > 0)
      Positioned.fill(child: Opacity(opacity: glass, child: Glass(tint: tint, shape: shape))),
    child,
  ]);
}

/// A 44px icon button for glass: snow, brightening a step under the
/// pointer.
final class GlassIcon extends StatelessWidget {
  const GlassIcon({super.key, required this.icon, required this.tooltip, required this.onPressed, this.size = 24});
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 44,
    child: IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      padding: EdgeInsets.zero,
      style: IconButton.styleFrom(foregroundColor: brand.snow, hoverColor: brand.inkTile, highlightColor: brand.inkTile),
      icon: Icon(icon, size: size),
    ),
  );
}

/// The more menu, for the glass cluster.
Widget glassMore(List<Widget> items) => Dropdown(
  tone: MenuTone.ink,
  align: MenuAlign.end,
  items: items,
  builder: (context, menu) => GlassIcon(icon: Icons.more_horiz_rounded, tooltip: 'More', onPressed: menu.toggle),
);

// The sleeve's actions.

/// The one primary action on a sleeve (DESIGN.md "Play pill"): periwinkle,
/// and its label says what pressing it does.
final class PlayPill extends StatefulWidget {
  const PlayPill({super.key, required this.episode});
  final PodcastEpisode episode;

  @override
  State<PlayPill> createState() => _PlayPillState();
}

final class _PlayPillState extends State<PlayPill> with SingleTickerProviderStateMixin {
  late final _icon = AnimationController(vsync: this, duration: brand.quick);

  @override
  void dispose() {
    _icon.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = Services.of(context).player;
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final e = player.current?.id == widget.episode.id ? player.current! : widget.episode;
        final current = player.current?.id == e.id;
        final playing = current && player.playing;
        final loading = current && player.loading;
        if (playing) {
          unawaited(_icon.forward());
        } else {
          unawaited(_icon.reverse());
        }
        final position = current ? player.position : e.position;
        final duration = e.duration;
        final played = e.played && !current;
        final fraction = switch (duration) {
          final d? when !played && position > Duration.zero && d > Duration.zero =>
            (position.inMilliseconds / d.inMilliseconds).clamp(0.0, 1.0),
          _ => 0.0,
        };
        final label = played
          ? 'Played'
          : fraction > 0 && duration != null
            ? '${spokenDuration(duration - position)} left'
            : duration != null ? spokenDuration(duration) : 'Play';
        return brand.accentShadow(
          enabled: true,
          child: Semantics(
            button: true,
            label: playing ? 'Pause' : played ? 'Play again' : 'Play, $label',
            excludeSemantics: true,
            child: Material(
              shape: const StadiumBorder(),
              clipBehavior: Clip.antiAlias,
              color: brand.accent,
              child: Ink(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: const [brand.accentHover, brand.accentHover, brand.accent, brand.accent],
                    stops: [0, fraction, fraction, 1],
                  ),
                ),
                child: InkWell(
                  hoverColor: const Color(0x14FFFFFF),
                  onTap: () {
                    if (playing) return unawaited(player.pause());
                    doneTyping();
                    unawaited(player.playEpisode(e));
                  },
                  child: SizedBox(
                    height: 48,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 20, 0),
                      child: AnimatedSize(
                        duration: brand.labelSpeed,
                        curve: brand.easeOutExpo,
                        alignment: Alignment.centerLeft,
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          SizedBox.square(
                            dimension: 24,
                            child: loading
                              ? const Padding(
                                  padding: EdgeInsets.all(4),
                                  child: CircularProgressIndicator(strokeWidth: 2, color: brand.white),
                                )
                              : played
                                ? const Icon(Icons.check_rounded, color: brand.white)
                                : AnimatedIcon(icon: AnimatedIcons.play_pause, progress: _icon, color: brand.white),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            label,
                            style: text.labelLarge!.copyWith(
                              color: brand.white,
                              fontSize: 16,
                              fontFeatures: const [FontFeature.tabularFigures()],
                            ),
                          ),
                        ]),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A secondary action on a sleeve (DESIGN.md "Sleeve circles"): a 48px
/// faint circle with a light-periwinkle icon.
final class SleeveCircle extends StatelessWidget {
  const SleeveCircle({super.key, required this.icon, required this.tooltip, required this.onPressed, this.busy = false});
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 48,
    child: IconButton(
      tooltip: tooltip,
      onPressed: busy ? null : onPressed,
      padding: EdgeInsets.zero,
      style: IconButton.styleFrom(
        backgroundColor: brand.inkTile,
        disabledBackgroundColor: brand.inkTile,
        foregroundColor: brand.accentLight,
        hoverColor: const Color(0x14FFFFFF),
        highlightColor: const Color(0x1AFFFFFF),
      ),
      icon: busy
        ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2, color: brand.accentLight))
        : Icon(icon, size: 22),
    ),
  );
}
