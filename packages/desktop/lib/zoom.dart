// A show's page growing out of its cover in a grid, and going back into it
// (DESIGN.md, "Cover to sleeve"). The page's own artwork ([ZoomTarget]: a
// phone's full-width hero, a wide window's square beside the title) is the
// tile's cover, scaled: on opening, the page grows from the tile, the
// artwork's square widening to the window; once open, a finger anywhere on
// it (a swipe toward the back, or a pull down past the top of its content,
// on a touch screen, a trackpad or with a mouse) takes the whole page, which shrinks as it
// travels and moves with the finger in any direction. Let go with the finger
// heading away, or far enough out, and it flies home into the tile at the
// finger's speed; otherwise it springs back.
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/gestures.dart';
import 'package:flutter/physics.dart';
import 'package:material_ui/material_ui.dart';

import 'shell.dart' show pageSurface;
import 'theme.dart' as brand;
import 'ui.dart' show Artwork;

/// The cover a page grows out of. It hides while its page is up, as the
/// page is it, moved.
final class ZoomSource extends StatefulWidget {
  const ZoomSource({super.key, required this.child});
  final Widget child;

  @override
  State<ZoomSource> createState() => ZoomSourceState();
}

final class ZoomSourceState extends State<ZoomSource> {
  bool _hidden = false;

  set _hide(bool hide) {
    if (mounted && hide != _hidden) setState(() => _hidden = hide);
  }

  /// Where the cover is in [ancestor]'s coordinates, while it's laid out.
  Rect? _rectIn(RenderBox ancestor) {
    if (!mounted) return null;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    return MatrixUtils.transformRect(box.getTransformTo(ancestor), Offset.zero & box.size);
  }

  @override
  Widget build(BuildContext context) => Opacity(opacity: _hidden ? 0 : 1, child: widget.child);
}

/// The page's artwork, which its cover grows into.
final class ZoomTarget extends StatefulWidget {
  const ZoomTarget({super.key, required this.child});
  final Widget child;

  @override
  State<ZoomTarget> createState() => _ZoomTargetState();
}

