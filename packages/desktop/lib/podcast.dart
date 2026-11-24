// A podcast of the listener's own, opened from the feed list: its artwork,
// which they change by picking a picture (artwork.dart, uploaded through
// uploads.dart), and every episode it has, uploaded or on its way. Videos go
// in from the window's link field, which adds to this podcast while it is
// open (main.dart). The player follows the podcast's RSS feed like any other
// show (podcasts.dart), so an uploaded episode plays, downloads and keeps its
// place from here just as it does there: the feed's guid is the episode's id.
import 'dart:async';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';

import 'artwork.dart';
import 'backend/api.dart';
import 'feeds.dart';
import 'library.dart' show PodcastEpisode, videoThumbnail;
import 'plans.dart' show formatBytes;
import 'sync.dart';
import 'theme.dart' as brand;
import 'ui.dart' show Artwork, DownloadButton, EpisodeMenu, PlayButton, Services, showEpisode, spokenDate, spokenDuration;

final class PodcastPage extends StatefulWidget {
  const PodcastPage({super.key, required this.feed, required this.feeds, required this.listenIn, required this.onRemove});
  final Feed feed;
  final Feeds feeds;

  /// The window's "Listen in…" button for this feed.
  final Widget listenIn;
  final VoidCallback onRemove;

  @override
  State<PodcastPage> createState() => _PodcastPageState();
}

final class _PodcastPageState extends State<PodcastPage> {
  Feed get _feed => widget.feed;

  List<Episode>? _episodes;
  Object? _loadError;
  final _removing = <String>{};
  Object? _episodeError;

  /// The playable row under the pointer.
  String? _hovered;

  /// The picture being uploaded as artwork, shown at once, and how far
  /// along it is; then what went wrong, if it did.
  Uint8List? _picked;
  double? _sent;
  Object? _artworkError;

  /// What the list was loaded at: when the sync moves on, it loads again.
  Object? _loadedAt;
  Future<void>? _loading;

  @override
  void initState() {
    super.initState();
    widget.feeds.addListener(_follow);
    _follow();
  }

  @override
  void dispose() {
    widget.feeds.removeListener(_follow);
    super.dispose();
  }

  /// The episodes change when an upload lands, a video is added or one is
  /// removed; progress alone repaints without asking the API again.
  Object _signature() {
    final sync = widget.feeds.statusOf(_feed);
    return (_feed.episodeCount, sync?.phase, sync?.added, sync?.queued, sync?.current);
  }

  void _follow() {
    if (!mounted) return;
    final signature = _signature();
    if (signature != _loadedAt) {
      _loadedAt = signature;
      unawaited(_load());
    }
    setState(() {});
  }

  Future<void> _load() async {
    if (_loading != null) {
      await _loading;
      return _load();
    }
    final loading = () async {
      try {
        final episodes = await widget.feeds.episodes(_feed);
        if (!mounted) return;
        setState(() {
          _episodes = episodes;
          _loadError = null;
        });
        // An upload the player's copy of the feed hasn't seen yet plays
        // once that copy catches up.
        final known = _playable();
        if (episodes.any((e) => e.uploadedAt != null && !known.containsKey(e.id))) {
          unawaited(Services.of(context).podcasts.cloudPublished(_feed.id));
        }
      } catch (e) {
        if (mounted) setState(() => _loadError = e);
      }
    }();
    _loading = loading;
    await loading;
    _loading = null;
  }

  Future<void> _pickArtwork() async {
    if (_sent != null) return;
    final file = await openFile(acceptedTypeGroups: const [
      XTypeGroup(label: 'Pictures', extensions: artworkExtensions, uniformTypeIdentifiers: ['public.image']),
    ]);
    if (file == null || !mounted) return;
    final picture = await file.readAsBytes();
    setState(() {
      _picked = picture;
      _sent = 0;
      _artworkError = null;
    });
    try {
      await widget.feeds.setArtwork(_feed, picture, progress: (sent) {
        if (mounted) setState(() => _sent = sent);
      });
      if (mounted) setState(() => _picked = null);
    } catch (e) {
      if (mounted) {
        setState(() {
          _picked = null;
          _artworkError = e;
        });
      }
    } finally {
      if (mounted) setState(() => _sent = null);
    }
  }

