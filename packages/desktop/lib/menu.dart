// The app's one dropdown: every "More", choice and split-button menu opens
// through [Dropdown] and is built from [MenuEntry], [MenuHeader] and
// [MenuDivider], so a menu looks and behaves the same wherever it opens.
//
// Two tones (DESIGN.md, "The Two-Tone Rule"): paper menus are white panels
// on a soft tinted shadow; ink menus, opened from the player, are a step of
// raised ink with a hairline where the shadow vanishes against ink. Rows are
// 36px, 8px corners inside the 14px panel's 6px padding, and highlight to
// mist (or a white tint on ink) on hover and keyboard focus, their icon
// turning to the accent.
import 'package:material_ui/material_ui.dart';

import 'marks.dart';
import 'theme.dart' as brand;

enum MenuTone { paper, ink }

/// Which edge of the anchor the menu lines up with: start for menus that
/// open from a field or a left-hand button, end for trailing "More" buttons.
enum MenuAlign { start, end }

extension MenuToggle on MenuController {
  void toggle() => isOpen ? close() : open();
}

/// A menu that opens from what [builder] draws.
final class Dropdown extends StatelessWidget {
  const Dropdown({
    super.key,
    required this.items,
    required this.builder,
    this.tone = MenuTone.paper,
    this.align = MenuAlign.start,
  });

  final List<Widget> items;
  final Widget Function(BuildContext context, MenuController menu) builder;
  final MenuTone tone;
  final MenuAlign align;

  @override
  Widget build(BuildContext context) {
    final ltr = Directionality.of(context);
    // MenuAnchor only lines a menu's start edge up with the anchor. Laid out
    // right-to-left, its start is its right edge, so an end-aligned menu is
    // an RTL anchor whose button and rows are set back to the ambient
    // direction.
    final end = align == MenuAlign.end;
    final flipped = switch (ltr) {
      TextDirection.ltr => end ? TextDirection.rtl : TextDirection.ltr,
      TextDirection.rtl => end ? TextDirection.ltr : TextDirection.rtl,
    };
    Widget restore(Widget child) => Directionality(textDirection: ltr, child: child);
    return _Tone(
      tone: tone,
      child: Theme(
        data: menuTheme(Theme.of(context), tone),
        child: Directionality(
          textDirection: flipped,
          child: MenuAnchor(
            alignmentOffset: const Offset(0, 6),
            menuChildren: [
              for (final item in items) restore(SizedBox(width: double.infinity, child: item)),
            ],
            builder: (context, menu, _) => restore(builder(context, menu)),
          ),
        ),
      ),
    );
  }
}

final class _Tone extends InheritedWidget {
  const _Tone({required this.tone, required super.child});
  final MenuTone tone;

  static MenuTone of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_Tone>()?.tone ?? MenuTone.paper;

  @override
  bool updateShouldNotify(_Tone old) => tone != old.tone;
}

/// The colours a menu takes in each tone.
typedef _Palette = ({
  Color surface,
  Color text,
  Color soft,
  Color faint,
  Color hover,
  Color press,
  Color accent,
  Color danger,
  Color line,
});

_Palette _palette(MenuTone tone) => switch (tone) {
  MenuTone.paper => (
    surface: brand.white,
    text: brand.fg,
    soft: brand.fgSoft,
    faint: brand.fgFaint,
    hover: brand.mist,
    press: brand.lavender,
    accent: brand.accent,
    danger: brand.danger,
    line: brand.line,
  ),
  MenuTone.ink => (
    surface: brand.inkFloat,
    text: brand.snow,
    soft: brand.snowSoft,
    faint: brand.snowFaint,
    hover: const Color(0x14FFFFFF),
    press: const Color(0x1FFFFFFF),
    accent: brand.accentLight,
    danger: brand.dangerOnInk,
    line: brand.inkLine,
  ),
};

/// [base] with the menu panel and rows of [tone]; theme() installs the
/// paper one app-wide, and [Dropdown] the one it opens with.
ThemeData menuTheme(ThemeData base, MenuTone tone) {
  final p = _palette(tone);
  // The Opaque Fade Rule: rows fade from the hover colour at alpha 0.
  final rest = p.hover.withAlpha(0);
  return base.copyWith(
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(p.surface),
        surfaceTintColor: const WidgetStatePropertyAll(Color(0x00000000)),
        // Paper floats on a soft shadow tinted toward ink-blue. Ink menus
        // also open over paper (from the mini player), so they keep a
        // shadow, and add a hairline for where it vanishes against ink.
        elevation: const WidgetStatePropertyAll(10),
        shadowColor: WidgetStatePropertyAll(tone == MenuTone.paper ? const Color(0xFF171A38) : brand.ink),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: tone == MenuTone.ink ? BorderSide(color: p.line) : BorderSide.none,
        )),
        padding: const WidgetStatePropertyAll(EdgeInsets.all(6)),
        minimumSize: const WidgetStatePropertyAll(Size(200, 0)),
        maximumSize: const WidgetStatePropertyAll(Size(340, double.infinity)),
      ),
    ),
    menuButtonTheme: MenuButtonThemeData(style: _row(p, rest)),
  );
}

