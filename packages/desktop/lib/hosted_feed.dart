// A show's ListenJar Cloud feed, on the show's own page (show_page.dart).
// On a plan with the Cloud, YouTube playlists, channels and podcasts of the
// listener's own also get an RSS feed ListenJar hosts: this device fetches
// each video and uploads its audio (sync.dart), and the player follows that
// feed like any podcast (podcasts.dart), so an uploaded episode is an
// episode of the show, its guid the feed's episode id. What's here is only
// what the feed adds: what its sync is doing, the videos still on their
// way up, and opening it in another podcast app.
import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'backend/api.dart';
import 'cloud.dart' show feedStatus;
import 'feeds.dart';
import 'library.dart' show PodcastEpisode, videoThumbnail;
import 'links.dart' show canonicalSourceUrl, parseYouTubeLink;
import 'menu.dart';
import 'podcasts.dart';
import 'shared_links.dart' show addVideoToOwnPodcast, ownPodcasts;
import 'sync.dart';
import 'theme.dart' as brand;
import 'ui.dart' show Artwork, Services, rowsPanel;

/// The episodes ListenJar has for the feed [feedId], uploaded or on their
/// way, loaded again whenever its sync moves on; progress alone doesn't
/// ask the API again.
final class FeedEpisodes extends ChangeNotifier {
  FeedEpisodes({required this.feedId, required this._feeds, required this._podcasts}) {
    _feeds.addListener(_follow);
    _follow();
  }

  final String feedId;
  final Feeds _feeds;
  final Podcasts _podcasts;

  List<Episode>? episodes;
  Object? loadError;

  /// What went wrong removing an episode, until the next try.
  Object? removeError;
  final removing = <String>{};

  Object? _loadedAt;
  Future<void>? _loading;
  bool _disposed = false;

  Feed? get feed => _feeds.feeds.where((f) => f.id == feedId).firstOrNull;

  /// Those not uploaded yet, so not in the show's RSS, nor here already,
  /// streaming from their source until they are.
  List<Episode> get onTheWay {
    final library = _podcasts.library;
    final show = library.podcasts.where((p) => p.cloudFeedId == feedId).firstOrNull;
    final here = {
      if (show != null)
        for (final e in library.episodes(show.id)) if (e.link != null) canonicalSourceUrl(e.link!),
    };
    return [for (final e in episodes ?? const <Episode>[]) if (e.uploadedAt == null && !here.contains(_sourceOf(e))) e];
  }

  /// The feed's episode that [episode] of the show is: by its guid once its
  /// upload is in the feed, by its source until then.
  Episode? of(PodcastEpisode episode) {
    final source = episode.link == null ? null : canonicalSourceUrl(episode.link!);
    return episodes?.where((e) => e.id == episode.guid || _sourceOf(e) == source).firstOrNull;
  }

  /// The canonical URL of what [episode] was made from.
  static String _sourceOf(Episode episode) => canonicalSourceUrl(episode.sourceUrl);

  void _follow() {
    final feed = this.feed;
    if (feed == null) return;
    final sync = _feeds.statusOf(feed);
    final signature = (feed.episodeCount, sync?.phase, sync?.added, sync?.queued, sync?.current);
    if (signature == _loadedAt) return;
    _loadedAt = signature;
    unawaited(_load(feed));
  }

  Future<void> _load(Feed feed) async {
    if (_loading case final running?) {
      await running;
      if (!_disposed) await _load(feed);
      return;
    }
    final loading = () async {
      try {
        final loaded = await _feeds.episodes(feed);
        if (_disposed) return;
        episodes = loaded;
        loadError = null;
        notifyListeners();
        // An upload the player's copy of the feed hasn't seen yet plays
        // once that copy catches up.
        final library = _podcasts.library;
        final show = library.podcasts.where((p) => p.cloudFeedId == feedId).firstOrNull;
        final known = {if (show != null) for (final e in library.episodes(show.id)) e.guid};
        if (loaded.any((e) => e.uploadedAt != null && !known.contains(e.id))) unawaited(_podcasts.cloudPublished(feedId));
      } catch (e) {
        if (_disposed) return;
        loadError = e;
        notifyListeners();
      }
    }();
    _loading = loading;
    await loading;
    _loading = null;
  }