final class _ZoomTargetState extends State<ZoomTarget> {
  ZoomRoute? _route;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is ZoomRoute) (_route = route)._target = this;
  }

  @override
  void dispose() {
    if (_route?._target == this) _route!._target = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Opens [page] out of [from]'s cover: [artwork] and [title] draw the
/// cover as it grows.
Future<void> zoomOpen(
  BuildContext context, {
  required GlobalKey<ZoomSourceState> from,
  required String? artwork,
  required String title,
  required Widget page,
}) async {
  // Its page is still up, or still flying home.
  if (from.currentState?._hidden ?? false) return;
  await Navigator.of(context).push(ZoomRoute(from: from, artwork: artwork, title: title, page: page));
}

/// The springs a page settles on once the finger lets go: no overshoot
/// home, a little on the way back open.
const _home = SpringDescription(mass: 1, stiffness: 320, damping: 36);
const _open = SpringDescription(mass: 1, stiffness: 420, damping: 36);

/// A page that grows out of a cover, and that a finger can take back.
final class ZoomRoute extends PageRoute<void> {
  ZoomRoute({required this.from, required this.artwork, required this.title, required this.page});

  final GlobalKey<ZoomSourceState> from;
  final String? artwork;
  final String title;
  final Widget page;

  @override
  bool get opaque => false;
  @override
  Color? get barrierColor => null;
  @override
  String? get barrierLabel => null;
  @override
  bool get maintainState => true;
  @override
  Duration get transitionDuration => const Duration(milliseconds: 420);
  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 380);

  /// How far the finger has carried the page from where it took it.
  final _pull = ValueNotifier(Offset.zero);

  /// Where the finger took the page, which stays under it as it shrinks.
  Offset _anchor = Offset.zero;

  /// What holds the page: the scroll position a pull down started on, the
  /// swipe toward the back, or null.
  Object? _holder;

  /// The scroll position whose fling a let-go page swallows.
  Object? _swallow;

  /// The touch the page follows, where it went down, and how it moves.
  int? _pointer;
  Offset _finger = Offset.zero;
  Offset _start = Offset.zero;
  VelocityTracker? _tracker;

  /// Springs a page let go of back open.
  AnimationController? _back;
  Offset _backFrom = Offset.zero;

  /// Under a finger or settling from one: the page follows the controller
  /// as is, not on the opening curve.
  bool _driven = false;

  /// Whether this page holds its navigator's user gesture, which keeps
  /// every page in it from taking input: only while a finger has it or it
  /// springs back open, never while it flies home.
  bool _gesture = false;

  void _startGesture() {
    if (_gesture) return;
    _gesture = true;
    navigator?.didStartUserGesture();
  }

  void _endGesture() {
    if (!_gesture) return;
    _gesture = false;
    navigator?.didStopUserGesture();
  }

  /// Whether the system asks for less motion: the page fades instead.
  bool _reduced = false;

  late final CurvedAnimation _curved;

  /// What moves the page.
  late final Listenable _moves;

  /// The page's artwork, and where it last was in the page.
  _ZoomTargetState? _target;
  Rect? _art;

  /// The page, as laid out at the window's size.
  final _pageKey = GlobalKey();

  @override
  void install() {
    super.install();
    _back = AnimationController.unbounded(vsync: navigator!)
      ..addListener(() => _pull.value = _backFrom * _back!.value);
    _curved = CurvedAnimation(parent: animation!, curve: brand.easeOutExpo, reverseCurve: brand.easeOutExpo.flipped);
    _moves = Listenable.merge([animation, _pull]);
  }

  @override
  TickerFuture didPush() {
    from.currentState?._hide = true;
    return super.didPush();
  }

  @override
  bool didPop(void result) {
    // Sent home some other way while a finger has it: the finger lets go,
    // and the page flies home from where it was.
    if (_holder != null) {
      _swallow = _holder;
      _holder = null;
    }
    _pointer = null;
    _endGesture();
    final popped = super.didPop(result);
    // Shown again once the page has landed in it; and a page that ends up
    // open anyway still goes home, never left over the library.
    late final AnimationStatusListener landed;
    landed = (status) {
      if (status.isCompleted) {
        unawaited(controller?.animateBackWith(SpringSimulation(_home, 1, 0, 0)));
        return;
      }
      if (!status.isDismissed) return;
      controller?.removeStatusListener(landed);
      from.currentState?._hide = false;
    };
    controller?.addStatusListener(landed);
    return popped;
  }

  @override
  void dispose() {
    from.currentState?._hide = false;
    _endGesture();
    _back?.dispose();
    _curved.dispose();
    _pull.dispose();
    super.dispose();
  }

  /// The overlay the page and the cover are drawn in.
  RenderBox? get _overlay => navigator?.overlay?.context.findRenderObject() as RenderBox?;

  bool get _settled => isCurrent && controller!.isCompleted && !_back!.isAnimating && _holder == null;

  // The finger.

  Offset _local(Offset global) => _overlay?.globalToLocal(global) ?? global;

  void _follow(int pointer, PointerDeviceKind kind, Duration time, Offset at) {
    // A pointer whose lift never reached the page doesn't keep new ones
    // out, unless it holds the page.
    if (_pointer != null && _holder != null) return;
    _pointer = pointer;
    _finger = at;
    _tracker = VelocityTracker.withKind(kind)..addPosition(time, at);
  }

  void _down(PointerDownEvent e) {
    // A mouse drags with its main button; a trackpad's two fingers come as
    // pans.
    if (e.kind == PointerDeviceKind.mouse && e.buttons != kPrimaryMouseButton) return;
    _follow(e.pointer, e.kind, e.timeStamp, _local(e.position));
  }

  void _panStart(PointerPanZoomStartEvent e) => _follow(e.pointer, e.kind, e.timeStamp, _local(e.position));

  void _move(PointerMoveEvent e) => _moved(e.pointer, e.timeStamp, _local(e.position));

  void _pan(PointerPanZoomUpdateEvent e) => _moved(e.pointer, e.timeStamp, _local(e.position + e.pan));

  void _moved(int pointer, Duration time, Offset at) {
    if (pointer != _pointer) return;
    _finger = at;
    _tracker?.addPosition(time, at);
    if (_holder == null) return;
    var pull = _finger - _start;
    // Pulled down out of the content, it goes no higher than it was: the
    // content scrolls on from there.
    if (_holder is ScrollMetrics && pull.dy < 0) pull = Offset(pull.dx, 0);
    _pull.value = pull;
  }

  void _up(PointerEvent e) {
    if (e.pointer != _pointer) return;
    _pointer = null;
    // Where it lifted counts too: a finger held still before lifting has
    // stopped, whatever it did before.
    if (e is PointerUpEvent) _tracker?.addPosition(e.timeStamp, _local(e.position));
    final velocity = e is PointerUpEvent || e is PointerPanZoomEndEvent
      ? _tracker?.getVelocity().pixelsPerSecond ?? Offset.zero
      : Offset.zero;
    _tracker = null;
    if (_holder == null) return;
    _swallow = _holder;
    _holder = null;
    _letGo(velocity);
  }

  /// Takes the page for [holder], [already] pixels down from where the
  /// finger is.
  bool _grab(Object holder, {double already = 0}) {
    if (_pointer == null || !_settled) return false;
    final nav = navigator!;
    if (nav.userGestureInProgress) return false;
    _holder = holder;
    _driven = true;
    _start = _finger - Offset(0, already);
    _anchor = _start;
    _pull.value = _finger - _start;
    _startGesture();
    return true;
  }

  /// A swipe toward the back, anywhere on the page.
  void _swipe(DragUpdateDetails d, TextDirection direction) {
    if (_holder != null || d.primaryDelta == null) return;
    final back = direction == TextDirection.ltr ? d.primaryDelta! > 0 : d.primaryDelta! < 0;
    if (back) _grab(_Swipe.instance);
  }

  /// Whether the page's content is at its top, where a mouse dragged down
  /// takes the page (a mouse doesn't drag content, so the content can't
  /// hand it over).
  bool _atTop = true;

  /// A mouse drag's first move decides: toward the back, or down from the
  /// top, takes the page; anything else leaves it.
  bool _decided = false;

  void _mouseStart(DragStartDetails _) => _decided = false;

  void _mouseDrag(DragUpdateDetails d, TextDirection direction) {
    if (_decided || _holder != null) return;
    _decided = true;
    final dx = direction == TextDirection.ltr ? d.delta.dx : -d.delta.dx;
    final back = dx > 0 && dx.abs() >= d.delta.dy.abs();
    final down = _atTop && d.delta.dy > 0 && d.delta.dy > d.delta.dx.abs();
    if (back || down) _grab(_Swipe.instance);
  }

  /// A scroll position pulled down past its top, by [excess].
  bool _pullDown(ScrollMetrics position, double excess) => _grab(position, already: excess);

  bool _heldBy(Object holder) => _holder == holder;

  /// Hands a pull back to the content it came out of, once the finger has
  /// brought the page back up to where it took it.
  bool _handBack(ScrollMetrics position) {
    if (_holder != position || _pull.value.dy > 0) return false;
    _holder = null;
    _springOpen(0);
    return true;
  }

  bool _swallowed(ScrollMetrics position) {
    if (_swallow != position) return false;
    _swallow = null;
    return true;
  }

  /// Settles a page let go at [velocity]: home when the finger was heading
  /// away from where it took it, or had carried it far; back open
  /// otherwise.
  void _letGo(Offset velocity) {
    final pull = _pull.value;
    final distance = pull.distance;
    final size = _overlay?.size ?? Size.zero;
    final away = distance == 0 ? 0.0 : (velocity.dx * pull.dx + velocity.dy * pull.dy) / distance;
    final home = distance > 8 && (away > 350 || (away > -350 && distance > size.shortestSide * 0.28));
    if (!home) return _springOpen(distance == 0 ? 0 : away / distance);
    // The page leaves from where the finger left it, toward the cover, at
    // the speed it was let go.
    final card = _frame(size, 1).card;
    final cover = _cover(size);
    final way = cover.center - card.center;
    final toward = way.distance == 0 ? 0.0 : (velocity.dx * way.dx + velocity.dy * way.dy) / way.distance;
    final rate = way.distance == 0 ? 0.0 : (toward / way.distance).clamp(0.0, 8.0);
    if (!isCurrent) return;
    navigator!.pop();
    // The page behind takes input again at once; this one ignores it while
    // it flies, as a page leaving does.
    _endGesture();
    unawaited(controller!.animateBackWith(SpringSimulation(_home, 1, 0, -rate)));
  }

  /// Springs the page back open from where the finger left it, at [rate]
  /// of its pull a second, outward.
  void _springOpen(double rate) {
    _backFrom = _pull.value;
    if (_backFrom == Offset.zero) {
      _back!.value = 0;
      _stopDriving();
      return;
    }
    _back!.value = 1;
    unawaited(_back!.animateWith(SpringSimulation(_open, 1, 0, rate)).whenComplete(() {
      if (_holder == null) _stopDriving();
    }));
  }

  void _stopDriving() {
    _driven = false;
    _pull.value = Offset.zero;
    _endGesture();
  }

  // Where the page is.

  /// The cover, in the overlay; the middle of the screen if it's gone.
  Rect _cover(Size size) {
    final overlay = _overlay;
    final rect = overlay == null ? null : from.currentState?._rectIn(overlay);
    return rect ?? Rect.fromCenter(center: size.center(Offset.zero), width: size.width * 0.4, height: size.width * 0.4);
  }

  /// Where the page's artwork is in the page: measured once laid out, held
  /// at the page's top if it has scrolled above it, and a phone's hero
  /// until then.
  Rect _artIn(Size size) {
    final target = _target?.context.findRenderObject();
    final page = _pageKey.currentContext?.findRenderObject();
    if (target is RenderBox && page is RenderBox && target.attached && page.attached && target.hasSize) {
      var art = MatrixUtils.transformRect(target.getTransformTo(page), Offset.zero & target.size);
      if (art.top < 0) art = art.translate(0, -art.top);
      _art = art;
    }
    return _art ?? Rect.fromLTWH(0, 0, size.width, math.min(size.width, size.height * 0.7));
  }

  /// How far the page is from its cover: by the controller under a finger,
  /// on the curve otherwise, and always open when it fades instead.
  double get _t {
    if (_reduced && !_driven) return 1;
    return _driven ? animation!.value : _curved.value;
  }

  /// The page [t] of the way from its cover to where the finger has it.
  _Frame _frame(Size size, double t) {
    final pull = _pull.value;
    // It shrinks as the finger carries it, to 70% at most, about the point
    // the finger took it by.
    final travel = (pull.distance / (size.shortestSide * 0.6)).clamp(0.0, 1.0);
    final scale = 1 - 0.3 * travel;
    final held = _Frame(
      offset: _anchor * (1 - scale) + pull,
      scale: scale,
      clip: Offset.zero & size,
      radius: 40 * (pull.distance / 24).clamp(0.0, 1.0),
    );
    if (t >= 1) return held;
    // The page's artwork laid over the tile's cover.
    final cover = _cover(size);
    final art = _artIn(size);
    final s0 = cover.width / art.width;
    final home = _Frame(offset: cover.topLeft - art.topLeft * s0, scale: s0, clip: art, radius: 18);
    return _Frame.lerp(home, held, t);
  }

  // The page.

  // The page behind stays still while this one moves, without the alert a
  // modal barrier plays when it's tapped.
  @override
  Widget buildModalBarrier() => _Barrier(this);

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) {
    final scrolling = ScrollConfiguration.of(context);
    return ScrollConfiguration(
      behavior: scrolling.copyWith(physics: _PullPhysics(this, parent: scrolling.getScrollPhysics(context))),
      child: pageSurface(page),
    );
  }

  @override
  Widget buildTransitions(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation, Widget child) {
    _reduced = MediaQuery.disableAnimationsOf(context);
    return _Zoom(route: this, child: child);
  }
}

