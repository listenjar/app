// Search, in two modes behind one field. Podcasts asks Apple's directory
// (directory.dart) and opens shows to look at or follow; before anything is
// typed it shows the region's charts. YouTube asks YouTube from this device
// (youtube.dart): a video plays free as an episode of its own, while
// following a playlist or channel is ListenJar Cloud's, which keeps it as a
// podcast for every app. A pasted link says what it is: a podcast feed
// opens, a YouTube link switches to YouTube.
import 'dart:async';

import 'package:cancellation_token/cancellation_token.dart';
import 'package:material_ui/material_ui.dart';

import 'backend/api.dart' show SourceKind;
import 'directory.dart';
import 'library.dart' show PodcastEpisode;
import 'links.dart';
import 'menu.dart';
import 'shared_links.dart' show OwnPodcast, addVideoToOwnPodcast, followYouTube, ownPodcast, ownPodcasts;
import 'plans.dart';
import 'podcasts.dart' show feedUrl;
import 'shell.dart';
import 'show_page.dart';
import 'sync.dart' show PlanLimit;
import 'theme.dart' as brand;
import 'ui.dart';
import 'youtube.dart';

const _searchDelay = Duration(milliseconds: 350);

enum _Mode { podcasts, youtube }

final class SearchPage extends StatefulWidget {
  const SearchPage({super.key, required this.request});
  final SearchRequest request;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

final class _SearchPageState extends State<SearchPage> {
  final _field = TextEditingController();
  final _focus = FocusNode();
  final _life = CancellationToken();
  _Mode _mode = _Mode.podcasts;

  CancellationToken? _searching;
  String? _answered;
  Object? _error;
  List<DirectoryPodcast> _podcasts = const [];
  List<SearchResult> _videos = const [];
  List<DirectoryPodcast>? _charts;
  Object? _chartsError;

  /// Results kept per query, so typing back to one doesn't ask again.
  final _podcastCache = <String, List<DirectoryPodcast>>{};
  final _youtubeCache = <String, List<SearchResult>>{};

  /// Something being opened or added: its feed or video link.
  final _busy = <String>{};

  /// The podcast of the listener's own that search was opened from, by id,
  /// while they search for videos to put in it; and what went in this time.
  String? _intoId;
  final _added = <String>{};
  OwnPodcast? get _into => switch (_intoId) {
    final id? => ownPodcast(context, id),
    null => null,
  };