  /// Takes [episode] out of the feed, and out of the show here, a podcast
  /// of the listener's own.
  Future<void> remove(Episode episode) async {
    final feed = this.feed;
    if (feed == null || !removing.add(episode.id)) return;
    removeError = null;
    notifyListeners();
    try {
      await _feeds.removeEpisode(feed, episode);
      episodes = [...?episodes?.where((e) => e.id != episode.id)];
      final library = _podcasts.library;
      final source = _sourceOf(episode);
      if (library.podcasts.where((p) => p.cloudFeedId == feedId).firstOrNull case final show?) {
        for (final e in library.episodes(show.id)) {
          if (e.guid == episode.id || (e.link != null && canonicalSourceUrl(e.link!) == source)) library.removeEpisode(e.id);
        }
      }
    } catch (e) {
      removeError = e;
    } finally {
      removing.remove(episode.id);
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _feeds.removeListener(_follow);
    super.dispose();
  }
}

/// What the feed's sync is doing, in a line with a dot, and how far the
/// episode uploading now has got.
final class FeedSyncLine extends StatelessWidget {
  const FeedSyncLine({super.key, required this.feed});
  final Feed feed;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final p = brand.Surface.of(context);
    final sync = Services.of(context).feeds.statusOf(feed);
    final (status, failed) = feedStatus(feed, sync);
    final phase = sync?.phase ?? FeedPhase.waiting;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Row(children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: switch (phase) {
              FeedPhase.failed => p.danger,
              FeedPhase.upToDate => p.ok,
              FeedPhase.syncing || FeedPhase.scanning => p.link,
              FeedPhase.waiting => p.fgFaint,
            },
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            status,
            style: text.bodySmall!.copyWith(color: failed ? p.danger : p.fgSoft),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ]),
      if (phase == FeedPhase.syncing && sync?.fraction != null) ...[
        const SizedBox(height: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(value: sync!.fraction, minHeight: 3, color: p.link, backgroundColor: p.track),
          ),
        ),
      ],
    ]);
  }
}

/// The feed's videos still on their way up, each with what the sync is
/// doing with it; a podcast of the listener's own can drop one.
final class OnTheWay extends StatelessWidget {
  const OnTheWay({super.key, required this.episodes, required this.own});
  final FeedEpisodes episodes;
  final bool own;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final p = brand.Surface.of(context);
    final waiting = episodes.onTheWay;
    final feed = episodes.feed;
    if (waiting.isEmpty || feed == null) return const SizedBox.shrink();
    final sync = Services.of(context).feeds.statusOf(feed);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 10),
        child: Text(
          waiting.length == 1 ? '1 on its way' : '${waiting.length} on their way',
          style: text.titleMedium!.copyWith(color: p.fg, fontSize: 15),
        ),
      ),
      rowsPanel([
        for (final episode in waiting) _row(context, episode, sync),
      ]),
    ]);
  }

  Widget _row(BuildContext context, Episode episode, FeedSync? sync) {
    final text = Theme.of(context).textTheme;
    final p = brand.Surface.of(context);
    final removing = episodes.removing.contains(episode.id);
    final (detail, busy) = _detail(episode, sync);
    return AnimatedOpacity(
      key: ValueKey(episode.id),
      opacity: removing ? 0.4 : 1,
      duration: brand.quick,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(_rowInset, 12, 10, 12),
        child: Row(children: [
          Artwork(
            url: switch (parseYouTubeLink(episode.sourceUrl)) {
              final link? => videoThumbnail(link.id),
              null => null,
            },
            title: episode.title,
            size: _thumbWidth,
            height: _thumbWidth * 9 / 16,
            radius: 8,
          ),
          const SizedBox(width: _rowInset),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                episode.title,
                style: text.bodySmall!.copyWith(color: p.fg, fontWeight: FontWeight.w600),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                detail,
                style: text.bodySmall!.copyWith(
                  color: busy ? p.link : p.fgSoft,
                  fontSize: 13,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ]),
          ),
          if (own) ...[
            const SizedBox(width: 12),
            IconButton(
              tooltip: 'Remove episode',
              visualDensity: VisualDensity.compact,
              onPressed: removing ? null : () => unawaited(episodes.remove(episode)),
              icon: Icon(Icons.close_rounded, size: 17, color: p.fgFaint),
            ),
          ],
        ]),
      ),
    );
  }

  /// What the sync is doing with [episode], and whether that is under way.
  (String, bool) _detail(Episode episode, FeedSync? sync) {
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

/// A single YouTube video's feed: put the video in a podcast of the
/// listener's own instead.
final class AddToPodcast extends StatelessWidget {
  const AddToPodcast({super.key, required this.feed, required this.url});
  final Feed feed;
  final String url;

  @override
  Widget build(BuildContext context) => Dropdown(
    align: MenuAlign.end,
    items: [
      const MenuHeader('Add to a podcast of yours'),
      for (final own in ownPodcasts(context))
        MenuEntry(own.title, icon: Icons.podcasts_rounded, onPressed: () => unawaited(addVideoToOwnPodcast(context, url, own, title: feed.title))),
      if (ownPodcasts(context).isNotEmpty) const MenuDivider(),
      MenuEntry('New podcast…', icon: Icons.add_rounded, onPressed: () => unawaited(addVideoToOwnPodcast(context, url, null, title: feed.title))),
    ],
    builder: (context, menu) => TextButton.icon(
      style: brand.button(brand.Tone.quietOnInk, brand.ButtonSize.sm),
      onPressed: menu.toggle,
      icon: const Icon(Icons.playlist_add_rounded, size: 18),
      label: const Text('Add to a podcast'),
    ),
  );
}

/// An episode row's left edge and the gap after its thumbnail.
const _rowInset = 16.0;

/// How wide an episode's video thumbnail is; 16:9, as YouTube shows it.
const _thumbWidth = 96.0;
