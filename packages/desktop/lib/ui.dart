// The player's shared pieces, in the app's design language (theme.dart,
// DESIGN.md at the monorepo root): show artwork, the episode row every list
// uses, its play and download buttons and menu, the episode sheet with show
// notes, and how times and dates read. Screens are in shell.dart and the
// files it names.
import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart' show RenderObject, RenderParagraph;
import 'package:flutter/services.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:material_ui/material_ui.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'account.dart';
import 'directory.dart';
import 'downloads.dart';
import 'feeds.dart';
import 'library.dart';
import 'menu.dart';
import 'player.dart';
import 'shared_links.dart' show openWebLink;
import 'podcasts.dart';
import 'theme.dart' as brand;
import 'youtube.dart';

/// Everything the screens use, made once in main.dart.
final class Services extends InheritedWidget {
  const Services({
    super.key,
    required this.youtube,
    required this.account,
    required this.feeds,
    required this.library,
    required this.podcasts,
    required this.player,
    required this.downloads,
    required this.directory,
    required super.child,
  });

  final YouTubeService youtube;
  final Account account;
  final Feeds feeds;
  final Library library;
  final Podcasts podcasts;
  final Player player;
  final Downloads downloads;
  final PodcastDirectory directory;

  static Services of(BuildContext context) => context.getInheritedWidgetOfExactType<Services>()!;

  @override
  bool updateShouldNotify(Services old) => false;
}

/// How the shell moves between screens, for anything inside the app,
/// dialogs and sheets included: they sit above the shell, so the shell
/// registers itself here (shell.dart) and this sits above the app.
final class Navigation {
  Navigation();
  NavigationTarget? target;

  void openShow(int podcastId) => target?.openShow(podcastId);
  void openNowPlaying() => target?.openNowPlaying();
  void openSearch({String? query, bool youtube = false, String? into}) =>
    target?.openSearch(query: query, youtube: youtube, into: into);
  void openFeed(String feedId) => target?.openFeed(feedId);
  void openSettings() => target?.openSettings();
  void openPlans({String? title}) => target?.openPlans(title: title);
  void openNewPodcast() => target?.openNewPodcast();

  static Navigation of(BuildContext context) => context.getInheritedWidgetOfExactType<NavigationScope>()!.navigation;
}

abstract interface class NavigationTarget {
  void openShow(int podcastId);
  void openNowPlaying();
  /// [into] is a Listenjar Cloud podcast of the listener's own that the
  /// videos found go into, with one click each.
  void openSearch({String? query, bool youtube = false, String? into});

  /// A Listenjar feed of the listener's, in the Library.
  void openFeed(String feedId);
  void openSettings();

  /// The plans sheet (plans.dart), titled [title] or its default.
  void openPlans({String? title});

  /// Making a podcast of the listener's own (cloud.dart's createPodcast).
  void openNewPodcast();
}

final class NavigationScope extends InheritedWidget {
  const NavigationScope({super.key, required this.navigation, required super.child});
  final Navigation navigation;
  @override
  bool updateShouldNotify(NavigationScope old) => false;
}

// Reading times and dates.

/// `1 h 12 min`, `42 min`, `50 s`.
String spokenDuration(Duration d) {
  if (d.inMinutes < 1) return '${d.inSeconds} s';
  final h = d.inHours;
  final m = d.inMinutes % 60;
  return h == 0 ? '$m min' : (m == 0 ? '$h h' : '$h h $m min');
}

