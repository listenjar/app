// ListenJar's design system, the one listenjar.com uses: DESIGN.md at the
// listeners root records it and apps/web/src/styles/app.css ships it. The app
// is a working surface, so it takes the website's paper side (the dashboard):
// warm paper ground, white panels with soft shadows, one periwinkle accent
// for everything you can press, and the platform's own UI face set heavy and
// tight for headings. Import as `brand`.
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import 'menu.dart';

// Colours (DESIGN.md "Colors").
const paper = Color(0xFFF5F4F0);
const paperDeep = Color(0xFFEBE9E3);
const ink = Color(0xFF0A0B0F);
const line = Color(0x14111217);
const fg = Color(0xFF1C1D20);
const fgSoft = Color(0xFF5B5E69);

/// Disabled text and decorative arrows only: 3.3:1 on white.
const fgFaint = Color(0xFF8A8D98);
const accent = Color(0xFF5165EE);
const accentHover = Color(0xFF4054E0);
const lavender = Color(0xFFE7E4FC);
const mist = Color(0xFFEEF0FD);
const danger = Color(0xFFD4483F);
const white = Color(0xFFFFFFFF);

// The ink side (DESIGN.md "Neutral", "The Two-Tone Rule"): the player's own
// surfaces, where listening happens.
const inkRaised = Color(0xFF15161C);

/// What floats over ink: menus opened from the player, a step above
/// [inkRaised] so they read over the glows without a shadow.
const inkFloat = Color(0xFF1D1E27);
const inkLine = Color(0x17FFFFFF);
const inkTile = Color(0x0DFFFFFF);
const snow = Color(0xFFF3F4F7);
const snowSoft = Color(0xFFA5A8B6);
const snowFaint = Color(0xFF8B8E9C);
const accentLight = Color(0xFF8F9CFF);
const violet = Color(0xFF8E79FD);
const ok = Color(0xFF377D40);
const okOnInk = Color(0xFF7FD08A);
const dangerOnInk = Color(0xFFFF8A80);

/// Float: dark cards and the mini player (DESIGN.md "Shadow Vocabulary").
const shadowFloat = BoxShadow(
  color: Color(0x470A0B0F),
  offset: Offset(0, 24),
  blurRadius: 48,
  spreadRadius: -18,
);

/// The ink panel's two glows: periwinkle top-left, violet bottom-right.
const inkGlow = [
  RadialGradient(center: Alignment(-0.9, -1), radius: 1.1, colors: [Color(0x4D5165EE), Color(0x005165EE)]),
  RadialGradient(center: Alignment(1, 1.1), radius: 1.0, colors: [Color(0x408E79FD), Color(0x008E79FD)]),
];

/// An ink surface with its glows, for the player.
Widget inkSurface({required Widget child, BorderRadius? radius}) => DecoratedBox(
  decoration: BoxDecoration(color: ink, borderRadius: radius),
  child: DecoratedBox(
    decoration: BoxDecoration(gradient: inkGlow[0], borderRadius: radius),
    child: DecoratedBox(
      decoration: BoxDecoration(gradient: inkGlow[1], borderRadius: radius),
      child: child,
    ),
  ),
);

// Corners (DESIGN.md "Shapes").
const radiusCard = 28.0;
const radiusSheet = 22.0;
const radiusTile = 18.0;

// Shadows: long, soft and tinted (DESIGN.md "Shadow Vocabulary").
const shadowSoft = BoxShadow(
  color: Color(0x2E171A38),
  offset: Offset(0, 12),
  blurRadius: 32,
  spreadRadius: -14,
);
const shadowAccent = BoxShadow(
  color: Color(0xE65165EE),
  offset: Offset(0, 10),
  blurRadius: 24,
  spreadRadius: -12,
);

/// The web's 150ms ease-out-expo.
const quick = Duration(milliseconds: 150);
const easeOutExpo = Cubic(0.16, 1, 0.3, 1);

/// The global focus ring: 2px periwinkle outside the control.
const focusSide = BorderSide(color: accent, width: 2, strokeAlign: BorderSide.strokeAlignOutside);

/// [focusSide] while unfocused: the same ring at alpha 0. Flutter's lerps
/// don't premultiply alpha, so a fade from BorderSide.none (transparent
/// black) or `Color(0x00000000)` passes through dark grey; animate between
/// opaque colours, or from the target colour at alpha 0 (DESIGN.md, "The
/// Opaque Fade Rule").
const focusSideOff = BorderSide(color: Color(0x005165EE), width: 2, strokeAlign: BorderSide.strokeAlignOutside);