  Future<void> _removeEpisode(Episode episode) async {
    setState(() {
      _removing.add(episode.id);
      _episodeError = null;
    });
    try {
      await widget.feeds.removeEpisode(_feed, episode);
      if (mounted) setState(() => _episodes = [...?_episodes?.where((e) => e.id != episode.id)]);
    } catch (e) {
      if (mounted) setState(() => _episodeError = e);
    } finally {
      if (mounted) setState(() => _removing.remove(episode.id));
    }
  }

  /// The player's copy of each uploaded episode, by its feed guid.
  Map<String, PodcastEpisode> _playable() {
    final library = Services.of(context).library;
    final show = library.podcasts.where((p) => p.cloudFeedId == _feed.id).firstOrNull;
    return {if (show != null) for (final e in library.episodes(show.id)) e.guid: e};
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _header(text),
      const SizedBox(height: 36),
      ListenableBuilder(
        listenable: Services.of(context).library,
        builder: (context, _) => _episodeList(text, _playable()),
      ),
    ]);
  }

  Widget _header(TextTheme text) {
    final episodes = _episodes;
    final live = episodes?.where((e) => e.uploadedAt != null).length ?? _feed.episodeCount ?? 0;
    final waiting = (episodes?.length ?? live) - live;
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _ArtworkButton(
        url: _feed.imageUrl,
        picked: _picked,
        sent: _sent,
        onPressed: _pickArtwork,
      ),
      const SizedBox(width: 24),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const SizedBox(height: 6),
          Text(
            _feed.title,
            style: text.headlineMedium!.copyWith(fontSize: 30),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 8),
          Text(
            [
              'Podcast of your own',
              live == 1 ? '1 episode' : '$live episodes',
              if (waiting > 0) '$waiting on the way',
            ].join(' · '),
            style: text.bodySmall!.copyWith(color: brand.fgSoft),
          ),
          const SizedBox(height: 18),
          Wrap(spacing: 8, runSpacing: 8, children: [
            widget.listenIn,
            TextButton.icon(
              style: brand.button(brand.Tone.quiet, brand.ButtonSize.sm),
              onPressed: _sent == null ? _pickArtwork : null,
              icon: const Icon(Icons.image_outlined, size: 17),
              label: Text(_feed.imageUrl == null ? 'Add artwork…' : 'Change artwork…'),
            ),
            TextButton(
              style: brand.button(brand.Tone.quiet, brand.ButtonSize.sm).copyWith(
                foregroundColor: const WidgetStatePropertyAll(brand.danger),
              ),
              onPressed: widget.onRemove,
              child: const Text('Remove podcast'),
            ),
          ]),
          if (_artworkError case final error?) ...[
            const SizedBox(height: 12),
            Text(
              switch (error) {
                UnreadablePicture() || PlanLimit() => '$error',
                _ => 'Couldn’t change the artwork: $error',
              },
              style: text.bodySmall!.copyWith(color: brand.danger),
            ),
          ] else ...[
            const SizedBox(height: 12),
            Text(
              'A square picture works best. Podcast apps show it at least 1400 pixels wide.',
              style: text.bodySmall!.copyWith(color: brand.fgSoft, fontSize: 13),
            ),
          ],
        ]),
      ),
    ]);
  }

  Widget _episodeList(TextTheme text, Map<String, PodcastEpisode> playable) {
    final episodes = _episodes;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 12),
        child: Text('Episodes', style: text.titleLarge),
      ),
      if (_episodeError case final error?)
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 12),
          child: Text('Couldn’t remove that episode: $error', style: text.bodySmall!.copyWith(color: brand.danger)),
        ),
      if (episodes == null && _loadError != null)
        _quiet(text, 'Couldn’t load the episodes', '$_loadError', danger: true)
      else if (episodes == null)
        _quiet(text, 'Loading episodes…', null)
      else if (episodes.isEmpty)
        _quiet(
          text,
          'No episodes yet',
          'Search YouTube or paste a video link in the field above, and it’s added here. '
            'It uploads from this computer.',
        )
      else
        DecoratedBox(
          decoration: BoxDecoration(
            color: brand.white,
            borderRadius: BorderRadius.circular(brand.radiusTile),
            boxShadow: const [brand.shadowSoft],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(brand.radiusTile),
            child: Column(children: [
              for (final (i, episode) in episodes.indexed) ...[
                if (i > 0) const Divider(height: 1, thickness: 1, indent: _rowInset * 2 + _thumbWidth, color: brand.line),
                _episodeRow(text, episode, episode.uploadedAt == null ? null : playable[episode.id]),
              ],
            ]),
          ),
        ),
    ]);
  }

  Widget _quiet(TextTheme text, String title, String? body, {bool danger = false}) => DecoratedBox(
    decoration: BoxDecoration(color: brand.paperDeep.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(brand.radiusTile)),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 22),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: text.titleMedium!.copyWith(fontSize: 15, color: danger ? brand.danger : brand.fg)),
        if (body != null) ...[
          const SizedBox(height: 4),
          Text(body, style: text.bodySmall!.copyWith(color: brand.fgSoft)),
        ],
      ]),
    ),
  );

  /// An episode: its video's thumbnail, title, and when, how long and how
  /// big, or how its upload is going. Once the player has it, it plays like
  /// an episode of any show: a click opens its notes, and it downloads,
  /// queues and keeps its place, shown along the thumbnail's foot.
  Widget _episodeRow(TextTheme text, Episode episode, PodcastEpisode? playable) {
    final removing = _removing.contains(episode.id);
    final (detail, busy) = _detail(episode, playable);
    final published = DateTime.tryParse(episode.publishedAt);
    final narrow = MediaQuery.sizeOf(context).width < 520;
    final hover = playable != null && _hovered == episode.id;
    final small = text.bodySmall!.copyWith(
      color: brand.fgSoft,
      fontSize: 13,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final progress = switch (playable) {
      PodcastEpisode(started: true, duration: final d?) when d > Duration.zero =>
        (playable.position.inMilliseconds / d.inMilliseconds).clamp(0.0, 1.0),
      _ => null,
    };
    Widget thumbnail = Artwork(
      url: videoThumbnail(episode.videoId),
      title: episode.title,
      size: _thumbWidth,
      height: _thumbWidth * 9 / 16,
      radius: 8,
    );
    if (progress != null) {
      thumbnail = ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(children: [
          thumbnail,
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 3,
              color: brand.accent,
              backgroundColor: const Color(0x66FFFFFF),
            ),
          ),
        ]),
      );
    }
    final remove = IconButton(
      tooltip: 'Remove episode',
      visualDensity: VisualDensity.compact,
      onPressed: removing ? null : () => _removeEpisode(episode),
      icon: const Icon(Icons.close_rounded, size: 17, color: brand.fgFaint),
    );
    final row = Padding(
      padding: EdgeInsets.fromLTRB(_rowInset, 12, playable == null ? 10 : 14, 12),
      child: Row(children: [
        thumbnail,
        const SizedBox(width: _rowInset),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              episode.title,
              style: text.bodySmall!.copyWith(
                color: playable?.played ?? false ? brand.fgSoft : brand.fg,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),
            Text(
              busy || published == null ? detail : [spokenDate(published), if (detail.isNotEmpty) detail].join(' · '),
              style: small.copyWith(color: busy ? brand.accent : brand.fgSoft),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ]),
        ),
        const SizedBox(width: 12),
        if (playable == null)
          remove
        else ...[
          if (!narrow) DownloadButton(episode: playable),
          remove,
          EpisodeMenu(episode: playable),
          const SizedBox(width: 4),
          PlayButton(episode: playable, size: 36),
        ],
      ]),
    );
    return AnimatedOpacity(
      key: ValueKey(episode.id),
      opacity: removing ? 0.4 : 1,
      duration: brand.quick,
      child: playable == null
        ? row
        : MouseRegion(
            onEnter: (_) => setState(() => _hovered = episode.id),
            onExit: (_) => setState(() => _hovered = _hovered == episode.id ? null : _hovered),
            child: AnimatedContainer(
              duration: brand.quick,
              curve: brand.easeOutExpo,
              color: hover ? brand.mist : brand.mist.withValues(alpha: 0),
              child: InkWell(onTap: () => showEpisode(context, playable), child: row),
            ),
          ),
    );
  }

  /// Under an episode's title: its length, or what's left of it, and size
  /// once it is live, what the sync is doing with it otherwise, and whether
  /// that is under way.
  (String, bool) _detail(Episode episode, PodcastEpisode? playable) {
    final length = switch ((playable, episode.durationSeconds)) {
      (PodcastEpisode(started: true, remaining: final left?), _) => '${spokenDuration(left)} left',
      (_, final s?) => _duration(s),
      _ => null,
    };
    if (episode.uploadedAt != null) {
      return ([?length, if (episode.byteLength case final b?) formatBytes(b)].join(' · '), false);
    }
    final sync = widget.feeds.statusOf(_feed);
    if (sync?.current == episode.title && sync?.stage != null) {
      final percent = sync!.fraction == null ? '' : ' ${(sync.fraction! * 100).floor()}%';
      return ('${sync.stage}$percent', true);
    }
    return (
      switch (sync?.error) {
        PlanLimit(storageFull: true) => 'Waiting for room in your plan',
        PlanLimit() => 'Waiting until you have a plan',
        _ => 'Waiting to upload',
      },
      false,
    );
  }
}