/// `1:02:03`, `4:05`: a clock for scrubbers.
String clock(Duration d) {
  final s = d.inSeconds.abs();
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final sec = (s % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$sec' : '$m:$sec';
}

const _monthNames = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const _dayNames = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

/// Today, Yesterday, Tuesday, Nov 3, Nov 3, 2024.
String spokenDate(DateTime when) {
  final at = when.toLocal();
  final now = DateTime.now();
  final days = DateTime(now.year, now.month, now.day).difference(DateTime(at.year, at.month, at.day)).inDays;
  if (days == 0) return 'Today';
  if (days == 1) return 'Yesterday';
  if (days > 1 && days < 7) return _dayNames[at.weekday - 1];
  final day = '${_monthNames[at.month - 1]} ${at.day}';
  return at.year == now.year ? day : '$day, ${at.year}';
}

/// What a row says under an episode's title: when, and how long or how much
/// is left.
String episodeMeta(PodcastEpisode e, {bool withShow = false}) => [
  if (withShow) e.from,
  if (e.publishedAt case final at?) spokenDate(at),
  if (e.started && e.remaining != null) '${spokenDuration(e.remaining!)} left'
  else if (e.duration case final d?) spokenDuration(d),
].join(' · ');

// Artwork.

/// A show's square cover, rounded by size (DESIGN.md "Shapes"): the cover
/// when there is one, else the show's initial on the authored violet.
final class Artwork extends StatelessWidget {
  const Artwork({super.key, required this.url, this.fallbackUrl, required this.title, required this.size, this.height, this.radius});
  final String? url;

  /// Shown when [url] fails to load, before the lettered square.
  final String? fallbackUrl;
  final String title;

  /// The width, and the height unless [height] says otherwise.
  final double size;
  final double? height;
  final double? radius;

  @override
  Widget build(BuildContext context) {
    final r = radius ?? (size * 0.16).clamp(8.0, 24.0);
    final fallback = Container(
      alignment: Alignment.center,
      color: const Color(0xFF6A55F0),
      child: Text(
        title.trim().isEmpty ? '?' : title.trim().characters.first.toUpperCase(),
        style: TextStyle(color: brand.white, fontWeight: FontWeight.w700, fontSize: size * 0.42, height: 1),
      ),
    );
    final cacheWidth = (size * MediaQuery.devicePixelRatioOf(context)).round();
    Widget loading(BuildContext _, Widget child, int? frame, bool sync) => sync || frame != null
      ? child
      : const ColoredBox(color: brand.paperDeep);
    Widget picture(String? url, Widget otherwise) => switch (url) {
      // A podcast of the listener's own on this device keeps its artwork
      // beside the library.
      final url? when url.startsWith('file:') => Image.file(
        File.fromUri(Uri.parse(url)),
        fit: BoxFit.cover,
        cacheWidth: cacheWidth,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => otherwise,
        frameBuilder: loading,
      ),
      final url? when url.isNotEmpty => Image.network(
        url,
        fit: BoxFit.cover,
        cacheWidth: cacheWidth,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => otherwise,
        frameBuilder: loading,
      ),
      _ => otherwise,
    };
    return Semantics(
      excludeSemantics: true,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(r),
        child: SizedBox(
          width: size,
          height: height ?? size,
          child: picture(url, picture(fallbackUrl, fallback)),
        ),
      ),
    );
  }
}

/// YouTube as a source, drawn in the app's own colour rather than
/// YouTube's red: a rounded screen with a play triangle cut out of it. [size]
/// is its width, as an [Icon]'s is; it takes the icon colour unless given one.
final class YouTubeMark extends StatelessWidget {
  const YouTubeMark({super.key, this.size = 24, this.color});
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(painter: _YouTubeMarkPainter(color ?? IconTheme.of(context).color ?? brand.fg)),
  );
}

final class _YouTubeMarkPainter extends CustomPainter {
  const _YouTubeMarkPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final screen = Rect.fromCenter(center: size.center(Offset.zero), width: w, height: w * 0.7);
    final c = screen.center;
    final play = Path()
      ..moveTo(c.dx - w * 0.12, c.dy - w * 0.15)
      ..lineTo(c.dx + w * 0.16, c.dy)
      ..lineTo(c.dx - w * 0.12, c.dy + w * 0.15)
      ..close();
    final mark = Path()
      ..fillType = PathFillType.evenOdd
      ..addRRect(RRect.fromRectAndRadius(screen, Radius.circular(w * 0.2)))
      ..addPath(play, Offset.zero);
    canvas.drawPath(mark, Paint()..color = color..isAntiAlias = true);
  }

  @override
  bool shouldRepaint(_YouTubeMarkPainter old) => old.color != color;
}

// Buttons.

/// Around a show's page: the order it lists the episodes in, oldest first
/// or not. An episode started there plays on into the show's next, in
/// that order (Player.following).
final class ShowOrder extends InheritedWidget {
  const ShowOrder({super.key, required this.oldestFirst, required super.child});
  final bool oldestFirst;

  /// Null outside a show's page. Read when a play button is pressed.
  static bool? of(BuildContext context) => context.getInheritedWidgetOfExactType<ShowOrder>()?.oldestFirst;

  @override
  bool updateShouldNotify(ShowOrder old) => false;
}

/// The round play button beside an episode: ink on paper (DESIGN.md), a
/// pause while it plays, a spinner while it loads.
final class PlayButton extends StatelessWidget {
  const PlayButton({super.key, required this.episode, this.size = 40, this.onInk = false});
  final PodcastEpisode episode;
  final double size;
  final bool onInk;

