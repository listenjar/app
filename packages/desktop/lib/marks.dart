// The logo and icons, drawn from the same paths as the website
// (apps/web/src/components/Logo.tsx and Icon.tsx), so nothing is a font or an
// image file.
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:material_ui/material_ui.dart';
import 'package:path_parsing/path_parsing.dart';

import 'theme.dart' as brand;

// Logo.tsx: the folded wave and the outlined Figtree 750 wordmark.
const _wave = 'M60 96A44 44 0 0 1 104 140H144A84 84 0 0 0 60 56';
const _wordmark =
  'M2.16 0V-21H6.62V-4.09H15.72V0ZM17.5 0V-15H21.82V0ZM19.67 -17.18Q18.68 -17.18 17.94 -17.92Q17.2 -18.65 17.2 -19.64Q17.2 -20.65 17.94 -21.38Q18.68 -22.1 19.67 -22.1Q20.68 -22.1 21.4 -21.38Q22.13 -20.65 22.13 -19.64Q22.13 -18.65 21.4 -17.92Q20.68 -17.18 19.67 -17.18ZM30.34 0.36Q28.89 0.36 27.62 -0.07Q26.35 -0.5 25.41 -1.31Q24.46 -2.12 23.96 -3.29L27.58 -4.88Q28 -4.14 28.73 -3.69Q29.47 -3.24 30.34 -3.24Q31.21 -3.24 31.69 -3.51Q32.17 -3.77 32.17 -4.28Q32.17 -4.78 31.74 -5.05Q31.3 -5.31 30.52 -5.5L29.18 -5.84Q27.06 -6.4 25.87 -7.65Q24.68 -8.89 24.68 -10.53Q24.68 -12.84 26.22 -14.1Q27.76 -15.36 30.53 -15.36Q32.03 -15.36 33.25 -14.94Q34.46 -14.51 35.31 -13.75Q36.16 -13 36.51 -12L33.01 -10.48Q32.8 -11.08 32.07 -11.43Q31.34 -11.77 30.56 -11.77Q29.82 -11.77 29.42 -11.46Q29.03 -11.14 29.03 -10.61Q29.03 -10.22 29.45 -9.97Q29.87 -9.71 30.68 -9.52L32.45 -9.08Q33.9 -8.73 34.82 -7.97Q35.74 -7.2 36.18 -6.22Q36.63 -5.24 36.63 -4.22Q36.63 -2.84 35.82 -1.81Q35 -0.77 33.59 -0.21Q32.18 0.36 30.34 0.36ZM44.59 0.36Q42.02 0.36 40.72 -0.89Q39.43 -2.15 39.43 -4.47V-11.35H37.05V-15H39.43V-19.68H43.75V-15H47.34V-11.35H43.75V-5.5Q43.75 -4.55 44.12 -4.1Q44.5 -3.64 45.26 -3.64Q45.54 -3.64 45.9 -3.78Q46.25 -3.92 46.6 -4.16L48.1 -0.96Q47.38 -0.39 46.44 -0.02Q45.5 0.36 44.59 0.36ZM56.9 0.36Q54.63 0.36 52.88 -0.64Q51.12 -1.64 50.12 -3.41Q49.12 -5.18 49.12 -7.5Q49.12 -9.82 50.14 -11.59Q51.16 -13.36 52.94 -14.36Q54.72 -15.36 57.04 -15.36Q59.1 -15.36 60.79 -14.33Q62.48 -13.31 63.48 -11.3Q64.49 -9.29 64.49 -6.37H53.63Q53.78 -4.97 54.8 -4.15Q55.82 -3.32 57.18 -3.32Q58.35 -3.32 59.12 -3.83Q59.89 -4.34 60.25 -5.15L64.09 -3.74Q63.48 -2.41 62.43 -1.48Q61.38 -0.56 59.98 -0.1Q58.58 0.36 56.9 0.36ZM53.79 -9.41H59.89Q59.79 -10.31 59.31 -10.86Q58.83 -11.41 58.18 -11.66Q57.54 -11.91 56.91 -11.91Q56.3 -11.91 55.62 -11.67Q54.95 -11.43 54.43 -10.88Q53.92 -10.33 53.79 -9.41ZM66.03 0V-15H70.1L70.28 -13.02Q71.01 -14.15 72.11 -14.75Q73.22 -15.36 74.6 -15.36Q76.4 -15.36 77.64 -14.63Q78.89 -13.91 79.52 -12.4Q80.16 -10.89 80.15 -8.52V0H75.83V-7.68Q75.83 -9.04 75.52 -9.81Q75.21 -10.59 74.65 -10.94Q74.08 -11.29 73.31 -11.31Q71.87 -11.35 71.11 -10.48Q70.35 -9.61 70.35 -7.9V0ZM85.71 -17.07Q84.69 -17.07 83.94 -17.82Q83.19 -18.57 83.19 -19.59Q83.19 -20.63 83.94 -21.37Q84.69 -22.12 85.71 -22.12Q86.75 -22.12 87.49 -21.37Q88.24 -20.63 88.24 -19.59Q88.24 -18.57 87.49 -17.82Q86.75 -17.07 85.71 -17.07ZM82.38 6.45Q80.56 6.45 79.02 5.5L80.77 1.91Q81.2 2.15 81.58 2.29Q81.96 2.43 82.26 2.43Q83.55 2.43 83.55 0.71V-15H87.87V1.01Q87.87 3.6 86.45 5.03Q85.02 6.45 82.38 6.45ZM95.68 0.36Q93 0.36 91.52 -0.84Q90.04 -2.03 90.04 -4.23Q90.04 -6.61 91.61 -7.81Q93.18 -9 96.01 -9H99.61Q99.43 -10.28 98.83 -10.99Q98.22 -11.69 96.99 -11.69Q96.08 -11.69 95.38 -11.29Q94.67 -10.88 94.19 -10.11L90.4 -11.38Q90.87 -12.41 91.71 -13.32Q92.56 -14.24 93.86 -14.8Q95.15 -15.36 96.96 -15.36Q99.27 -15.36 100.83 -14.49Q102.4 -13.62 103.17 -12.05Q103.95 -10.48 103.93 -8.34L103.86 0H99.82L99.76 -1.63Q99.17 -0.66 98.14 -0.15Q97.12 0.36 95.68 0.36ZM96.53 -3.06Q97.43 -3.06 98.15 -3.47Q98.87 -3.87 99.28 -4.54Q99.7 -5.2 99.7 -5.95V-6.02H97.58Q95.86 -6.02 95.15 -5.58Q94.45 -5.14 94.45 -4.35Q94.45 -3.74 95 -3.4Q95.54 -3.06 96.53 -3.06ZM106.32 0V-15H110.64V-12.23Q111.57 -13.64 113 -14.35Q114.43 -15.06 115.95 -15.06V-10.87Q114.57 -10.87 113.35 -10.55Q112.14 -10.23 111.39 -9.55Q110.64 -8.86 110.64 -7.79V0Z';