/// An episode row's left edge and the gap after its thumbnail.
const _rowInset = 16.0;

/// How wide an episode's video thumbnail is; 16:9, as YouTube shows it.
const _thumbWidth = 96.0;

/// "4:05", "1:02:03".
String _duration(int seconds) {
  final h = seconds ~/ 3600, m = seconds ~/ 60 % 60, s = seconds % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
}

/// The artwork, square like a podcast app shows it. Pressing it picks a
/// new picture; the pointer over it says so. While a new one uploads it
/// shows at once, under a veil that fills as the bytes go.
final class _ArtworkButton extends StatefulWidget {
  const _ArtworkButton({required this.url, required this.picked, required this.sent, required this.onPressed});
  final String? url;
  final Uint8List? picked;
  final double? sent;
  final VoidCallback onPressed;

  @override
  State<_ArtworkButton> createState() => _ArtworkButtonState();
}

final class _ArtworkButtonState extends State<_ArtworkButton> {
  static const _size = 168.0;
  bool _hover = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final uploading = widget.sent != null;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final empty = Container(
      color: brand.paperDeep,
      alignment: Alignment.center,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.add_photo_alternate_outlined, size: 30, color: brand.fgSoft),
        const SizedBox(height: 8),
        Text('Add artwork', style: text.labelLarge!.copyWith(color: brand.fgSoft, fontSize: 14)),
      ]),
    );
    final image = switch ((widget.picked, widget.url)) {
      (final bytes?, _) => Image.memory(bytes, fit: BoxFit.cover, cacheWidth: (_size * dpr).round(), gaplessPlayback: true),
      (_, final url?) => Image.network(
        url,
        fit: BoxFit.cover,
        cacheWidth: (_size * dpr).round(),
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => empty,
        frameBuilder: (_, child, frame, sync) => sync || frame != null ? child : Container(color: brand.paperDeep),
      ),
      _ => empty,
    };
    final veil = uploading || (_hover && (widget.url != null || widget.picked != null));
    return Semantics(
      button: true,
      label: widget.url == null ? 'Add artwork' : 'Change artwork',
      child: FocusableActionDetector(
        mouseCursor: uploading ? SystemMouseCursors.basic : SystemMouseCursors.click,
        onShowHoverHighlight: (hover) => setState(() => _hover = hover),
        onShowFocusHighlight: (focused) => setState(() => _focused = focused),
        actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => widget.onPressed())},
        child: GestureDetector(
          onTap: uploading ? null : widget.onPressed,
          child: AnimatedContainer(
            duration: brand.quick,
            curve: brand.easeOutExpo,
            width: _size,
            height: _size,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(brand.radiusTile),
              boxShadow: const [brand.shadowSoft],
              border: _focused ? Border.fromBorderSide(brand.focusSide) : null,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(brand.radiusTile),
              child: Stack(fit: StackFit.expand, children: [
                image,
                AnimatedOpacity(
                  opacity: veil ? 1 : 0,
                  duration: brand.quick,
                  curve: brand.easeOutExpo,
                  child: ColoredBox(
                    color: const Color(0x8C0A0B0F),
                    child: Center(
                      child: uploading
                        ? SizedBox.square(
                            dimension: 34,
                            child: CircularProgressIndicator(
                              value: widget.sent == 0 ? null : widget.sent,
                              strokeWidth: 2.5,
                              color: brand.white,
                              backgroundColor: const Color(0x33FFFFFF),
                            ),
                          )
                        : Column(mainAxisSize: MainAxisSize.min, children: [
                            const Icon(Icons.image_outlined, size: 24, color: brand.white),
                            const SizedBox(height: 6),
                            Text('Change', style: text.labelLarge!.copyWith(color: brand.white, fontSize: 14)),
                          ]),
                    ),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