/// Keeps input from the page behind while this one is up, and lets it
/// through as soon as this one has been sent home.
final class _Barrier extends LeafRenderObjectWidget {
  const _Barrier(this.route);
  final ZoomRoute route;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderBarrier(route);

  @override
  void updateRenderObject(BuildContext context, _RenderBarrier renderObject) => renderObject.route = route;
}

final class _RenderBarrier extends RenderBox {
  _RenderBarrier(this.route);
  ZoomRoute route;

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  bool hitTestSelf(Offset position) => route.isActive;
}

/// What holds a page taken by a swipe toward the back.
final class _Swipe {
  const _Swipe._();
  static const instance = _Swipe._();
}

/// Where the page is drawn: where its top left goes on screen, its scale,
/// the part of it that shows (in its own pixels) and the corners of that
/// part (on screen).
final class _Frame {
  const _Frame({required this.offset, required this.scale, required this.clip, required this.radius});
  final Offset offset;
  final double scale;
  final Rect clip;
  final double radius;

  /// The part that shows, on screen.
  Rect get card => Rect.fromLTWH(offset.dx + clip.left * scale, offset.dy + clip.top * scale, clip.width * scale, clip.height * scale);

  RRect get shape => RRect.fromRectAndRadius(card, Radius.circular(radius));