// AuthCard.tsx's GoogleMark: Google's "G" on a 48 grid, in its own colours.
const _google = [
  (Color(0xFFEA4335), 'M24 9.5c3.54 0 6.71 1.22 9.21 3.6l6.85-6.85C35.9 2.38 30.47 0 24 0 14.62 0 6.51 5.38 2.56 13.22l7.98 6.19C12.43 13.72 17.74 9.5 24 9.5z'),
  (Color(0xFF4285F4), 'M46.98 24.55c0-1.57-.15-3.09-.38-4.55H24v9.02h12.94c-.58 2.96-2.26 5.48-4.78 7.18l7.73 6c4.51-4.18 7.09-10.36 7.09-17.65z'),
  (Color(0xFFFBBC05), 'M10.53 28.59c-.48-1.45-.76-2.99-.76-4.59s.27-3.14.76-4.59l-7.98-6.19C.92 16.46 0 20.12 0 24c0 3.88.92 7.54 2.56 10.78l7.97-6.19z'),
  (Color(0xFF34A853), 'M24 48c6.48 0 11.93-2.13 15.89-5.81l-7.73-6c-2.15 1.45-4.92 2.3-8.16 2.3-6.26 0-11.57-4.22-13.47-9.91l-7.98 6.19C6.51 42.62 14.62 48 24 48z'),
];