/// A heading in the display voice: weight 700, tracked tight.
TextStyle _display(double size, double height, [double tracking = -0.03]) => TextStyle(
  fontSize: size,
  fontWeight: FontWeight.w700,
  height: height,
  letterSpacing: size * tracking,
);

/// The platform's own face (SF Pro, Segoe UI, Roboto): no font ships.
TextTheme _face() => Typography.material2021(platform: defaultTargetPlatform).black;

ThemeData theme() => menuTheme(_theme(), MenuTone.paper);

ThemeData _theme() {
  final text = _face()
    .merge(TextTheme(
      headlineMedium: _display(36, 1.1),
      titleLarge: _display(20, 1.2, -0.02),
      titleMedium: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, height: 1.3, letterSpacing: 0),
      bodyLarge: const TextStyle(fontSize: 17, height: 1.55, letterSpacing: 0),
      bodyMedium: const TextStyle(fontSize: 16, height: 1.55, letterSpacing: 0),
      bodySmall: const TextStyle(fontSize: 14, height: 1.45, letterSpacing: 0),
      labelLarge: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, height: 1, letterSpacing: 0),
    ))
    .apply(bodyColor: fg, displayColor: fg);
  return ThemeData(
    useMaterial3: true,
    colorScheme: const ColorScheme(
      brightness: Brightness.light,
      primary: accent,
      onPrimary: white,
      secondary: accent,
      onSecondary: white,
      error: danger,
      onError: white,
      surface: paper,
      onSurface: fg,
      onSurfaceVariant: fgSoft,
      outline: line,
      outlineVariant: line,
    ),
    scaffoldBackgroundColor: paper,
    textTheme: text,
    splashFactory: NoSplash.splashFactory,
    textSelectionTheme: const TextSelectionThemeData(cursorColor: accent, selectionColor: lavender),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStateProperty.fromMap({WidgetState.hovered: fgSoft, WidgetState.any: fgFaint}),
      radius: const Radius.circular(8),
      thickness: const WidgetStatePropertyAll(6),
    ),
  );
}

enum Tone { accent, ink, quiet }

enum ButtonSize { sm, md }

/// The web's `button(tone, size)` (apps/web/src/components/ui.ts): solid,
/// 600 weight, hover a step darker, deep paper when disabled. Accent is the
/// one primary action per view; wrap it in [accentShadow].
ButtonStyle button(Tone tone, [ButtonSize size = ButtonSize.md]) {
  final (background, hover, foreground) = switch (tone) {
    Tone.accent => (accent, accentHover, white),
    Tone.ink => (ink, const Color(0xFF23252D), white),
    Tone.quiet => (paper, paperDeep, fg),
  };
  final (height, side, radius, font) = switch (size) {
    ButtonSize.sm => (38.0, 18.0, 12.0, 14.0),
    ButtonSize.md => (44.0, 20.0, 14.0, 15.0),
  };
  return ButtonStyle(
    minimumSize: WidgetStatePropertyAll(Size(0, height)),
    padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: side)),
    textStyle: WidgetStatePropertyAll(_face().labelLarge!.copyWith(
      fontSize: font,
      fontWeight: FontWeight.w600,
      height: 1,
      letterSpacing: 0,
    )),
    backgroundColor: WidgetStateProperty.fromMap({
      WidgetState.disabled: paperDeep,
      WidgetState.hovered: hover,
      WidgetState.any: background,
    }),
    foregroundColor: WidgetStateProperty.fromMap({WidgetState.disabled: fgFaint, WidgetState.any: foreground}),
    iconColor: WidgetStateProperty.fromMap({WidgetState.disabled: fgFaint, WidgetState.any: foreground}),
    overlayColor: const WidgetStatePropertyAll(Color(0x00000000)),
    elevation: const WidgetStatePropertyAll(0),
    shape: WidgetStateProperty.resolveWith((states) => RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radius),
      side: states.contains(WidgetState.focused) ? focusSide : focusSideOff,
    )),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    animationDuration: quick,
  );
}

/// The accent shadow under an enabled accent button.
Widget accentShadow({required bool enabled, required Widget child}) => DecoratedBox(
  decoration: BoxDecoration(
    borderRadius: BorderRadius.circular(14),
    boxShadow: enabled ? const [shadowAccent] : null,
  ),
  child: child,
);

/// A dashboard panel: white, 28px corners, the soft shadow.
Widget panel({required Widget child, double padding = 28}) => DecoratedBox(
  decoration: BoxDecoration(
    color: white,
    borderRadius: BorderRadius.circular(radiusCard),
    boxShadow: const [shadowSoft],
  ),
  child: Padding(padding: EdgeInsets.all(padding), child: child),
);