  @override
  void initState() {
    super.initState();
    widget.request.addListener(_asked);
    _field.addListener(_typed);
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_loadCharts()));
  }

  @override
  void dispose() {
    widget.request.removeListener(_asked);
    _life.cancel();
    _field.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _asked() {
    final r = widget.request;
    setState(() {
      _mode = r.youtube ? _Mode.youtube : _Mode.podcasts;
      _intoId = r.into;
    });
    // The caret at the end, so typing carries on where another screen's
    // field left off.
    if (r.query case final q?) _field.value = TextEditingValue(text: q, selection: TextSelection.collapsed(offset: q.length));
    _focus.requestFocus();
  }

  Future<void> _loadCharts() async {
    try {
      final charts = await Services.of(context).directory.charts(_life);
      if (mounted) setState(() => _charts = charts);
    } catch (e) {
      if (mounted) setState(() => _chartsError = e);
    }
  }

  String get _query => _field.text.trim();
  YouTubeLink? get _youtubeLink => parseYouTubeLink(_query);
  Uri? get _feed => _youtubeLink == null ? feedUrl(_query) : null;

  void _typed() {
    if (_youtubeLink != null && _mode != _Mode.youtube) _mode = _Mode.youtube;
    setState(() {});
    unawaited(_search());
  }

  void _setMode(_Mode mode) {
    if (mode == _mode) return;
    setState(() {
      _mode = mode;
      _answered = null;
      _error = null;
    });
    unawaited(_search(now: true));
  }

  Future<void> _search({bool now = false}) async {
    _searching?.cancel();
    _searching = null;
    final query = _query;
    final key = '${_mode.name}:$query';
    if (query.isEmpty || _youtubeLink != null || _feed != null) {
      setState(() => _answered = null);
      return;
    }
    final cachedPodcasts = _mode == _Mode.podcasts ? _podcastCache[query] : null;
    final cachedVideos = _mode == _Mode.youtube ? _youtubeCache[query] : null;
    if (cachedPodcasts != null || cachedVideos != null) {
      setState(() => _answer(key, podcasts: cachedPodcasts, videos: cachedVideos));
      return;
    }
    final token = CancellationToken();
    setState(() => _searching = token);
    final s = Services.of(context);
    try {
      if (!now) await Future<void>.delayed(_searchDelay).asCancellable(token);
      final merged = _life.merge(token).merge(TimeoutCancellationToken(const Duration(seconds: 30)));
      if (_mode == _Mode.podcasts) {
        final found = await s.directory.search(query, merged);
        _podcastCache[query] = found;
        if (mounted) setState(() => _answer(key, podcasts: found));
      } else {
        final found = await (await s.youtube.session(merged)).search(query, merged);
        _youtubeCache[query] = found;
        if (mounted) setState(() => _answer(key, videos: found));
      }
    } on CancelledException {
      if (!token.isCancelled && !_life.isCancelled && mounted) setState(() => _answer(key, error: 'It took too long.'));
    } catch (e) {
      if (mounted) setState(() => _answer(key, error: e));
    } finally {
      if (_searching == token && mounted) setState(() => _searching = null);
    }
  }

  void _answer(String key, {List<DirectoryPodcast>? podcasts, List<SearchResult>? videos, Object? error}) {
    _answered = key;
    _error = error;
    if (podcasts != null) _podcasts = podcasts;
    if (videos != null) _videos = videos;
  }

  // Acting on results.

  Future<void> _run(String key, Future<void> Function() action, String failed) async {
    if (!_busy.add(key)) return;
    setState(() {});
    try {
      await action();
    } on PlanLimit catch (e) {
      if (mounted) {
        await showPlans(
          context,
          title: e.storageFull ? 'Your storage is full' : 'Follow playlists and channels',
          cloud: e.storageFull || isPaid(Services.of(context).account.user),
        );
      }
    } catch (e) {
      if (mounted) tell(context, '$failed: $e');
    } finally {
      _busy.remove(key);
      if (mounted) setState(() {});
    }
  }

  Future<void> _openFeed(String url, {bool follow = false}) => _run(url, () async {
    final s = Services.of(context);
    final navigator = Navigator.of(context);
    final show = await s.podcasts.open(Uri.parse(url), _life, follow: follow);
    if (!follow && mounted) {
      await navigator.push(MaterialPageRoute<void>(builder: (_) => ShowPage(podcastId: show.id)));
    } else if (mounted) {
      tell(context, 'Following “${show.title}”.');
    }
  }, 'Couldn’t open that podcast');

  Future<void> _playVideo(YouTubeLink link, {SearchResult? result, bool keep = false}) => _run(link.url, () async {
    final s = Services.of(context);
    final episode = await s.podcasts.youtubeVideo(
      link,
      _life,
      title: result?.title,
      channel: result?.details.firstOrNull,
      artworkUrl: result?.thumbnailUrl,
      follow: keep,
    );
    if (keep) {
      if (mounted) tell(context, 'Added “${episode.title}” to your library.');
    } else {
      await s.player.playEpisode(episode);
    }
  }, 'Couldn’t play that video');

  /// Playlists and channels take a plan: followed on this device, where
  /// they stream, or in ListenJar Cloud, as Settings says.
  Future<void> _follow(String url, String title) async {
    final link = parseYouTubeLink(url);
    if (link == null) return;
    await _run(url, () => followYouTube(context, link, '“$title”'), 'Couldn’t follow that');
  }

  /// Adds the video to [own], a podcast of the listener's own on this
  /// device or in ListenJar Cloud, or to a new one they make. Signed out or
  /// on Free, says what that takes instead.
  Future<void> _addToPodcast(YouTubeLink link, OwnPodcast? own, {String? title}) async {
    await _run(link.url, () async {
      final target = await addVideoToOwnPodcast(context, link.url, own, title: title);
      if (target != null) _added.add('${target.id} ${link.url}');
    }, 'Couldn’t add that video');
  }

  // Building.

  @override
  Widget build(BuildContext context) {
    final s = Services.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([s.library, s.account, s.feeds]),
      builder: (context, _) => PageBody(children: [
        pageTitle(context, 'Search'),
        const SizedBox(height: 12),
        _searchField(context),
        const SizedBox(height: 12),
        _modes(context),
        if (_mode == _Mode.youtube && _into != null) ...[const SizedBox(height: 16), _intoBar(context, _into!)],
        const SizedBox(height: 24),
        ..._results(context),
      ]),
    );
  }

  Widget _searchField(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final focused = _focus.hasFocus;
    return ListenableBuilder(
      listenable: _focus,
      builder: (context, _) => AnimatedContainer(
        duration: brand.quick,
        curve: brand.easeOutExpo,
        height: 52,
        padding: const EdgeInsets.only(left: 16, right: 6),
        decoration: BoxDecoration(
          color: _focus.hasFocus ? brand.white : const Color(0xFFEFEDE8),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _focus.hasFocus ? brand.accent.withValues(alpha: 0.6) : brand.line, width: _focus.hasFocus ? 1.5 : 1),
          boxShadow: _focus.hasFocus ? const [BoxShadow(color: Color(0x1F5165EE), offset: Offset(0, 6), blurRadius: 18, spreadRadius: -6)] : null,
        ),
        child: Row(children: [
          SizedBox.square(
            dimension: 20,
            child: _searching != null
              ? const Padding(padding: EdgeInsets.all(2), child: CircularProgressIndicator(strokeWidth: 2, color: brand.accent))
              : Icon(
                  _youtubeLink != null || _feed != null ? Icons.link_rounded : Icons.search_rounded,
                  size: 20,
                  color: focused ? brand.accent : brand.fgSoft,
                ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: _field,
              focusNode: _focus,
              autofocus: MediaQuery.sizeOf(context).width >= wideWidth,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => unawaited(_search(now: true)),
              style: text.bodyLarge!.copyWith(height: 1.2),
              cursorColor: brand.accent,
              decoration: InputDecoration(
                isCollapsed: true,
                border: InputBorder.none,
                hintText: _mode == _Mode.podcasts ? 'Shows, people, topics, or an RSS link' : 'Videos, channels, playlists, or a YouTube link',
                hintStyle: text.bodyLarge!.copyWith(color: brand.fgSoft, height: 1.2),
              ),
            ),
          ),
          if (_field.text.isNotEmpty)
            IconButton(
              tooltip: 'Clear',
              onPressed: () {
                _field.clear();
                _focus.requestFocus();
              },
              icon: const Icon(Icons.close_rounded, size: 20, color: brand.fgSoft),
            ),
        ]),
      ),
    );
  }

  Widget _modes(BuildContext context) {
    final text = Theme.of(context).textTheme;
    Widget tab(_Mode mode, IconData icon, String label) {
      final on = _mode == mode;
      return Semantics(
        selected: on,
        button: true,
        child: TextButton.icon(
          onPressed: () => _setMode(mode),
          style: TextButton.styleFrom(
            backgroundColor: on ? brand.ink : brand.white,
            foregroundColor: on ? brand.white : brand.fg,
            minimumSize: const Size(0, 36),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            shape: StadiumBorder(side: BorderSide(color: on ? brand.ink : brand.line)),
            textStyle: text.labelLarge!.copyWith(fontSize: 14),
          ),
          icon: Icon(icon, size: 18),
          label: Text(label),
        ),
      );
    }

    return Wrap(spacing: 8, children: [
      tab(_Mode.podcasts, Icons.podcasts_rounded, 'Podcasts'),
      tab(_Mode.youtube, Icons.smart_display_outlined, 'YouTube'),
    ]);
  }

  /// Search opened from a podcast of the listener's own: the videos found
  /// go into it, until they're done.
  Widget _intoBar(BuildContext context, OwnPodcast own) {
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
      decoration: BoxDecoration(color: brand.mist, borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        const Icon(Icons.podcasts_rounded, size: 18, color: brand.accent),
        const SizedBox(width: 10),
        Expanded(
          child: Text.rich(
            TextSpan(children: [
              const TextSpan(text: 'Adding videos to '),
              TextSpan(text: '“${own.title}”', style: const TextStyle(fontWeight: FontWeight.w600)),
            ]),
            style: text.bodyMedium!.copyWith(color: brand.fg),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 12),
        TextButton(
          style: brand.button(brand.Tone.quiet, brand.ButtonSize.sm),
          onPressed: () => setState(() => _intoId = null),
          child: const Text('Done'),
        ),
      ]),
    );
  }

  List<Widget> _results(BuildContext context) {
    final text = Theme.of(context).textTheme;
    if (_youtubeLink case final link?) return [_linkCard(context, link)];
    if (_feed case final url?) return [_feedCard(context, url)];
    final key = '${_mode.name}:$_query';
    if (_query.isEmpty) return _mode == _Mode.podcasts ? _chartsList(context) : [_youtubeIntro(context)];
    if (_answered != key) return [const _ResultsSkeleton()];
    if (_error case final error?) {
      return [problem(context, _mode == _Mode.podcasts ? 'Couldn’t reach Apple’s podcast directory.' : 'Couldn’t search YouTube.', error)];
    }
    if (_mode == _Mode.podcasts) {
      if (_podcasts.isEmpty) return [Text('No shows found for “$_query”.', style: text.bodyMedium!.copyWith(color: brand.fgSoft))];
      return [rowsPanel([for (final p in _podcasts) _podcastRow(context, p)])];
    }
    if (_videos.isEmpty) return [Text('Nothing found on YouTube for “$_query”.', style: text.bodyMedium!.copyWith(color: brand.fgSoft))];
    return [rowsPanel([for (final r in _videos) _youtubeRow(context, r)])];
  }

  List<Widget> _chartsList(BuildContext context) {
    final charts = _charts;
    return [
      sectionHeading(context, 'Top podcasts', top: 0),
      if (charts == null && _chartsError == null)
        const _ResultsSkeleton()
      else if (_chartsError != null)
        problem(context, 'Couldn’t load the charts. Search still works.', _chartsError)
      else
        rowsPanel([for (final p in charts!.take(30)) _podcastRow(context, p)]),
    ];
  }

  Widget _podcastRow(BuildContext context, DirectoryPodcast p) {
    final text = Theme.of(context).textTheme;
    final library = Services.of(context).library;
    final known = library.podcastByUrl(p.feedUrl);
    final following = known?.followed ?? false;
    final busy = _busy.contains(p.feedUrl);
    return _ResultRow(
      onTap: () => unawaited(_openFeed(p.feedUrl)),
      leading: Artwork(url: p.artworkUrl, title: p.title, size: 60),
      title: p.title,
      subtitle: [
        if (p.author.isNotEmpty) p.author,
        ?p.genre,
        if (p.episodeCount case final n? when n > 0) '$n episodes',
      ].join(' · '),
      trailing: busy
        ? const _Spinner()
        : following
          ? TextButton.icon(
              style: brand.button(brand.Tone.quiet, brand.ButtonSize.sm),
              onPressed: () => Navigation.of(context).openShow(known!.id),
              icon: const Icon(Icons.check_rounded, size: 18),
              label: Text('Following', style: text.labelLarge!.copyWith(fontSize: 14)),
            )
          : TextButton.icon(
              style: brand.button(brand.Tone.ink, brand.ButtonSize.sm),
              onPressed: () => unawaited(_openFeed(p.feedUrl, follow: true)),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Follow'),
            ),
    );
  }

  /// The video as the episode it became when it was played or kept, if it
  /// was: the player knows it by that, as it knows any other episode.
  PodcastEpisode? _videoEpisode(YouTubeLink? link) =>
    link == null || link.kind != SourceKind.video ? null : Services.of(context).library.youtubeVideo(link.id);

  Widget _youtubeRow(BuildContext context, SearchResult r) {
    final link = parseYouTubeLink(r.url);
    final busy = _busy.contains(link?.url ?? r.url);
    final episode = _videoEpisode(link);
    final kind = switch (r.kind) {
      SourceRefKind.video => null,
      SourceRefKind.playlist => 'Playlist',
      SourceRefKind.channel => 'Channel',
    };
    return _ResultRow(
      onTap: link == null
        ? null
        : r.kind != SourceRefKind.video
          ? () => unawaited(_follow(r.url, r.title))
          : episode != null
            ? () {
                doneTyping();
                unawaited(Services.of(context).player.playEpisode(episode));
              }
            : () {
                doneTyping();
                unawaited(_playVideo(link, result: r));
              },
      leading: _Thumbnail(result: r),
      title: r.title,
      subtitle: [?kind, ...r.details].join(' · '),
      progress: episode == null ? null : _progress(episode),
      trailing: busy || link == null
        ? (busy ? const _Spinner() : null)
        : r.kind == SourceRefKind.video
          ? _videoActions(context, link, r, episode)
          : _followButton(context, r.url, r.title),
    );
  }

  /// How far the listener got in [e], once they started it.
  static double? _progress(PodcastEpisode e) => switch (e.duration) {
    final d? when e.started && d > Duration.zero => (e.position.inMilliseconds / d.inMilliseconds).clamp(0.0, 1.0),
    _ => null,
  };

  /// Add and play. Add keeps the video in the Library, or puts it in a
  /// podcast of the listener's own. Once the video is an
  /// episode, play is the same button every episode has: it pauses while
  /// this one plays and resumes it.
  Widget _videoActions(BuildContext context, YouTubeLink link, SearchResult? r, PodcastEpisode? episode) {
    final s = Services.of(context);
    final kept = episode != null && (s.library.podcast(episode.podcastId)?.followed ?? false);
    final own = ownPodcasts(context);
    final into = _into;
    final added = into != null && _added.contains('${into.id} ${link.url}');
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Dropdown(
        align: MenuAlign.end,
        items: [
          MenuEntry(
            kept ? 'In your Library' : 'Add to Library',
            icon: kept ? Icons.library_add_check_rounded : Icons.library_add_outlined,
            onPressed: kept ? null : () => unawaited(_playVideo(link, result: r, keep: true)),
          ),
          const MenuDivider(),
          const MenuHeader('Add to a podcast of yours'),
          for (final o in own)
            MenuEntry(o.title, icon: o.icon, onPressed: () => unawaited(_addToPodcast(link, o, title: r?.title))),
          MenuEntry('New podcast…', icon: Icons.add_rounded, onPressed: () => unawaited(_addToPodcast(link, null, title: r?.title))),
        ],
        builder: (context, menu) => IconButton(
          tooltip: 'Add to Library or a podcast',
          onPressed: menu.toggle,
          icon: Icon(kept ? Icons.library_add_check_rounded : Icons.library_add_outlined, color: kept ? brand.accent : brand.fgSoft),
        ),
      ),
      const SizedBox(width: 4),
      if (into != null) ...[
        TextButton.icon(
          style: brand.button(added ? brand.Tone.quiet : brand.Tone.accent, brand.ButtonSize.sm),
          onPressed: added ? null : () => unawaited(_addToPodcast(link, into, title: r?.title)),
          icon: Icon(added ? Icons.check_rounded : Icons.add_rounded, size: 18),
          label: Text(added ? 'Added' : 'Add'),
        ),
        const SizedBox(width: 8),
      ],
      if (episode != null)
        PlayButton(episode: episode)
      else
        SizedBox.square(
          dimension: 40,
          child: IconButton(
            tooltip: 'Play',
            padding: EdgeInsets.zero,
            style: IconButton.styleFrom(backgroundColor: brand.ink, foregroundColor: brand.white, hoverColor: const Color(0xFF23252D)),
            onPressed: () {
              doneTyping();
              unawaited(_playVideo(link, result: r));
            },
            icon: const Icon(Icons.play_arrow_rounded, size: 22),
          ),
        ),
    ]);
  }

  /// Follow: where Settings keeps new podcasts, on this device unless the
  /// listener chose the Cloud; its page can move it. Without a plan, says
  /// what following takes.
  Widget _followButton(BuildContext context, String url, String title) => TextButton.icon(
    style: brand.button(brand.Tone.quiet, brand.ButtonSize.sm),
    onPressed: () => unawaited(_follow(url, title)),
    icon: const Icon(Icons.add_rounded, size: 18),
    label: const Text('Follow'),
  );

  Widget _linkCard(BuildContext context, YouTubeLink link) {
    final text = Theme.of(context).textTheme;
    final video = link.kind == SourceKind.video;
    return brand.panel(
      padding: 24,
      child: Row(children: [
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(color: brand.mist, borderRadius: BorderRadius.circular(14)),
          child: const Icon(Icons.smart_display_outlined, color: brand.accent),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(kindLabel(link.kind), style: text.titleMedium),
            const SizedBox(height: 4),
            Text(
              video
                ? 'Plays here as an episode of its own. Free, on this device.'
                : startsInCloud(Services.of(context))
                  ? 'Follow it in ListenJar Cloud, for any podcast app.'
                  : 'Follow it on this device. Its videos stream from YouTube.',
              style: text.bodySmall!.copyWith(color: brand.fgSoft),
            ),
          ]),
        ),
        const SizedBox(width: 12),
        if (_busy.contains(link.url))
          const _Spinner()
        else if (video)
          _videoActions(context, link, null, _videoEpisode(link))
        else
          _followButton(context, link.url, kindLabel(link.kind)),
      ]),
    );
  }

  Widget _feedCard(BuildContext context, Uri url) {
    final text = Theme.of(context).textTheme;
    return brand.panel(
      padding: 24,
      child: Row(children: [
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(color: brand.mist, borderRadius: BorderRadius.circular(14)),
          child: const Icon(Icons.rss_feed_rounded, color: brand.accent),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Podcast feed', style: text.titleMedium),
            const SizedBox(height: 4),
            Text('$url', maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodySmall!.copyWith(color: brand.fgSoft)),
          ]),
        ),
        const SizedBox(width: 12),
        if (_busy.contains('$url'))
          const _Spinner()
        else ...[
          TextButton(style: brand.button(brand.Tone.quiet, brand.ButtonSize.sm), onPressed: () => unawaited(_openFeed('$url')), child: const Text('Open')),
          const SizedBox(width: 8),
          brand.accentShadow(
            enabled: true,
            child: TextButton(
              style: brand.button(brand.Tone.accent, brand.ButtonSize.sm),
              onPressed: () => unawaited(_openFeed('$url', follow: true)),
              child: const Text('Follow'),
            ),
          ),
        ],
      ]),
    );
  }

  Widget _youtubeIntro(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final signedIn = Services.of(context).account.user != null;
    return brand.panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('YouTube, as podcasts', style: text.titleLarge),
        const SizedBox(height: 10),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Text(
            'Search YouTube or paste a link. Any single video plays here as an episode, free, straight from YouTube to this device. '
            'Following a playlist or a channel turns it into a podcast that ListenJar Cloud keeps up to date, for this app and any other.',
            style: text.bodyMedium!.copyWith(color: brand.fgSoft),
          ),
        ),
        if (!signedIn) ...[
          const SizedBox(height: 20),
          TextButton.icon(
            style: brand.button(brand.Tone.quiet, brand.ButtonSize.sm),
            onPressed: () => Navigation.of(context).openSettings(),
            icon: const Icon(Icons.cloud_outlined, size: 18),
            label: const Text('About ListenJar Cloud'),
          ),
        ],
      ]),
    );
  }
}