final class _PathProxy implements PathProxy {
  final path = Path();
  @override
  void moveTo(double x, double y) => path.moveTo(x, y);
  @override
  void lineTo(double x, double y) => path.lineTo(x, y);
  @override
  void cubicTo(double x1, double y1, double x2, double y2, double x3, double y3) =>
    path.cubicTo(x1, y1, x2, y2, x3, y3);
  @override
  void close() => path.close();
}

Path _parse(String data) {
  final proxy = _PathProxy();
  writeSvgPathDataToPath(data, proxy);
  return proxy.path;
}

final _wavePath = _parse(_wave);
final _wordmarkPath = _parse(_wordmark);
final _googlePaths = [for (final (color, data) in _google) (color, _parse(data))];

/// The logo in its paper colourway: a white mark on a periwinkle tile and a
/// periwinkle wordmark. [height] is the tile's; the viewBox is 176.37 × 48.
Widget logo({double height = 30}) => Semantics(
  label: 'Listenjar',
  image: true,
  child: CustomPaint(size: Size(height * 176.37 / 48, height), painter: const _Logo()),
);

final class _Logo extends CustomPainter {
  const _Logo();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.height / 48);
    canvas.save();
    canvas.scale(0.24);
    canvas.drawRRect(
      RRect.fromRectAndRadius(const Rect.fromLTWH(0, 0, 200, 200), const Radius.circular(44)),
      Paint()..color = brand.accent,
    );
    canvas.drawPath(_wavePath, Paint()
      ..color = brand.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 21
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round);
    canvas.drawCircle(const Offset(60, 140), 14, Paint()..color = brand.white);
    canvas.restore();
    canvas.translate(60, 34.5);
    canvas.drawPath(_wordmarkPath, Paint()..color = brand.accent);
  }

  @override
  bool shouldRepaint(_Logo oldDelegate) => false;
}

/// The arrow the website puts on links and actions, in [color] or the
/// enclosing icon colour (a button's foreground).
final class Arrow extends StatelessWidget {
  const Arrow({super.key, this.size = 18, this.color});
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => GlyphIcon(Glyphs.arrow, size: size, color: color);
}

/// Icon.tsx's key: a passkey.
final class KeyMark extends StatelessWidget {
  const KeyMark({super.key, this.size = 20, this.color});
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => GlyphIcon(Glyphs.key, size: size, color: color);
}

/// Google's "G" on a white disc, as the website's "Continue with Google"
/// shows it on ink.
final class GoogleMark extends StatelessWidget {
  const GoogleMark({super.key, this.size = 20});
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    padding: EdgeInsets.all(size / 10),
    decoration: const BoxDecoration(color: brand.white, shape: BoxShape.circle),
    child: const CustomPaint(painter: _Google()),
  );
}

