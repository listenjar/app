// Settings: the Listenjar Cloud account (cloud.dart), how the player skips and downloads, the space downloads take
// (storage_page.dart), moving shows in and out, updates (updates.dart), and what the app sends where.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';
import 'package:share_plus/share_plus.dart';

import 'cloud.dart' show AccountPanel;
import 'library.dart';
import 'marks.dart';
import 'menu.dart';
import 'now_playing.dart' show speedLabel;
import 'player.dart' show speeds;
import 'plans.dart' show formatBytes;
import 'shell.dart';
import 'storage_page.dart';
import 'theme.dart' as brand;
import 'ui.dart';
import 'updates.dart';

final class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, this.pushed = false});
  final bool pushed;

  @override
  Widget build(BuildContext context) {
    final s = Services.of(context);
    final mobile = Platform.isAndroid || Platform.isIOS;
    final page = ListenableBuilder(
      listenable: Listenable.merge([s.library, s.account]),
      builder: (context, _) {
        final settings = s.library.settings;
        void set(PlayerSettings next) => s.library.updateSettings(next);
        return PageBody(maxWidth: 720, children: [
          if (pushed) backButton(context, 'Library'),
          pageTitle(context, 'Settings'),
          sectionHeading(context, 'Listenjar Cloud', top: 20),
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
              () => unawaited(Navigator.of(context).push(pageRoute(const StoragePage(back: 'Settings')))),
            ),
          ]),
          sectionHeading(context, 'Your shows'),
          _group([
            _action(context, 'Import from another podcast app', 'Choose an OPML file it exported.', () => unawaited(importOpml(context))),
            _action(context, 'Export for another podcast app', 'Saves every show you follow as an OPML file.', () => unawaited(exportOpml(context))),
          ]),
          if (updatesSupported) ...[
            sectionHeading(context, 'Updates'),
            const _Updates(),
          ],
          sectionHeading(context, 'Privacy'),
          Text(
            'Your library, your place in each episode and your downloads stay on this device. '
            'The app fetches feeds and audio from each podcast’s host, searches podcasts through Apple’s directory, '
            'and reaches YouTube for YouTube search and videos. It talks to Listenjar only when you’re signed in. '
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

  Widget _toggle(BuildContext context, String title, String body, bool value, void Function(bool) onChanged) =>
    _switch(context, title, body, value, onChanged);

  Widget _choice<T>(BuildContext context, String title, T value, List<T> options, String Function(T) label, void Function(T) onChanged) =>
    settingChoice(context, title, null, value, options, label, onChanged);

  Widget _action(BuildContext context, String title, String body, VoidCallback onTap) =>
    settingRow(context, title, body, const GlyphIcon(Glyphs.chevronRight, color: brand.fgSoft), onTap: onTap);
}

/// Sparkle's, WinSparkle's and Android's update preferences (updates.dart).
/// A build without an update key says so instead.
final class _Updates extends StatelessWidget {
  const _Updates();

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: updates,
    builder: (context, state, _) {
      if (state == null) return const SizedBox.shrink();
      final version = state.version.isEmpty ? '' : 'This is version ${state.version}. ';
      if (!state.available) {
        return Text(
          '${version}This build doesn’t update itself: the ones from listenjar.com do.',
          style: Theme.of(context).textTheme.bodyMedium!.copyWith(color: brand.fgSoft),
        );
      }
      final downloads = state.automaticDownloads;
      return rowsPanel([
        settingRow(
          context,
          'Check for updates',
          state.status ?? '${version}Listenjar also looks once a day.',
          const GlyphIcon(Glyphs.chevronRight, color: brand.fgSoft),
          onTap: state.canCheck ? () => unawaited(checkForUpdates()) : null,
        ),
        _switch(
          context,
          'Check automatically',
          Platform.isWindows
            ? 'Looks for a new version every day. A change applies the next time Listenjar starts.'
            : 'Looks for a new version every day.',
          state.automatic,
          (v) => unawaited(setAutomaticUpdates(v)),
        ),
        if (downloads != null)
          _switch(
            context,
            'Install automatically',
            'New versions download in the background and install when Listenjar quits.',
            downloads,
            (v) => unawaited(setAutomaticDownloads(v)),
          ),
      ]);
    },
  );
}

/// A settings row with a switch; the whole row toggles it.
Widget _switch(BuildContext context, String title, String body, bool value, void Function(bool) onChanged) => settingRow(
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
        icon: const GlyphIcon(Glyphs.unfold, size: 18),
        label: Text(label(value), style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
      ),
    ),
  );

const _opml = XTypeGroup(label: 'OPML', extensions: ['opml', 'xml'], uniformTypeIdentifiers: ['public.xml', 'public.data'], mimeTypes: ['text/x-opml', 'text/xml', 'application/xml']);

Future<void> importOpml(BuildContext context) async {
  final podcasts = Services.of(context).podcasts;
  final file = await openFile(acceptedTypeGroups: const [_opml]);
  if (file == null || !context.mounted) return;
  tell(context, 'Importing your shows…');
  try {
    final (followed, failed) = await podcasts.importOpml(utf8.decode(await file.readAsBytes(), allowMalformed: true));
    if (!context.mounted) return;
    tell(context, [
      'Followed $followed ${followed == 1 ? 'show' : 'shows'}.',
      if (failed > 0) '$failed couldn’t be read.',
    ].join(' '));
    unawaited(podcasts.refreshAll(force: true));
  } catch (e) {
    if (context.mounted) tell(context, 'Couldn’t import that file: $e');
  }
}

Future<void> exportOpml(BuildContext context) async {
  final podcasts = Services.of(context).podcasts;
  final data = XFile.fromData(utf8.encode(podcasts.exportOpml()), mimeType: 'text/x-opml', name: 'Listenjar.opml');
  // Phones have no save dialog: the share sheet saves to Files or Drive,
  // or hands the file to another podcast app.
  if (Platform.isAndroid || Platform.isIOS) {
    final box = context.findRenderObject() as RenderBox?;
    await SharePlus.instance.share(ShareParams(
      files: [data],
      fileNameOverrides: const ['Listenjar.opml'],
      sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
    ));
    return;
  }
  final where = await getSaveLocation(suggestedName: 'Listenjar.opml', acceptedTypeGroups: const [_opml]);
  if (where == null) return;
  await data.saveTo(where.path);
  if (context.mounted) tell(context, 'Exported your shows.');
}