  @override
  Widget build(BuildContext context) {
    final player = Services.of(context).player;
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final current = player.current?.id == episode.id;
        final playing = current && player.playing;
        final loading = current && player.loading;
        final light = onInk || brand.Surface.of(context).onInk;
        final background = light ? brand.white : brand.ink;
        final foreground = light ? brand.ink : brand.white;
        return Tooltip(
          message: playing ? 'Pause' : (episode.started ? 'Resume' : 'Play'),
          waitDuration: const Duration(milliseconds: 500),
          child: SizedBox.square(
            dimension: size,
            child: IconButton(
              padding: EdgeInsets.zero,
              style: IconButton.styleFrom(
                backgroundColor: background,
                foregroundColor: foreground,
                hoverColor: light ? brand.paperDeep : const Color(0xFF23252D),
                shape: const CircleBorder(),
              ),
              onPressed: () {
                if (playing) return unawaited(player.pause());
                doneTyping();
                unawaited(player.playEpisode(episode, oldestFirst: ShowOrder.of(context)));
              },
              icon: loading
                ? SizedBox.square(
                    dimension: size * 0.4,
                    child: CircularProgressIndicator(strokeWidth: 2, color: foreground),
                  )
                : Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded, size: size * 0.55),
            ),
          ),
        );
      },
    );
  }
}

/// Whether focus is in a text field.
bool get _typing {
  final focus = FocusManager.instance.primaryFocus?.context;
  return focus != null && (focus.widget is EditableText || focus.findAncestorWidgetOfExactType<EditableText>() != null);
}

/// Takes focus out of a text field, which hides the software keyboard, as
/// pressing play does: the listener is done typing and wants to listen.
/// Focus anywhere else stays, so keyboard navigation keeps its place.
void doneTyping() {
  if (_typing) FocusManager.instance.primaryFocus?.unfocus();
}

/// Space plays and pauses and [back] and [forward] skip, wherever focus
/// is, except in a text field: there those keys type and move the cursor.
Widget playerKeys({required Player player, required SingleActivator back, required SingleActivator forward, required Widget child}) => Focus(
  canRequestFocus: false,
  skipTraversal: true,
  onKeyEvent: (node, event) {
    if (_typing) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    if (const SingleActivator(LogicalKeyboardKey.space, includeRepeats: false).accepts(event, keys)) {
      unawaited(player.toggle());
    } else if (back.accepts(event, keys)) {
      unawaited(player.rewind());
    } else if (forward.accepts(event, keys)) {
      unawaited(player.fastForward());
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  },
  child: child,
);

/// An episode's download, at a glance: offer, progress, done, or why not.
final class DownloadButton extends StatelessWidget {
  const DownloadButton({super.key, required this.episode});
  final PodcastEpisode episode;

  @override
  Widget build(BuildContext context) {
    final downloads = Services.of(context).downloads;
    final p = brand.Surface.of(context);
    final (tip, icon, action) = switch (episode.downloadState) {
      DownloadState.none => (
        'Download',
        Icon(Icons.arrow_circle_down_rounded, size: 22, color: p.fgSoft),
        () => downloads.download(episode),
      ),
      DownloadState.queued => (
        'Waiting to download · Cancel',
        SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2, color: p.fgFaint)),
        () => downloads.delete(episode),
      ),
      DownloadState.downloading => (
        'Downloading ${(episode.downloadProgress * 100).round()}% · Cancel',
        SizedBox.square(
          dimension: 18,
          child: CircularProgressIndicator(
            strokeWidth: 2.2,
            value: episode.downloadProgress > 0 ? episode.downloadProgress : null,
            color: p.link,
            backgroundColor: p.track,
          ),
        ),
        () => downloads.delete(episode),
      ),
      DownloadState.done => (
        'Downloaded · Delete download',
        Icon(Icons.check_circle_rounded, size: 22, color: p.ok),
        () => downloads.delete(episode),
      ),
      DownloadState.failed => (
        '${episode.downloadError ?? 'The download failed'} · Try again',
        Icon(Icons.error_outline_rounded, size: 22, color: p.danger),
        () => downloads.download(episode),
      ),
    };
    return Tooltip(
      message: tip,
      waitDuration: const Duration(milliseconds: 400),
      child: IconButton(
        onPressed: () => unawaited(action()),
        style: IconButton.styleFrom(hoverColor: p.held),
        icon: icon,
      ),
    );
  }
}