  Matrix4 get transform => Matrix4.translationValues(offset.dx, offset.dy, 0)..scaleByDouble(scale, scale, 1, 1);

  static _Frame lerp(_Frame a, _Frame b, double t) => _Frame(
    offset: Offset.lerp(a.offset, b.offset, t)!,
    scale: lerpDouble(a.scale, b.scale, t)!,
    clip: Rect.lerp(a.clip, b.clip, t)!,
    radius: lerpDouble(a.radius, b.radius, t)!,
  );
}

/// The page and the tile's cover over its artwork, moved and clipped by
/// [ZoomRoute._frame]. Where the artwork is in the page is only known once
/// the page is laid out, so the frame is worked out as it paints.
final class _Zoom extends StatelessWidget {
  const _Zoom({required this.route, required this.child});
  final ZoomRoute route;
  final Widget child;

  static const _fingers = {PointerDeviceKind.touch, PointerDeviceKind.stylus, PointerDeviceKind.invertedStylus, PointerDeviceKind.trackpad};

  @override
  Widget build(BuildContext context) {
    final direction = Directionality.of(context);
    final page = Listener(
      key: route._pageKey,
      onPointerDown: route._down,
      onPointerMove: route._move,
      onPointerUp: route._up,
      onPointerCancel: route._up,
      onPointerPanZoomStart: route._panStart,
      onPointerPanZoomUpdate: route._pan,
      onPointerPanZoomEnd: route._up,
      child: RawGestureDetector(
        gestures: {
          HorizontalDragGestureRecognizer: GestureRecognizerFactoryWithHandlers<HorizontalDragGestureRecognizer>(
            () => HorizontalDragGestureRecognizer(supportedDevices: _fingers),
            (r) => r.onUpdate = (d) => route._swipe(d, direction),
          ),
          PanGestureRecognizer: GestureRecognizerFactoryWithHandlers<PanGestureRecognizer>(
            () => PanGestureRecognizer(supportedDevices: const {PointerDeviceKind.mouse}),
            (r) => r
              ..onStart = route._mouseStart
              ..onUpdate = (d) => route._mouseDrag(d, direction),
          ),
        },
        child: NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if (n.depth == 0 && n.metrics.axis == Axis.vertical) route._atTop = n.metrics.pixels <= n.metrics.minScrollExtent + 0.5;
            return false;
          },
          child: child,
        ),
      ),
    );
    // One shape of tree throughout, open or moving, so the page keeps its
    // state (its scroll, its fields) as it lands and leaves.
    return AnimatedBuilder(
      animation: route._moves,
      builder: (context, page) {
        final size = MediaQuery.sizeOf(context);
        final t = route._t;
        final pull = route._pull.value;
        final whole = t >= 1 && pull == Offset.zero;
        final travel = (pull.distance / (size.shortestSide * 0.6)).clamp(0.0, 1.0);
        final fading = route._reduced && !route._driven;
        final dim = fading ? 0.0 : 0.28 * t.clamp(0.0, 1.0) * (1 - travel * 0.6);
        // The tile's own cover over the page's artwork, fading into it as
        // the page grows, and back as it lands, so the picture never waits
        // on the page's larger decode.
        final cover = (1 - (t - 0.3) / 0.5).clamp(0.0, 1.0);
        final side = route._cover(size).width;
        return Stack(children: [
          // The page behind settles back as this one leaves it.
          Positioned.fill(
            child: IgnorePointer(child: ColoredBox(color: Color.fromRGBO(0, 0, 0, whole ? 0 : dim))),
          ),
          Positioned.fill(
            child: IgnorePointer(child: CustomPaint(painter: whole ? null : _Shadow(route, t))),
          ),
          Positioned.fill(
            child: Opacity(
              opacity: fading ? route.animation!.value.clamp(0.0, 1.0) : 1,
              child: ClipRRect(
                clipper: _Clip(route, t),
                clipBehavior: whole ? Clip.none : Clip.antiAlias,
                child: Flow(
                  delegate: _Place(route, t, side, cover),
                  children: [
                    page!,
                    // Its own corners too: the page's clip doesn't always
                    // reach a child the flow draws by itself.
                    IgnorePointer(
                      child: ClipRRect(
                        clipper: _CoverClip(route, t, side),
                        child: Artwork(url: route.artwork, title: route.title, size: side, radius: 0),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ]);
      },
      child: page,
    );
  }
}

/// Draws the page where its frame puts it, and the cover over its artwork.
final class _Place extends FlowDelegate {
  const _Place(this.route, this.t, this.side, this.cover);
  final ZoomRoute route;
  final double t, side, cover;

  @override
  BoxConstraints getConstraintsForChild(int i, BoxConstraints constraints) =>
    i == 0 ? BoxConstraints.tight(constraints.biggest) : BoxConstraints.tight(Size.square(side));

  @override
  void paintChildren(FlowPaintingContext context) {
    final frame = route._frame(context.size, t);
    context.paintChild(0, transform: frame.transform);
    if (cover <= 0 || side <= 0) return;
    // Filling the artwork's box, as the artwork does.
    final art = route._artIn(context.size);
    final k = math.max(art.width, art.height) / side;
    final at = art.center - Offset(side, side) * k / 2;
    context.paintChild(
      1,
      transform: frame.transform..translateByDouble(at.dx, at.dy, 0, 1)..scaleByDouble(k, k, 1, 1),
      opacity: cover,
    );
  }

  @override
  bool shouldRepaint(_Place old) => true;
}

/// The page's corners, where its frame puts it.
final class _Clip extends CustomClipper<RRect> {
  const _Clip(this.route, this.t);
  final ZoomRoute route;
  final double t;

  @override
  RRect getClip(Size size) => route._frame(size, t).shape;

  @override
  bool shouldReclip(_Clip old) => true;
}

/// The cover's corners: the page's on screen where its edges meet the
/// page's, square where the page goes on past them.
final class _CoverClip extends CustomClipper<RRect> {
  const _CoverClip(this.route, this.t, this.side);
  final ZoomRoute route;
  final double t, side;

  @override
  RRect getClip(Size size) {
    final window = route._overlay?.size;
    if (window == null || side <= 0) return RRect.fromRectAndRadius(Offset.zero & size, Radius.zero);
    final frame = route._frame(window, t);
    final art = route._artIn(window);
    // Screen pixels to the cover's own.
    final k = side / (math.max(art.width, art.height) * frame.scale);
    Radius at(double gap) => Radius.circular(frame.radius * k * (1 - gap / math.max(frame.radius, 0.001)).clamp(0.0, 1.0));
    // How far past the cover the page shows, on screen, edge by edge.
    final left = (art.left - frame.clip.left) * frame.scale;
    final top = (art.top - frame.clip.top) * frame.scale;
    final right = (frame.clip.right - art.right) * frame.scale;
    final bottom = (frame.clip.bottom - art.bottom) * frame.scale;
    return RRect.fromRectAndCorners(
      Offset.zero & size,
      topLeft: at(math.max(left, top)),
      topRight: at(math.max(right, top)),
      bottomLeft: at(math.max(left, bottom)),
      bottomRight: at(math.max(right, bottom)),
    );
  }

  @override
  bool shouldReclip(_CoverClip old) => true;
}

/// The page's shadow on the page behind, while it's out of place.
final class _Shadow extends CustomPainter {
  const _Shadow(this.route, this.t);
  final ZoomRoute route;
  final double t;

  static const _shadow = BoxShadow(color: Color(0x47000000), offset: Offset(0, 18), blurRadius: 44, spreadRadius: -8);

  @override
  void paint(Canvas canvas, Size size) {
    final shape = route._frame(size, t).shape;
    canvas.drawRRect(shape.shift(_shadow.offset).inflate(_shadow.spreadRadius), _shadow.toPaint());
  }

  @override
  bool shouldRepaint(_Shadow old) => true;
}

/// Lets a pull down past the top of the page's content take the page, and
/// hands it back to the content once the finger brings it back up.
final class _PullPhysics extends ScrollPhysics {
  const _PullPhysics(this.route, {super.parent});
  final ZoomRoute route;

  @override
  _PullPhysics applyTo(ScrollPhysics? ancestor) => _PullPhysics(route, parent: buildParent(ancestor));

  // Content that fits still pulls the page.
  @override
  bool shouldAcceptUserOffset(ScrollMetrics position) =>
    position.axis == Axis.vertical || super.shouldAcceptUserOffset(position);

  @override
  double applyPhysicsToUserOffset(ScrollMetrics position, double offset) {
    if (position.axis != Axis.vertical) return super.applyPhysicsToUserOffset(position, offset);
    if (route._heldBy(position)) {
      // The page has the finger until it's back where it was taken.
      if (offset >= 0 || !route._handBack(position)) return 0;
    } else if (offset > 0) {
      // Down: the content scrolls back to its top, then the page follows.
      final room = math.max(0.0, position.pixels - position.minScrollExtent);
      if (offset > room && route._pullDown(position, offset - room)) offset = room;
    }
    if (offset == 0) return 0;
    return super.applyPhysicsToUserOffset(position, offset);
  }

  @override
  Simulation? createBallisticSimulation(ScrollMetrics position, double velocity) {
    // The page took the fling.
    if (route._heldBy(position) || route._swallowed(position)) return super.createBallisticSimulation(position, 0);
    return super.createBallisticSimulation(position, velocity);
  }
}