final class _ResultRow extends StatefulWidget {
  const _ResultRow({required this.leading, required this.title, required this.subtitle, required this.trailing, required this.onTap, this.progress});
  final Widget leading;
  final String title;
  final String subtitle;

  /// How far the listener got, for a video they started.
  final double? progress;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  State<_ResultRow> createState() => _ResultRowState();
}

final class _ResultRowState extends State<_ResultRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: brand.quick,
        decoration: BoxDecoration(color: _hover ? brand.mist : brand.mist.withValues(alpha: 0), borderRadius: BorderRadius.circular(14)),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: widget.onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
            child: Row(children: [
              widget.leading,
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(widget.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: text.titleMedium!.copyWith(fontSize: 15, height: 1.3)),
                  if (widget.subtitle.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(widget.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodySmall!.copyWith(color: brand.fgSoft, fontSize: 13)),
                  ],
                  if (widget.progress case final progress?) ...[
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: SizedBox(
                        width: 120,
                        height: 3,
                        child: LinearProgressIndicator(value: progress, color: brand.accent, backgroundColor: brand.paperDeep),
                      ),
                    ),
                  ],
                ]),
              ),
              if (widget.trailing case final trailing?) ...[const SizedBox(width: 12), trailing],
            ]),
          ),
        ),
      ),
    );
  }
}