/// What else can be done with an episode.
List<Widget> episodeActions(BuildContext context, PodcastEpisode e, {bool showLink = false}) {
  final s = Services.of(context);
  final queued = s.library.queued(e.id);
  final current = s.player.current?.id == e.id;
  return [
    if (!current) ...[
      MenuEntry('Play next', icon: Icons.playlist_play_rounded, onPressed: () => s.library.playNext(e.id)),
      if (queued)
        MenuEntry('Remove from Up Next', icon: Icons.playlist_remove_rounded, onPressed: () => s.library.dequeue(e.id))
      else
        MenuEntry('Play last', icon: Icons.playlist_add_rounded, onPressed: () => s.library.playLast([e.id])),
    ],
    if (e.played)
      MenuEntry('Mark as unplayed', icon: Icons.replay_rounded, onPressed: () => s.library.setPlayed([e.id], false))
    else
      MenuEntry('Mark as played', icon: Icons.done_all_rounded, onPressed: () {
        if (current) {
          unawaited(s.player.markPlayedAndNext());
        } else {
          s.library.setPlayed([e.id], true);
        }
      }),
    if (e.downloadState == DownloadState.none || e.downloadState == DownloadState.failed)
      MenuEntry('Download', icon: Icons.download_rounded, onPressed: () => unawaited(s.downloads.download(e)))
    else
      MenuEntry('Delete download', icon: Icons.delete_outline_rounded, danger: true, onPressed: () => unawaited(s.downloads.delete(e))),
    if (showLink) MenuEntry('Go to show', icon: Icons.podcasts_rounded, onPressed: () => Navigation.of(context).openShow(e.podcastId)),
    if (episodeUrl(e) case final url?) MenuEntry('Share…', icon: Icons.adaptive.share, onPressed: () => unawaited(shareLink(context, url, title: e.title))),
    if (e.link case final link? when Uri.tryParse(link)?.hasScheme ?? false)
      MenuEntry(
        e.videoId == null ? 'Open episode page' : 'Open on YouTube',
        icon: e.videoId == null ? Icons.open_in_new_rounded : Icons.smart_display_outlined,
        onPressed: () => unawaited(launchUrl(Uri.parse(link), mode: LaunchMode.externalApplication)),
      ),
  ];
}

/// The page that stands for [e] when it's shared: a YouTube video's watch
/// page, or the episode's own page; null when it has neither.
String? episodeUrl(PodcastEpisode e) => switch (e) {
  PodcastEpisode(youtubeId: final id?) => 'https://www.youtube.com/watch?v=$id',
  PodcastEpisode(link: final link?) when Uri.tryParse(link)?.hasScheme ?? false => link,
  _ => null,
};

/// Hands [url] to the system share sheet: iOS and Android's sheet, the
/// macOS sharing picker, Windows' Share. iPad and Mac anchor it on
/// [context]'s widget. Linux has no share sheet, so the link is copied.
Future<void> shareLink(BuildContext context, String url, {String? title}) async {
  if (Platform.isLinux) {
    await Clipboard.setData(ClipboardData(text: url));
    if (context.mounted) tell(context, 'Link copied.');
    return;
  }
  final box = context.findRenderObject() as RenderBox?;
  await SharePlus.instance.share(ShareParams(
    uri: Uri.parse(url),
    title: title,
    subject: title,
    sharePositionOrigin: box == null || !box.hasSize ? null : box.localToGlobal(Offset.zero) & box.size,
  ));
}

final class EpisodeMenu extends StatelessWidget {
  const EpisodeMenu({super.key, required this.episode, this.showLink = false, this.tone});
  final PodcastEpisode episode;
  final bool showLink;

  /// The surface's own when not given.
  final MenuTone? tone;

  @override
  Widget build(BuildContext context) {
    final tone = this.tone ?? brand.Surface.of(context).menu;
    return Dropdown(
      tone: tone,
      align: MenuAlign.end,
      items: episodeActions(context, episode, showLink: showLink),
      builder: (context, menu) => MoreButton(menu: menu, tone: tone),
    );
  }
}

// The episode row.

/// An episode in a list: when and how long, its title, how far the
/// listener got, and play, download and more. Clicking it opens its notes.
final class EpisodeRow extends StatefulWidget {
  const EpisodeRow({super.key, required this.episode, this.withShow = false, this.thumbnail = false, this.trailing});
  final PodcastEpisode episode;

