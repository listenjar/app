// The logo and icons, drawn from the same paths as the website
// (apps/web/src/components/Logo.tsx and Icon.tsx), so nothing is a font or an
// image file.
import 'package:material_ui/material_ui.dart';
import 'package:path_parsing/path_parsing.dart';

import 'theme.dart' as brand;

// Logo.tsx: the folded wave and the outlined Figtree 750 wordmark.
const _wave = 'M60 96A44 44 0 0 1 104 140H144A84 84 0 0 0 60 56';
const _wordmark =
  'M2.16 0V-21H6.62V-4.09H15.72V0ZM17.5 0V-15H21.82V0ZM19.67 -17.18Q18.68 -17.18 17.94 -17.92Q17.2 -18.65 17.2 -19.64Q17.2 -20.65 17.94 -21.38Q18.68 -22.1 19.67 -22.1Q20.68 -22.1 21.4 -21.38Q22.13 -20.65 22.13 -19.64Q22.13 -18.65 21.4 -17.92Q20.68 -17.18 19.67 -17.18ZM30.34 0.36Q28.89 0.36 27.62 -0.07Q26.35 -0.5 25.41 -1.31Q24.46 -2.12 23.96 -3.29L27.58 -4.88Q28 -4.14 28.73 -3.69Q29.47 -3.24 30.34 -3.24Q31.21 -3.24 31.69 -3.51Q32.17 -3.77 32.17 -4.28Q32.17 -4.78 31.74 -5.05Q31.3 -5.31 30.52 -5.5L29.18 -5.84Q27.06 -6.4 25.87 -7.65Q24.68 -8.89 24.68 -10.53Q24.68 -12.84 26.22 -14.1Q27.76 -15.36 30.53 -15.36Q32.03 -15.36 33.25 -14.94Q34.46 -14.51 35.31 -13.75Q36.16 -13 36.51 -12L33.01 -10.48Q32.8 -11.08 32.07 -11.43Q31.34 -11.77 30.56 -11.77Q29.82 -11.77 29.42 -11.46Q29.03 -11.14 29.03 -10.61Q29.03 -10.22 29.45 -9.97Q29.87 -9.71 30.68 -9.52L32.45 -9.08Q33.9 -8.73 34.82 -7.97Q35.74 -7.2 36.18 -6.22Q36.63 -5.24 36.63 -4.22Q36.63 -2.84 35.82 -1.81Q35 -0.77 33.59 -0.21Q32.18 0.36 30.34 0.36ZM44.59 0.36Q42.02 0.36 40.72 -0.89Q39.43 -2.15 39.43 -4.47V-11.35H37.05V-15H39.43V-19.68H43.75V-15H47.34V-11.35H43.75V-5.5Q43.75 -4.55 44.12 -4.1Q44.5 -3.64 45.26 -3.64Q45.54 -3.64 45.9 -3.78Q46.25 -3.92 46.6 -4.16L48.1 -0.96Q47.38 -0.39 46.44 -0.02Q45.5 0.36 44.59 0.36ZM56.9 0.36Q54.63 0.36 52.88 -0.64Q51.12 -1.64 50.12 -3.41Q49.12 -5.18 49.12 -7.5Q49.12 -9.82 50.14 -11.59Q51.16 -13.36 52.94 -14.36Q54.72 -15.36 57.04 -15.36Q59.1 -15.36 60.79 -14.33Q62.48 -13.31 63.48 -11.3Q64.49 -9.29 64.49 -6.37H53.63Q53.78 -4.97 54.8 -4.15Q55.82 -3.32 57.18 -3.32Q58.35 -3.32 59.12 -3.83Q59.89 -4.34 60.25 -5.15L64.09 -3.74Q63.48 -2.41 62.43 -1.48Q61.38 -0.56 59.98 -0.1Q58.58 0.36 56.9 0.36ZM53.79 -9.41H59.89Q59.79 -10.31 59.31 -10.86Q58.83 -11.41 58.18 -11.66Q57.54 -11.91 56.91 -11.91Q56.3 -11.91 55.62 -11.67Q54.95 -11.43 54.43 -10.88Q53.92 -10.33 53.79 -9.41ZM66.03 0V-15H70.1L70.28 -13.02Q71.01 -14.15 72.11 -14.75Q73.22 -15.36 74.6 -15.36Q76.4 -15.36 77.64 -14.63Q78.89 -13.91 79.52 -12.4Q80.16 -10.89 80.15 -8.52V0H75.83V-7.68Q75.83 -9.04 75.52 -9.81Q75.21 -10.59 74.65 -10.94Q74.08 -11.29 73.31 -11.31Q71.87 -11.35 71.11 -10.48Q70.35 -9.61 70.35 -7.9V0ZM87.07 0.44Q85.43 0.44 84.18 -0.1Q82.93 -0.63 82.08 -1.48Q81.22 -2.33 80.75 -3.29Q80.28 -4.24 80.15 -5.08L83.98 -6.44Q84.41 -5.1 85.19 -4.38Q85.96 -3.66 87.11 -3.66Q88 -3.66 88.75 -4.05Q89.49 -4.45 89.94 -5.31Q90.4 -6.17 90.4 -7.53V-21H94.86V-6.3Q94.86 -4.76 94.29 -3.51Q93.72 -2.26 92.68 -1.38Q91.64 -0.5 90.2 -0.03Q88.77 0.44 87.07 0.44ZM102.58 0.36Q99.9 0.36 98.42 -0.84Q96.94 -2.03 96.94 -4.23Q96.94 -6.61 98.51 -7.81Q100.08 -9 102.91 -9H106.51Q106.33 -10.28 105.73 -10.99Q105.12 -11.69 103.89 -11.69Q102.98 -11.69 102.28 -11.29Q101.57 -10.88 101.09 -10.11L97.3 -11.38Q97.77 -12.41 98.61 -13.32Q99.46 -14.24 100.76 -14.8Q102.05 -15.36 103.86 -15.36Q106.17 -15.36 107.73 -14.49Q109.3 -13.62 110.07 -12.05Q110.85 -10.48 110.83 -8.34L110.76 0H106.72L106.66 -1.63Q106.07 -0.66 105.04 -0.15Q104.02 0.36 102.58 0.36ZM103.43 -3.06Q104.33 -3.06 105.05 -3.47Q105.77 -3.87 106.18 -4.54Q106.6 -5.2 106.6 -5.95V-6.02H104.48Q102.76 -6.02 102.05 -5.58Q101.35 -5.14 101.35 -4.35Q101.35 -3.74 101.9 -3.4Q102.44 -3.06 103.43 -3.06ZM113.22 0V-15H117.54V-12.23Q118.47 -13.64 119.9 -14.35Q121.33 -15.06 122.85 -15.06V-10.87Q121.47 -10.87 120.25 -10.55Q119.04 -10.23 118.29 -9.55Q117.54 -8.86 117.54 -7.79V0Z';

// Icon.tsx: a 24 grid, 1.8 round strokes.
const _arrow = 'M5 12h13M13 6l6 6-6 6';

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
final _arrowPath = _parse(_arrow);

/// The logo in its paper colourway: a white mark on a periwinkle tile and a
/// periwinkle wordmark. [height] is the tile's; the viewBox is 183.27 × 48.
Widget logo({double height = 30}) => Semantics(
  label: 'ListenJar',
  image: true,
  child: CustomPaint(size: Size(height * 183.27 / 48, height), painter: const _Logo()),
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
  Widget build(BuildContext context) => CustomPaint(
    size: Size.square(size),
    painter: _Stroke(_arrowPath, color ?? IconTheme.of(context).color ?? brand.fg),
  );
}

final class _Stroke extends CustomPainter {
  const _Stroke(this.path, this.color);
  final Path path;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24);
    canvas.drawPath(path, Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round);
  }

  @override
  bool shouldRepaint(_Stroke oldDelegate) => oldDelegate.color != color || oldDelegate.path != path;
}