ButtonStyle _row(_Palette p, Color rest, {bool danger = false}) {
  final ink = danger ? p.danger : p.text;
  return ButtonStyle(
    minimumSize: const WidgetStatePropertyAll(Size(0, 36)),
    padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 10)),
    visualDensity: VisualDensity.standard,
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    shape: const WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(8)))),
    textStyle: const WidgetStatePropertyAll(TextStyle(fontSize: 14.5, height: 1.25, letterSpacing: 0)),
    backgroundColor: WidgetStateProperty.fromMap({
      WidgetState.disabled: rest,
      WidgetState.pressed: p.press,
      WidgetState.hovered | WidgetState.focused: p.hover,
      WidgetState.any: rest,
    }),
    foregroundColor: WidgetStateProperty.fromMap({WidgetState.disabled: p.faint, WidgetState.any: ink}),
    iconColor: WidgetStateProperty.fromMap({
      WidgetState.disabled: p.faint,
      WidgetState.hovered | WidgetState.focused: danger ? p.danger : p.accent,
      WidgetState.any: danger ? p.danger : p.soft,
    }),
    iconSize: const WidgetStatePropertyAll(18),
    overlayColor: WidgetStatePropertyAll(rest),
    elevation: const WidgetStatePropertyAll(0),
    animationDuration: Duration.zero,
    mouseCursor: WidgetStateProperty.fromMap({WidgetState.disabled: SystemMouseCursors.basic, WidgetState.any: SystemMouseCursors.click}),
  );
}

/// The "…" that opens a trailing menu, held down while the menu is open.
final class MoreButton extends StatelessWidget {
  const MoreButton({super.key, required this.menu, this.tooltip = 'More', this.tone = MenuTone.paper, this.compact = false});
  final MenuController menu;
  final String tooltip;
  final MenuTone tone;

  /// Inside a pill of buttons: as tall as the pill and a little narrower,
  /// in the pill's own icon colour.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final ink = tone == MenuTone.ink;
    final held = ink ? brand.inkTile : brand.paperDeep;
    return IconButton(
      tooltip: tooltip,
      style: IconButton.styleFrom(
        // The Opaque Fade Rule: the held fill fades from itself at alpha 0.
        backgroundColor: menu.isOpen ? held : held.withAlpha(0),
        hoverColor: held,
        highlightColor: held.withAlpha(0),
      ),
      constraints: compact ? const BoxConstraints.tightFor(width: 42, height: 44) : null,
      padding: compact ? EdgeInsets.zero : null,
      onPressed: menu.toggle,
      icon: GlyphIcon(Glyphs.more, color: ink ? brand.snow : (compact ? brand.fg : brand.fgSoft)),
    );
  }
}

/// A row in a [Dropdown].
///
/// [checked] makes it one of a set of choices: the check sits where the
/// icon would, accent when chosen and an empty column when not. [danger]
/// is for rows that take something away (unfollow, delete a download).
/// [leading] stands in for [icon] when the row shows a picture. [count] is
/// a plain number at the row's end, in the faint colour.
final class MenuEntry extends StatelessWidget {
  const MenuEntry(
    this.label, {
    super.key,
    this.icon,
    this.leading,
    this.onPressed,
    this.checked,
    this.danger = false,
    this.tabular = false,
    this.count,
  });

  final String label;
  final Glyph? icon;
  final Widget? leading;
  final VoidCallback? onPressed;
  final bool? checked;
  final bool danger;
  final bool tabular;
  final String? count;

  @override
  Widget build(BuildContext context) {
    final p = _palette(_Tone.of(context));
    final lead = switch (checked) {
      true => GlyphIcon(Glyphs.check, size: 18, color: p.accent),
      false => const SizedBox.square(dimension: 18),
      null => leading ?? switch (icon) { final icon? => GlyphIcon(icon), null => null },
    };
    return MenuItemButton(
      style: danger ? _row(p, p.hover.withAlpha(0), danger: true) : null,
      leadingIcon: lead,
      trailingIcon: count == null
        ? null
        : Text(count!, style: TextStyle(color: p.faint, fontSize: 13.5, fontFeatures: const [FontFeature.tabularFigures()])),
      onPressed: onPressed,
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: tabular ? const TextStyle(fontFeatures: [FontFeature.tabularFigures()]) : null,
      ),
    );
  }
}

/// A quiet label over a group of rows, lined up with the rows' labels.
final class MenuHeader extends StatelessWidget {
  const MenuHeader(this.label, {super.key});
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    // A row's side padding, its 18px leading column and the 8px gap.
    padding: const EdgeInsets.fromLTRB(36, 8, 10, 4),
    child: Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, height: 1.2, color: _palette(_Tone.of(context)).soft),
    ),
  );
}

/// A hairline between groups of rows.
final class MenuDivider extends StatelessWidget {
  const MenuDivider({super.key});

  @override
  Widget build(BuildContext context) =>
    Divider(height: 13, thickness: 1, indent: 10, endIndent: 10, color: _palette(_Tone.of(context)).line);
}

/// The colour of secondary text inside a menu of the current tone, for
/// rows that are not [MenuEntry]s (the account card).
Color menuSoft(BuildContext context) => _palette(_Tone.of(context)).soft;