  /// Lists across shows put the show's cover and name on each row.
  final bool withShow;

  /// A show's own page puts each episode's picture on its row: a video's
  /// 16:9 thumbnail, as YouTube lists them, else the episode's square art,
  /// or the show's when it has none.
  final bool thumbnail;
  final Widget? trailing;

  @override
  State<EpisodeRow> createState() => _EpisodeRowState();
}

final class _EpisodeRowState extends State<EpisodeRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final e = widget.episode;
    final text = Theme.of(context).textTheme;
    final p = brand.Surface.of(context);
    final narrow = MediaQuery.sizeOf(context).width < 520;
    final progress = switch (e.duration) {
      final d? when e.started && d > Duration.zero => (e.position.inMilliseconds / d.inMilliseconds).clamp(0.0, 1.0),
      _ => null,
    };
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: brand.quick,
        curve: brand.easeOutExpo,
        decoration: BoxDecoration(
          color: _hover ? p.hover : p.hover.withValues(alpha: 0),
          borderRadius: BorderRadius.circular(14),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => showEpisode(context, e),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 4, 12),
            child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
              if (widget.withShow) ...[
                Artwork(url: e.artwork, title: e.podcastTitle, size: narrow ? 48 : 56),
                const SizedBox(width: 14),
              ] else if (widget.thumbnail && e.widescreen) ...[
                Artwork(url: e.artwork, title: e.title, size: narrow ? 80 : 96, height: (narrow ? 80 : 96) * 9 / 16, radius: 8),
                const SizedBox(width: 14),
              ] else if (widget.thumbnail) ...[
                Artwork(url: e.artwork, title: e.title, size: narrow ? 48 : 56, radius: 8),
                const SizedBox(width: 14),
              ],
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(
                    episodeMeta(e, withShow: widget.withShow),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodySmall!.copyWith(
                      color: p.fgSoft,
                      fontSize: 13,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    e.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: text.titleMedium!.copyWith(
                      color: e.played ? p.fgSoft : p.fg,
                      fontSize: 15.5,
                      height: 1.3,
                    ),
                  ),
                  if (progress != null) ...[
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: SizedBox(
                        width: 120,
                        height: 3,
                        child: LinearProgressIndicator(value: progress, color: p.link, backgroundColor: p.track),
                      ),
                    ),
                  ],
                ]),
              ),
              const SizedBox(width: 8),
              if (!narrow) DownloadButton(episode: e),
              ?widget.trailing,
              EpisodeMenu(episode: e, showLink: widget.withShow),
              const SizedBox(width: 4),
              PlayButton(episode: e),
              const SizedBox(width: 8),
            ]),
          ),
        ),
      ),
    );
  }
}

/// A panel of rows, the dashboard's list surface: white on paper with the
/// soft shadow, a faint tile on ink with none (DESIGN.md "The
/// Glow-Not-Border Rule").
Widget rowsPanel(List<Widget> rows) => Builder(builder: (context) {
  final p = brand.Surface.of(context);
  return DecoratedBox(
    decoration: BoxDecoration(
      color: p.panel,
      borderRadius: BorderRadius.circular(brand.radiusTile + 4),
      boxShadow: p.onInk ? null : const [brand.shadowSoft],
    ),
    child: Padding(
      padding: const EdgeInsets.all(6),
      child: Column(children: [
        for (final (i, row) in rows.indexed) ...[
          if (i > 0) Divider(height: 1, thickness: 1, indent: 12, endIndent: 12, color: p.line),
          row,
        ],
      ]),
    ),
  );
});

/// A section's heading, in the display voice, with an optional action.
Widget sectionHeading(BuildContext context, String title, {Widget? action, double top = 32}) => Padding(
  padding: EdgeInsets.only(top: top, bottom: 12),
  child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
    Expanded(child: Text(title, style: Theme.of(context).textTheme.titleLarge)),
    ?action,
  ]),
);

/// A page's title, in the dashboard's h1 voice.
Widget pageTitle(BuildContext context, String title, {List<Widget> actions = const []}) => Padding(
  padding: const EdgeInsets.only(bottom: 8),
  child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
    Expanded(
      child: Text(
        title,
        style: Theme.of(context).textTheme.headlineMedium!.copyWith(fontSize: MediaQuery.sizeOf(context).width < 520 ? 30 : 36),
      ),
    ),
    ...actions,
  ]),
);