final class _Google extends CustomPainter {
  const _Google();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 48);
    for (final (color, path) in _googlePaths) {
      canvas.drawPath(path, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(_Google oldDelegate) => false;
}

// The icons: one drawn set, as the website's Icon.tsx draws it. A 24 grid,
// 1.8 round strokes in the icon colour; a filled glyph fills its shapes and
// strokes them too, so its corners round the same way. Nothing comes from
// Material's icon font.

/// One icon of the set: SVG path data on the 24 grid. [label] is a few
/// characters set in its middle (the seconds in a skip button).
@immutable
final class Glyph {
  const Glyph(this.data, {this.filled = false, this.label});
  final String data;
  final bool filled;
  final String? label;

  /// The same drawing with [label] in its middle.
  Glyph labelled(String label) => Glyph(data, filled: filled, label: label);

  @override
  bool operator ==(Object other) => other is Glyph && other.data == data && other.filled == filled && other.label == label;

  @override
  int get hashCode => Object.hash(data, filled, label);
}

/// Every icon the app draws. Icon.tsx's own come first, in its spelling;
/// the app's additions follow in the same hand.
abstract final class Glyphs {
  // Icon.tsx.
  static const arrow = Glyph('M5 12h13M13 6l6 6-6 6');
  static const external = Glyph('M13.5 4.5h6v6M19.5 4.5 11 13M17.5 14v5.5h-13v-13H10');
  static const link = Glyph('M10 14a4.5 4.5 0 0 0 6.4 0l3-3a4.5 4.5 0 0 0-6.4-6.4l-1 1M14 10a4.5 4.5 0 0 0-6.4 0l-3 3a4.5 4.5 0 0 0 6.4 6.4l1-1');
  static const check = Glyph('M5 12.5l4.5 4.5L19 7.5');
  static const play = Glyph('M8 5.5v13l10.5-6.5z', filled: true);
  static const plus = Glyph('M12 5v14M5 12h14');
  static const upload = Glyph('M12 16V5M7 9.5 12 4.5l5 5M5 19.5h14');
  static const trash = Glyph('M5 7h14M10 7V5h4v2M7 7l1 12.5h8L17 7');
  static const feed = Glyph('M5 5a14 14 0 0 1 14 14M5 11a8 8 0 0 1 8 8M6 19h.01');
  static const power = Glyph('M12 4v7M7.5 6.8a7 7 0 1 0 9 0');
  static const clock = Glyph('M12 7v5l3 2M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0z');
  static const moon = Glyph('M20 14.5A8.5 8.5 0 0 1 9.5 4a8.5 8.5 0 1 0 10.5 10.5z');
  static const rewind = Glyph('M4.5 12a7.5 7.5 0 1 0 2.2-5.3M4.5 3.5v3.7h3.7');
  static const forward = Glyph('M19.5 12a7.5 7.5 0 1 1-2.2-5.3M19.5 3.5v3.7h-3.7');
  static const gauge = Glyph('M12 14.5l4-4.5M3.5 18a9 9 0 1 1 17 0');
  static const download = Glyph('M12 4v11M7 10.5l5 5 5-5M5 19.5h14');
  static const lock = Glyph('M7 10.5V8a5 5 0 0 1 10 0v2.5M5.5 10.5h13v9.5h-13z');
  static const search = Glyph('M10.5 17.5a7 7 0 1 0 0-14 7 7 0 0 0 0 14zM15.6 15.6 20.5 20.5');
  static const close = Glyph('M6.5 6.5l11 11M17.5 6.5l-11 11');
  static const chevronDown = Glyph('M6.5 9.5 12 15l5.5-5.5');
  static const copy = Glyph('M9 9h10.5v10.5H9zM15 9V4.5H4.5V15H9');
  static const key = Glyph('M19.5 8.5a4 4 0 1 1-8 0 4 4 0 0 1 8 0zM12.7 11.3 4 20M7 17l2.5 2.5M9.6 14.4l2 2');
  static const eye = Glyph('M2.5 12s3.5-6.5 9.5-6.5 9.5 6.5 9.5 6.5-3.5 6.5-9.5 6.5S2.5 12 2.5 12zM12 14.5a2.5 2.5 0 1 0 0-5 2.5 2.5 0 0 0 0 5z');
  static const eyeOff = Glyph(
    'M3.5 3.5l17 17M10.6 5.6c.5-.1.9-.1 1.4-.1 6 0 9.5 6.5 9.5 6.5a15.8 15.8 0 0 1-2.9 3.6M6.4 6.9C3.9 8.6 2.5 12 2.5 12s3.5 6.5 9.5 6.5c1.6 0 3-.4 4.2-1M10.2 10.3a2.5 2.5 0 0 0 3.5 3.5',
  );

  // The app's.
  static const chevronUp = Glyph('M6.5 14.5 12 9l5.5 5.5');
  static const chevronLeft = Glyph('M14.5 6.5 9 12l5.5 5.5');
  static const chevronRight = Glyph('M9.5 6.5 15 12l-5.5 5.5');
  static const back = Glyph('M19 12H5.5M11 6l-6 6 6 6');
  static const arrowUp = Glyph('M12 19V5.5M6 11l6-6 6 6');
  static const arrowDown = Glyph('M12 5v13.5M6 13l6 6 6-6');
  static const unfold = Glyph('M8 9.5 12 5.5l4 4M8 14.5l4 4 4-4');
  static const pause = Glyph('M8 5.5h2v13H8zM14 5.5h2v13h-2z', filled: true);
  static const more = Glyph('M6.6 12a1.1 1.1 0 1 1-2.2 0 1.1 1.1 0 0 1 2.2 0zM13.1 12a1.1 1.1 0 1 1-2.2 0 1.1 1.1 0 0 1 2.2 0zM19.6 12a1.1 1.1 0 1 1-2.2 0 1.1 1.1 0 0 1 2.2 0z', filled: true);
  static const drag = Glyph(
    'M9.9 6a.9.9 0 1 1-1.8 0 .9.9 0 0 1 1.8 0zM15.9 6a.9.9 0 1 1-1.8 0 .9.9 0 0 1 1.8 0zM9.9 12a.9.9 0 1 1-1.8 0 .9.9 0 0 1 1.8 0zM15.9 12a.9.9 0 1 1-1.8 0 .9.9 0 0 1 1.8 0zM9.9 18a.9.9 0 1 1-1.8 0 .9.9 0 0 1 1.8 0zM15.9 18a.9.9 0 1 1-1.8 0 .9.9 0 0 1 1.8 0z',
    filled: true,
  );
  static const checkDouble = Glyph('M2.5 12.5 7 17l9.5-9.5M12 16.5l.5.5L22 7.5');
  static const sync = Glyph('M4.6 10.5a7.5 7.5 0 0 1 13.5-2.9M19.4 13.5a7.5 7.5 0 0 1-13.5 2.9M18.5 3.5V8H14M5.5 20.5V16H10');
  static const moonFilled = Glyph('M20 14.5A8.5 8.5 0 0 1 9.5 4a8.5 8.5 0 1 0 10.5 10.5z', filled: true);
  static const gear = Glyph(
    'M12.22 2.5h-.44a1.8 1.8 0 0 0-1.8 1.8v.2a1.8 1.8 0 0 1-.9 1.56l-.4.23a1.8 1.8 0 0 1-1.8 0l-.15-.08a1.8 1.8 0 0 0-2.46.66l-.22.38a1.8 1.8 0 0 0 .66 2.46l.15.09a1.8 1.8 0 0 1 .9 1.56v.46a1.8 1.8 0 0 1-.9 1.57l-.15.08a1.8 1.8 0 0 0-.66 2.46l.22.38a1.8 1.8 0 0 0 2.46.66l.15-.08a1.8 1.8 0 0 1 1.8 0l.4.23a1.8 1.8 0 0 1 .9 1.56v.2a1.8 1.8 0 0 0 1.8 1.8h.44a1.8 1.8 0 0 0 1.8-1.8v-.2a1.8 1.8 0 0 1 .9-1.56l.4-.23a1.8 1.8 0 0 1 1.8 0l.15.08a1.8 1.8 0 0 0 2.46-.66l.22-.38a1.8 1.8 0 0 0-.66-2.46l-.15-.08a1.8 1.8 0 0 1-.9-1.57v-.46a1.8 1.8 0 0 1 .9-1.56l.15-.09a1.8 1.8 0 0 0 .66-2.46l-.22-.38a1.8 1.8 0 0 0-2.46-.66l-.15.08a1.8 1.8 0 0 1-1.8 0l-.4-.23a1.8 1.8 0 0 1-.9-1.56v-.2a1.8 1.8 0 0 0-1.8-1.8zM12 14.6a2.6 2.6 0 1 0 0-5.2 2.6 2.6 0 0 0 0 5.2z',
  );
  static const headphones = Glyph('M4.5 17v-4.5a7.5 7.5 0 0 1 15 0V17M4.5 14H7v6H5.5a1 1 0 0 1-1-1zM19.5 14H17v6h1.5a1 1 0 0 0 1-1z');
  static const grid = Glyph(
    'M6 4.5h3.5A1.5 1.5 0 0 1 11 6v3.5A1.5 1.5 0 0 1 9.5 11H6a1.5 1.5 0 0 1-1.5-1.5V6A1.5 1.5 0 0 1 6 4.5zM14.5 4.5H18A1.5 1.5 0 0 1 19.5 6v3.5A1.5 1.5 0 0 1 18 11h-3.5A1.5 1.5 0 0 1 13 9.5V6a1.5 1.5 0 0 1 1.5-1.5zM6 13h3.5a1.5 1.5 0 0 1 1.5 1.5V18a1.5 1.5 0 0 1-1.5 1.5H6A1.5 1.5 0 0 1 4.5 18v-3.5A1.5 1.5 0 0 1 6 13zM14.5 13H18a1.5 1.5 0 0 1 1.5 1.5V18a1.5 1.5 0 0 1-1.5 1.5h-3.5A1.5 1.5 0 0 1 13 18v-3.5a1.5 1.5 0 0 1 1.5-1.5z',
  );

  /// Up Next, and playing something next: the list with a play mark.
  static const queue = Glyph('M4.5 6.5h15M4.5 12h15M4.5 17.5h7.5M15.5 15v5l4.5-2.5z');

  /// Playing something last: the list with a plus.
  static const queueAdd = Glyph('M4.5 6.5h15M4.5 12h9M4.5 17.5h7M17.5 13.5v7M14 17h7');

  /// Taking something out of Up Next: the list with a minus.
  static const queueRemove = Glyph('M4.5 6.5h15M4.5 12h9M4.5 17.5h7M14 17h7');

  /// A podcast: a microphone's head inside its waves.
  static const podcast = Glyph('M12 13a2 2 0 1 0 0-4 2 2 0 0 0 0 4zM12 13v7.5M8 14.8a5.5 5.5 0 1 1 8 0M5.3 17a9 9 0 1 1 13.4 0');

  /// A video: a rounded screen with a play mark.
  static const video = Glyph('M5 5.5h14a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-9a2 2 0 0 1 2-2zM10 9.2v5.6l4.8-2.8z');

  /// Saving a video to the library, and saved.
  static const save = Glyph('M8 3.5h10.5a2 2 0 0 1 2 2V16a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2V5.5a2 2 0 0 1 2-2zM3.5 7.5V19a1.5 1.5 0 0 0 1.5 1.5h11.5M13.25 7v7.5M9.5 10.75H17');
  static const saved = Glyph('M8 3.5h10.5a2 2 0 0 1 2 2V16a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2V5.5a2 2 0 0 1 2-2zM3.5 7.5V19a1.5 1.5 0 0 0 1.5 1.5h11.5M9.75 10.75l2.5 2.5 4.5-4.5');

  static const image = Glyph('M4.5 4.5h15v15h-15zM4.5 16l4.5-4.5 4 4 2.5-2.5 4 4M16.5 9a1.5 1.5 0 1 1-3 0 1.5 1.5 0 0 1 3 0z');
  static const globe = Glyph('M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0zM3.5 12h17M12 3a13.5 13.5 0 0 1 0 18M12 3a13.5 13.5 0 0 0 0 18');
  static const cloud = Glyph('M7 18.5a4.5 4.5 0 0 1-.6-8.96 6 6 0 0 1 11.6 1.46 3.75 3.75 0 0 1-.5 7.5z');
  static const cloudOff = Glyph('M7 18.5a4.5 4.5 0 0 1-.6-8.96M9.3 5.7A6 6 0 0 1 18 11a3.75 3.75 0 0 1 1.9 6.1M3.5 3.5l17 17M15 18.5H7');
  static const minusCircle = Glyph('M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0zM8 12h8');
  static const checkCircle = Glyph('M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0zM8 12.5l2.7 2.7L16 10');
  static const pauseCircle = Glyph('M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0zM10 9v6M14 9v6');
  static const downloadCircle = Glyph('M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0zM12 7.5v8M8.5 12.5 12 16l3.5-3.5');
  static const alert = Glyph('M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0zM12 7.5v5.5M12 16.5h.01');
  static const playing = Glyph('M5 10v4M8.5 7v10M12 4.5v15M15.5 8v8M19 10.5v3');

  /// Share, as each OS draws it: a box with an arrow out of it on Apple's,
  /// three joined dots elsewhere. The one icon that follows the OS, since
  /// it stands for the OS's own share sheet.
  static Glyph get share => switch (defaultTargetPlatform) {
    TargetPlatform.iOS || TargetPlatform.macOS => _shareBox,
    _ => _shareNodes,
  };
  static const _shareBox = Glyph('M12 3.5v11M8 7l4-4 4 4M8.5 10H6.5a1 1 0 0 0-1 1v8.5a1 1 0 0 0 1 1h11a1 1 0 0 0 1-1V11a1 1 0 0 0-1-1h-2');
  static const _shareNodes = Glyph(
    'M15.5 5.5a2.5 2.5 0 1 0 5 0 2.5 2.5 0 0 0-5 0zM3.5 12a2.5 2.5 0 1 0 5 0 2.5 2.5 0 0 0-5 0zM15.5 18.5a2.5 2.5 0 1 0 5 0 2.5 2.5 0 0 0-5 0zM8.2 10.8l7.6-4.1M8.2 13.2l7.6 4.1',
  );
}

/// A [Glyph] drawn where an [Icon] would be: its size and colour come from
/// the enclosing [IconTheme] (a button's foreground) unless given.
final class GlyphIcon extends StatelessWidget {
  const GlyphIcon(this.glyph, {super.key, this.size, this.color, this.semanticLabel});
  final Glyph glyph;
  final double? size;
  final Color? color;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    final size = this.size ?? theme.size ?? 24;
    var color = this.color ?? theme.color ?? brand.fg;
    if (theme.opacity case final o? when o < 1) color = color.withValues(alpha: color.a * o);
    final mark = SizedBox.square(dimension: size, child: CustomPaint(painter: _GlyphPainter(glyph, color)));
    return semanticLabel == null ? ExcludeSemantics(child: mark) : Semantics(label: semanticLabel, child: ExcludeSemantics(child: mark));
  }
}

final _glyphPaths = <String, Path>{};

final class _GlyphPainter extends CustomPainter {
  const _GlyphPainter(this.glyph, this.color);
  final Glyph glyph;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24);
    final path = _glyphPaths[glyph.data] ??= _parse(glyph.data);
    if (glyph.filled) canvas.drawPath(path, Paint()..color = color);
    canvas.drawPath(path, Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round);
    if (glyph.label case final label?) {
      final text = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(color: color, fontSize: label.length > 1 ? 7 : 8, fontWeight: FontWeight.w700, height: 1, letterSpacing: -0.2),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      text.paint(canvas, Offset(12 - text.width / 2, 12.2 - text.height / 2));
      text.dispose();
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter old) => old.color != color || old.glyph != glyph;
}
