// Settings: the ListenJar Cloud account (cloud.dart), how the player skips and downloads, the space downloads take
// (storage_page.dart), moving shows in and out, and what the app sends where.
import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import 'cloud.dart' show AccountPanel;
import 'library.dart';
import 'library_page.dart' show exportOpml, importOpml;
import 'menu.dart';
import 'now_playing.dart' show speedLabel;
import 'player.dart' show speeds;
import 'plans.dart' show formatBytes;
import 'shell.dart';
import 'storage_page.dart';
import 'theme.dart' as brand;
import 'ui.dart';

final class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, this.pushed = false});
  final bool pushed;

  @override
  Widget build(BuildContext context) {
    final s = Services.of(context);
    final mobile = Platform.isAndroid || Platform.isIOS;
    final page = ListenableBuilder(
      listenable: s.library,
      builder: (context, _) {
        final settings = s.library.settings;
        void set(PlayerSettings next) => s.library.updateSettings(next);
        return PageBody(maxWidth: 720, children: [
          if (pushed) backButton(context, 'Library'),
          pageTitle(context, 'Settings'),
          sectionHeading(context, 'ListenJar Cloud', top: 20),
          const AccountPanel(),
          sectionHeading(context, 'Playback'),
          _group([
            _choice(
              context,
              'Skip back',
              settings.skipBack.inSeconds,
              const [5, 10, 15, 30],
              (v) => '$v seconds',
              (v) => set(settings.copyWith(skipBack: Duration(seconds: v))),
            ),
            _choice(
              context,
              'Skip forward',
              settings.skipForward.inSeconds,
              const [10, 15, 30, 45, 60],
              (v) => '$v seconds',
              (v) => set(settings.copyWith(skipForward: Duration(seconds: v))),
            ),
            _choice(
              context,
              'Speed',
              settings.speed,
              speeds,
              speedLabel,
              (v) => unawaited(s.player.setSpeed(v)),
            ),
            _toggle(
              context,
              'Headphone buttons skip',
              'Next and previous on headphones, keyboards and the lock screen skip forward and back. Off, they change episodes.',
              settings.remoteSkips,
              (v) => set(settings.copyWith(remoteSkips: v)),
            ),
          ]),
          sectionHeading(context, 'Downloads'),
          _group([
            _toggle(
              context,
              'Download new episodes',
              'Every show you follow downloads its new episodes as they arrive. Each show can also do this on its own.',
              settings.autoDownload,
              (v) => set(settings.copyWith(autoDownload: v)),
            ),
            if (mobile)
              _toggle(
                context,
                'Only on Wi-Fi',
                'New episodes wait for Wi-Fi before they download. Episodes you download yourself go at once.',
                settings.wifiOnly,
                (v) => set(settings.copyWith(wifiOnly: v)),
              ),
            _action(
              context,
              'Storage',
              _storageSummary(s.library),
              () => unawaited(Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const StoragePage(back: 'Settings')))),
            ),
          ]),
          sectionHeading(context, 'Your shows'),
          _group([
            _action(context, 'Import from another podcast app', 'Choose an OPML file it exported.', () => unawaited(importOpml(context))),
            _action(context, 'Export for another podcast app', 'Saves every show you follow as an OPML file.', () => unawaited(exportOpml(context))),
          ]),
          sectionHeading(context, 'Privacy'),
          Text(
            'Your library, your place in each episode and your downloads stay on this device. '
            'The app fetches feeds and audio from each podcast’s host, searches podcasts through Apple’s directory, '
            'and reaches YouTube for YouTube search and videos. It talks to ListenJar only when you’re signed in. '
            'No telemetry, tracing or crash reports.',
            style: Theme.of(context).textTheme.bodyMedium!.copyWith(color: brand.fgSoft),
          ),
        ]);
      },
    );
    return pushed ? Scaffold(body: SafeArea(child: page)) : page;
  }

  Widget _group(List<Widget> rows) => rowsPanel(rows);

  /// What downloads take now, and the limit on them.
  String _storageSummary(Library library) {
    final bytes = storedBytes(library);
    final limit = library.settings.storageLimit;
    final used = bytes == 0 ? 'No downloads on this device' : '${formatBytes(bytes)} of downloads';
    return limit == null ? '$used. Set a limit and what goes on its own.' : '$used, up to ${formatBytes(limit)}.';
  }

  Widget _toggle(BuildContext context, String title, String body, bool value, void Function(bool) onChanged) => settingRow(
    context,
    title,
    body,
    Switch.adaptive(
      value: value,
      onChanged: onChanged,
      activeTrackColor: brand.accent,
      activeThumbColor: brand.white,
    ),
    onTap: () => onChanged(!value),
  );

  Widget _choice<T>(BuildContext context, String title, T value, List<T> options, String Function(T) label, void Function(T) onChanged) =>
    settingChoice(context, title, null, value, options, label, onChanged);

  Widget _action(BuildContext context, String title, String body, VoidCallback onTap) =>
    settingRow(context, title, body, const Icon(Icons.chevron_right_rounded, color: brand.fgSoft), onTap: onTap);
}

/// A row of a settings panel: what it is, a line on what it does, and its
/// control.
Widget settingRow(BuildContext context, String title, String? body, Widget trailing, {VoidCallback? onTap}) {
  final text = Theme.of(context).textTheme;
  return InkWell(
    borderRadius: BorderRadius.circular(14),
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 10, 14),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: text.titleMedium!.copyWith(fontSize: 15)),
            if (body != null) ...[
              const SizedBox(height: 3),
              Text(body, style: text.bodySmall!.copyWith(color: brand.fgSoft, fontSize: 13.5)),
            ],
          ]),
        ),
        const SizedBox(width: 16),
        trailing,
      ]),
    ),
  );
}

/// A settings row that picks one of [options] from a menu.
Widget settingChoice<T>(
  BuildContext context,
  String title,
  String? body,
  T value,
  List<T> options,
  String Function(T) label,
  void Function(T) onChanged,
) =>
  settingRow(
    context,
    title,
    body,
    Dropdown(
      align: MenuAlign.end,
      items: [
        for (final option in options)
          MenuEntry(label(option), checked: option == value, tabular: true, onPressed: () => onChanged(option)),
      ],
      builder: (context, menu) => TextButton.icon(
        style: brand.button(brand.Tone.quiet, brand.ButtonSize.sm),
        onPressed: menu.toggle,
        iconAlignment: IconAlignment.end,
        icon: const Icon(Icons.unfold_more_rounded, size: 18),
        label: Text(label(value), style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
      ),
    ),
  );