/// What a screen says while it has nothing, and the way forward.
final class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.title, required this.body, this.actions = const []});
  final String title;
  final String body;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return brand.panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: text.titleLarge),
        const SizedBox(height: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Text(body, style: text.bodyMedium!.copyWith(color: brand.fgSoft)),
        ),
        if (actions.isNotEmpty) ...[
          const SizedBox(height: 22),
          Wrap(spacing: 10, runSpacing: 10, children: actions),
        ],
      ]),
    );
  }
}

/// A quiet notice of something that went wrong, with what it said; in the
/// colors of the surface it lands on, paper or ink.
Widget problem(BuildContext context, String message, [Object? error]) => Tooltip(
  message: error == null ? '' : '$error',
  child: Builder(builder: (context) {
    final p = brand.Surface.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(color: p.danger.withValues(alpha: p.onInk ? 0.12 : 0.08), borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        Icon(Icons.error_outline_rounded, size: 18, color: p.danger),
        const SizedBox(width: 10),
        Expanded(child: Text(message, style: Theme.of(context).textTheme.bodySmall!.copyWith(color: p.fg))),
      ]),
    );
  }),
);

/// The network is gone: said once, calmly, with what still works.
final class OfflineLine extends StatelessWidget {
  const OfflineLine({super.key, this.message = 'Offline · showing what’s saved here'});
  final String message;

  @override
  Widget build(BuildContext context) {
    final p = brand.Surface.of(context);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.cloud_off_rounded, size: 15, color: p.fgFaint),
      const SizedBox(width: 8),
      Flexible(child: Text(message, style: Theme.of(context).textTheme.bodySmall!.copyWith(color: p.fgSoft))),
    ]);
  }
}

/// Says what happened, at the bottom of the window.
void tell(BuildContext context, String message) {
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

// The episode sheet.

/// Opens [episode]'s page over the window: its show, when, how long, the
/// actions, and the show notes, whose timestamps seek.
Future<void> showEpisode(BuildContext context, PodcastEpisode episode) {
  final wide = MediaQuery.sizeOf(context).width >= 760;
  final sheet = EpisodeSheet(episodeId: episode.id);
  if (wide) {
    return showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: brand.paper,
        insetPadding: const EdgeInsets.all(40),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(brand.radiusSheet)),
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 680, maxHeight: 760), child: sheet),
      ),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: brand.paper,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(brand.radiusSheet))),
    builder: (context) => FractionallySizedBox(heightFactor: 0.9, child: sheet),
  );
}

final class EpisodeSheet extends StatelessWidget {
  const EpisodeSheet({super.key, required this.episodeId});
  final int episodeId;

  @override
  Widget build(BuildContext context) {
    final s = Services.of(context);
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: s.library,
      builder: (context, _) {
        final e = s.library.episode(episodeId);
        if (e == null) return const SizedBox(height: 200);
        return CustomScrollView(slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(28, 24, 28, 8),
            sliver: SliverList.list(children: [
              Row(children: [
                Artwork(url: e.artwork, title: e.podcastTitle, size: 64),
                const SizedBox(width: 16),
                Expanded(
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () {
                      final navigation = Navigation.of(context);
                      Navigator.of(context).pop();
                      navigation.openShow(e.podcastId);
                    },
                    child: Text(
                      e.from,
                      style: text.titleMedium!.copyWith(color: brand.accent),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ]),
              const SizedBox(height: 20),
              Text(e.title, style: text.titleLarge!.copyWith(fontSize: 24, height: 1.2)),
              const SizedBox(height: 8),
              Text(
                episodeMeta(e),
                style: text.bodySmall!.copyWith(color: brand.fgSoft, fontFeatures: const [FontFeature.tabularFigures()]),
              ),
              const SizedBox(height: 18),
              Row(children: [
                PlayButton(episode: e, size: 48),
                const SizedBox(width: 8),
                DownloadButton(episode: e),
                EpisodeMenu(episode: e),
              ]),
              const SizedBox(height: 18),
              const Divider(height: 1, color: brand.line),
              const SizedBox(height: 18),
            ]),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(28, 0, 28, 32),
            sliver: SliverToBoxAdapter(child: ShowNotes(html: s.library.description(e.id), episode: e)),
          ),
        ]);
      },
    );
  }
}

// Show notes.

final _timestamp = RegExp(r'\b(?:(\d{1,2}):)?(\d{1,2}):(\d{2})\b');

/// `https://…`, `http://…` or `www.…`, up to the next space.
final _webAddress = RegExp(r'\b(?:https?://|www\.)[^\s<>"]+', caseSensitive: false);