final class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.result});
  final SearchResult result;

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    const placeholder = ColoredBox(color: brand.paperDeep);
    Widget image(double w) => switch (result.thumbnailUrl) {
      null => placeholder,
      final url => Image.network(
        url,
        fit: BoxFit.cover,
        cacheWidth: (w * dpr).round(),
        errorBuilder: (_, _, _) => placeholder,
        frameBuilder: (_, child, frame, sync) => sync || frame != null ? child : placeholder,
      ),
    };
    return SizedBox(
      width: 96,
      height: 60,
      child: switch (result.kind) {
        SourceRefKind.channel => Center(child: ClipOval(child: SizedBox.square(dimension: 56, child: image(56)))),
        _ => Center(child: ClipRRect(borderRadius: BorderRadius.circular(10), child: SizedBox(width: 96, height: 54, child: image(96)))),
      },
    );
  }
}

final class _Spinner extends StatelessWidget {
  const _Spinner();
  @override
  Widget build(BuildContext context) => const SizedBox.square(
    dimension: 40,
    child: Center(child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2, color: brand.accent))),
  );
}

/// Rows of grey while results come, the shape of what's coming.
final class _ResultsSkeleton extends StatelessWidget {
  const _ResultsSkeleton();

  @override
  Widget build(BuildContext context) => rowsPanel([
    for (var i = 0; i < 5; i++)
      Padding(
        padding: const EdgeInsets.all(10),
        child: Row(children: [
          Container(width: 60, height: 60, decoration: BoxDecoration(color: brand.paperDeep, borderRadius: BorderRadius.circular(10))),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              FractionallySizedBox(widthFactor: 0.6 - i * 0.05, child: Container(height: 14, decoration: BoxDecoration(color: brand.paperDeep, borderRadius: BorderRadius.circular(4)))),
              const SizedBox(height: 8),
              FractionallySizedBox(widthFactor: 0.35, child: Container(height: 11, decoration: BoxDecoration(color: brand.paperDeep, borderRadius: BorderRadius.circular(4)))),
            ]),
          ),
        ]),
      ),
  ]);
}