/// An episode's notes as the feed wrote them: paragraphs, lists, bold and
/// links kept; scripts, styles and images dropped. Web addresses written
/// as plain text are links too; a long press or right-click on a link
/// offers Copy link. A timestamp plays the episode from there.
final class ShowNotes extends StatefulWidget {
  const ShowNotes({super.key, required this.html, this.episode, this.onInk = false});
  final String html;
  final PodcastEpisode? episode;
  final bool onInk;

  @override
  State<ShowNotes> createState() => _ShowNotesState();
}

final class _ShowNotesState extends State<ShowNotes> {
  final _recognizers = <TapGestureRecognizer>[];

  /// Each link's address, by its span.
  var _links = Expando<Uri>();
  final _text = GlobalKey();

  /// The link last pressed, for the selection menu's Copy link.
  Uri? _pressed;

  /// Notes which link, if any, a press landed on: a long press or a
  /// right-click on it then offers to copy it.
  void _pointerDown(PointerDownEvent event) {
    _pressed = null;
    RenderParagraph? paragraph;
    void find(RenderObject node) {
      if (paragraph != null) return;
      if (node is RenderParagraph) {
        paragraph = node;
      } else {
        node.visitChildren(find);
      }
    }

    if (_text.currentContext?.findRenderObject() case final root?) find(root);
    if (paragraph case final paragraph?) {
      final at = paragraph.globalToLocal(event.position);
      if (!(Offset.zero & paragraph.size).contains(at)) return;
      final span = paragraph.text.getSpanForPosition(paragraph.getPositionForOffset(at));
      if (span != null) _pressed = _links[span];
    }
  }

  Widget _menu(BuildContext context, SelectableRegionState region) {
    final link = _pressed;
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: region.contextMenuAnchors,
      buttonItems: [
        if (link != null)
          ContextMenuButtonItem(
            label: 'Copy link',
            onPressed: () {
              region.hideToolbar();
              region.clearSelection();
              unawaited(copyText(this.context, '$link', 'Link copied.'));
            },
          ),
        ...region.contextMenuButtonItems,
      ],
    );
  }

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
    _links = Expando<Uri>();
    final text = Theme.of(context).textTheme;
    final base = text.bodyMedium!.copyWith(color: widget.onInk ? brand.snow : brand.fg, height: 1.6);
    final source = widget.html.trim();
    if (source.isEmpty) {
      return Text('No show notes.', style: base.copyWith(color: widget.onInk ? brand.snowSoft : brand.fgSoft));
    }
    final looksHtml = RegExp(r'<[a-zA-Z][^>]*>').hasMatch(source);
    final fragment = looksHtml ? html.parseFragment(source) : null;
    final spans = <InlineSpan>[];
    if (fragment == null) {
      _inline(source, base, spans);
    } else {
      _walk(fragment.nodes, base, spans);
    }
    // Trim the blank lines blocks leave at the ends.
    while (spans.isNotEmpty && spans.last is TextSpan && ((spans.last as TextSpan).text?.trim().isEmpty ?? false)) {
      spans.removeLast();
    }
    return SelectionArea(
      contextMenuBuilder: _menu,
      child: Listener(
        onPointerDown: _pointerDown,
        child: Text.rich(key: _text, TextSpan(children: spans, style: base)),
      ),
    );
  }

  static const _blocks = {'p', 'div', 'br', 'li', 'ul', 'ol', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'blockquote', 'section', 'tr'};

  void _walk(List<dom.Node> nodes, TextStyle style, List<InlineSpan> out) {
    for (final node in nodes) {
      switch (node) {
        case dom.Text():
          _inline(node.text.replaceAll(RegExp(r'\s+'), ' '), style, out);
        case dom.Element(localName: 'script' || 'style' || 'img' || 'iframe'):
          break;
        case dom.Element(localName: 'br'):
          out.add(const TextSpan(text: '\n'));
        case dom.Element(localName: final name?):
          final block = _blocks.contains(name);
          if (block && out.isNotEmpty && !_endsWithBreak(out)) out.add(const TextSpan(text: '\n'));
          if (name == 'li') out.add(const TextSpan(text: '•  '));
          var child = style;
          if (name == 'b' || name == 'strong' || name.startsWith('h')) child = child.copyWith(fontWeight: FontWeight.w600);
          if (name == 'i' || name == 'em') child = child.copyWith(fontStyle: FontStyle.italic);
          final href = name == 'a' ? node.attributes['href'] : null;
          if (href != null) {
            final url = Uri.tryParse(href.trim());
            if (url != null && url.hasScheme) {
              final label = node.text.replaceAll(RegExp(r'\s+'), ' ');
              out.add(_link(label.trim().isEmpty ? href : label, url, child));
              continue;
            }
          }
          _walk(node.nodes, child, out);
          if (block && name != 'li') out.add(const TextSpan(text: '\n'));
          if (name == 'li') out.add(const TextSpan(text: '\n'));
        default:
          break;
      }
    }
  }

  bool _endsWithBreak(List<InlineSpan> out) => out.last is TextSpan && ((out.last as TextSpan).text?.endsWith('\n') ?? false);

  /// A link: Apple Podcasts and YouTube ones open here, the rest in the
  /// browser.
  TextSpan _link(String label, Uri url, TextStyle style) {
    final color = widget.onInk ? brand.accentLight : brand.accent;
    // A long press copies, never opens: when the selection's own long press
    // takes the gesture, its menu offers Copy link (_menu); when it doesn't,
    // a held press lets go here.
    DateTime? down;
    final r = TapGestureRecognizer()
      ..onTapDown = ((_) => down = DateTime.now())
      ..onTapUp = ((_) {
        if (down != null && DateTime.now().difference(down!) >= kLongPressTimeout) {
          unawaited(copyText(context, '$url', 'Link copied.'));
        } else {
          unawaited(openWebLink(context, url));
        }
      });
    _recognizers.add(r);
    final span = TextSpan(
      text: label,
      style: style.copyWith(color: color, decoration: TextDecoration.underline, decorationColor: color.withValues(alpha: 0.4)),
      recognizer: r,
      mouseCursor: SystemMouseCursors.click,
    );
    _links[span] = url;
    return span;
  }

  /// Plain text, with web addresses made into links and timestamps into
  /// seek links.
  void _inline(String value, TextStyle style, List<InlineSpan> out) {
    var at = 0;
    for (final m in _webAddress.allMatches(value)) {
      var address = m[0]!;
      // Sentence punctuation after an address isn't part of it; a closing
      // bracket is only when the address opened one.
      while (address.isNotEmpty) {
        final last = address[address.length - 1];
        final unopened = last == ')' && '('.allMatches(address).length < ')'.allMatches(address).length;
        if (!(unopened || '.,;:!?\'"’”»>'.contains(last))) break;
        address = address.substring(0, address.length - 1);
      }
      final url = Uri.tryParse(address.startsWith(RegExp('https?://', caseSensitive: false)) ? address : 'https://$address');
      if (url == null || url.host.isEmpty) continue;
      if (m.start > at) _timestamps(value.substring(at, m.start), style, out);
      out.add(_link(address, url, style));
      at = m.start + address.length;
    }
    if (at < value.length) _timestamps(value.substring(at), style, out);
  }

  /// Plain text, with timestamps made into seek links.
  void _timestamps(String value, TextStyle style, List<InlineSpan> out) {
    final episode = widget.episode;
    if (episode == null) {
      out.add(TextSpan(text: value, style: style));
      return;
    }
    var at = 0;
    for (final m in _timestamp.allMatches(value)) {
      if (m.start > at) out.add(TextSpan(text: value.substring(at, m.start), style: style));
      final position = Duration(
        hours: int.tryParse(m.group(1) ?? '') ?? 0,
        minutes: int.parse(m.group(2)!),
        seconds: int.parse(m.group(3)!),
      );
      final r = TapGestureRecognizer()..onTap = () => unawaited(_seek(episode, position));
      _recognizers.add(r);
      out.add(TextSpan(
        text: m.group(0),
        style: style.copyWith(
          color: widget.onInk ? brand.accentLight : brand.accent,
          fontWeight: FontWeight.w600,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
        recognizer: r,
        mouseCursor: SystemMouseCursors.click,
      ));
      at = m.end;
    }
    if (at < value.length) out.add(TextSpan(text: value.substring(at), style: style));
  }

  Future<void> _seek(PodcastEpisode episode, Duration position) async {
    final player = Services.of(context).player;
    if (player.current?.id != episode.id) await player.playEpisode(episode);
    await player.seek(position);
    if (!player.playing) await player.play();
  }
}

/// Copies [value] and says so.
Future<void> copyText(BuildContext context, String value, String said) async {
  await Clipboard.setData(ClipboardData(text: value));
  if (context.mounted) tell(context, said);
}
