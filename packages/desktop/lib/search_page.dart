// Search, in two modes behind one field. Podcasts asks Apple's directory
// (directory.dart) and opens shows to look at or follow; before anything is
// typed it shows the region's charts. YouTube asks YouTube from this device
// (youtube.dart): a video plays free as an episode of its own, while
// following a playlist or channel is Listenjar Cloud's, which keeps it as a
// podcast for every app. A pasted link says what it is: a podcast feed
// opens, a YouTube link switches to YouTube.
import 'dart:async';

import 'package:cancellation_token/cancellation_token.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'backend/api.dart' show SourceKind;
import 'directory.dart';
import 'library.dart' show PodcastEpisode;
import 'links.dart';
import 'marks.dart';
import 'menu.dart';
import 'shared_links.dart' show OwnPodcast, addVideoToOwnPodcast, followYouTube, openApplePodcasts, ownPodcast, ownPodcasts;
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

  /// Pasted YouTube links looked up, by link: as search would list them, or
  /// why YouTube couldn't say.
  final _linked = <String, SearchResult>{};
  final _linkFailed = <String, Object>{};
  final _lookingUp = <String>{};

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

  /// The request's [SearchRequest.asked] last taken up; a call that leaves it
  /// be (a second tap on Search) only focuses the field.
  int _seen = 0;

  void _asked() {
    final r = widget.request;
    if (r.asked != _seen) {
      _seen = r.asked;
      setState(() {
        _mode = r.youtube ? _Mode.youtube : _Mode.podcasts;
        _intoId = r.into;
      });
      // The caret at the end, so typing carries on where another screen's
      // field left off.
      if (r.query case final q?) _field.value = TextEditingValue(text: q, selection: TextSelection.collapsed(offset: q.length));
    }
    // After the frame: a page popped off search on the way here would
    // otherwise hand focus back as it goes.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // A focused field whose keyboard was put away (Android's back) gets
      // it back; focusing raises it otherwise.
      if (_focus.hasFocus) {
        unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.show'));
      } else {
        _focus.requestFocus();
      }
    });
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

  /// What a pasted link is: its title, thumbnail and channel, once.
  Future<void> _lookUp(YouTubeLink link) async {
    if (!mounted || _linked.containsKey(link.url) || _linkFailed.containsKey(link.url) || !_lookingUp.add(link.url)) return;
    setState(() {});
    final s = Services.of(context);
    final token = _life.merge(TimeoutCancellationToken(const Duration(seconds: 30)));
    try {
      final source = SourceRef(switch (link.kind) {
        SourceKind.video => SourceRefKind.video,
        SourceKind.playlist => SourceRefKind.playlist,
        SourceKind.channel => SourceRefKind.channel,
      }, link.id, link.url);
      final found = await (await s.youtube.session(token)).lookup(source, token);
      _linked[link.url] = found;
    } catch (e) {
      if (_life.isCancelled) return;
      _linkFailed[link.url] = e;
    } finally {
      _lookingUp.remove(link.url);
      if (mounted) setState(() {});
    }
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
    if (parseApplePodcastsLink(url) case final apple?) return openApplePodcasts(context, apple, Uri.parse(url), follow: follow);
    final s = Services.of(context);
    final navigator = Navigator.of(context);
    final show = await s.podcasts.open(Uri.parse(url), _life, follow: follow);
    if (!follow && mounted) {
      await navigator.push(pageRoute(ShowPage(podcastId: show.id)));
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
      description: result?.description,
      publishedAt: result?.publishedAt,
      follow: keep,
    );
    if (keep) {
      if (mounted) tell(context, 'Added “${episode.title}” to your library.');
    } else {
      await s.player.playEpisode(episode);
    }
  }, 'Couldn’t play that video');

  /// Playlists and channels take a plan; they stream here at once, and on
  /// a plan with Listenjar Cloud they upload too.
  Future<void> _follow(String url, String title) async {
    final link = parseYouTubeLink(url);
    if (link == null) return;
    await _run(url, () => followYouTube(context, link, '“$title”'), 'Couldn’t follow that');
  }

  /// Adds the video to [own], a podcast of the listener's own, or to a new
  /// one they make. Signed out or on Free, says what that takes instead.
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
            child: _searching != null || _lookingUp.isNotEmpty
              ? const Padding(padding: EdgeInsets.all(2), child: CircularProgressIndicator(strokeWidth: 2, color: brand.accent))
              : GlyphIcon(
                  _youtubeLink != null || _feed != null ? Glyphs.link : Glyphs.search,
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
              icon: const GlyphIcon(Glyphs.close, size: 20, color: brand.fgSoft),
            ),
        ]),
      ),
    );
  }

  Widget _modes(BuildContext context) => _SourceSwitch(youtube: _mode == _Mode.youtube, onChanged: (youtube) => _setMode(youtube ? _Mode.youtube : _Mode.podcasts));

  /// Search opened from a podcast of the listener's own: the videos found
  /// go into it, until they're done.
  Widget _intoBar(BuildContext context, OwnPodcast own) {
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
      decoration: BoxDecoration(color: brand.mist, borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        const GlyphIcon(Glyphs.podcast, size: 18, color: brand.accent),
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
    if (_youtubeLink case final link?) {
      if (_linked[link.url] case final r?) return [rowsPanel([_youtubeRow(context, r)])];
      // Should YouTube not say, the link still plays or follows as it is.
      if (_linkFailed.containsKey(link.url)) return [_linkCard(context, link)];
      WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_lookUp(link)));
      return [const _ResultsSkeleton(rows: 1, videos: true)];
    }
    if (_feed case final url?) return [_feedCard(context, url)];
    final key = '${_mode.name}:$_query';
    if (_query.isEmpty) return _mode == _Mode.podcasts ? _chartsList(context) : [_youtubeIntro(context)];
    if (_answered != key) return [_ResultsSkeleton(videos: _mode == _Mode.youtube)];
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
              icon: const GlyphIcon(Glyphs.check, size: 18),
              label: Text('Following', style: text.labelLarge!.copyWith(fontSize: 14)),
            )
          : TextButton.icon(
              style: brand.button(brand.Tone.ink, brand.ButtonSize.sm),
              onPressed: () => unawaited(_openFeed(p.feedUrl, follow: true)),
              icon: const GlyphIcon(Glyphs.plus, size: 18),
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
    return LayoutBuilder(builder: (context, box) {
      // Narrow, the row itself plays and only the add menu stays beside it,
      // so the title keeps room for two lines.
      final compact = box.maxWidth < _compactRow;
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
        leading: _Thumbnail(result: r, width: compact ? 120 : 160, episode: episode),
        title: r.title,
        subtitle: [?kind, ...r.details].join(' · '),
        trailing: busy || link == null
          ? (busy ? const _Spinner() : null)
          : r.kind == SourceRefKind.video
            ? _videoActions(context, link, r, episode, play: !compact)
            : _followButton(context, r.url, r.title),
      );
    });
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
  Widget _videoActions(BuildContext context, YouTubeLink link, SearchResult? r, PodcastEpisode? episode, {bool play = true}) {
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
            icon: kept ? Glyphs.saved : Glyphs.save,
            onPressed: kept ? null : () => unawaited(_playVideo(link, result: r, keep: true)),
          ),
          const MenuDivider(),
          const MenuHeader('Add to a podcast of yours'),
          for (final o in own)
            MenuEntry(o.title, icon: Glyphs.podcast, onPressed: () => unawaited(_addToPodcast(link, o, title: r?.title))),
          MenuEntry('New podcast…', icon: Glyphs.plus, onPressed: () => unawaited(_addToPodcast(link, null, title: r?.title))),
        ],
        builder: (context, menu) => IconButton(
          tooltip: 'Add to Library or a podcast',
          onPressed: menu.toggle,
          icon: GlyphIcon(kept ? Glyphs.saved : Glyphs.save, color: kept ? brand.accent : brand.fgSoft),
        ),
      ),
      const SizedBox(width: 4),
      if (into != null) ...[
        TextButton.icon(
          style: brand.button(added ? brand.Tone.quiet : brand.Tone.accent, brand.ButtonSize.sm),
          onPressed: added ? null : () => unawaited(_addToPodcast(link, into, title: r?.title)),
          icon: GlyphIcon(added ? Glyphs.check : Glyphs.plus, size: 18),
          label: Text(added ? 'Added' : 'Add'),
        ),
        if (play) const SizedBox(width: 8),
      ],
      if (!play)
        const SizedBox.shrink()
      else if (episode != null)
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
            icon: const GlyphIcon(Glyphs.play, size: 22),
          ),
        ),
    ]);
  }

  /// Follow: it lists here at once, and uploads on a plan with Listenjar
  /// Cloud. Without a plan, says
  /// what following takes.
  Widget _followButton(BuildContext context, String url, String title) => TextButton.icon(
    style: brand.button(brand.Tone.quiet, brand.ButtonSize.sm),
    onPressed: () => unawaited(_follow(url, title)),
    icon: const GlyphIcon(Glyphs.plus, size: 18),
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
          child: const Center(child: YouTubeMark(size: 24, color: brand.accent)),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(kindLabel(link.kind), style: text.titleMedium),
            const SizedBox(height: 4),
            Text(
              video
                ? 'Plays here as an episode of its own. Free, on this device.'
                : hasCloud(Services.of(context).account.user)
                  ? 'Follow it here, and as a podcast for any podcast app.'
                  : 'Follow it. Its videos stream from YouTube.',
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
    final apple = parseApplePodcastsLink('$url') != null;
    return brand.panel(
      padding: 24,
      child: Row(children: [
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(color: brand.mist, borderRadius: BorderRadius.circular(14)),
          child: GlyphIcon(apple ? Glyphs.podcast : Glyphs.feed, color: brand.accent),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(apple ? 'Apple Podcasts link' : 'Podcast feed', style: text.titleMedium),
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
            'Following a playlist or a channel makes it a show here with Local YouTube, and a feed for any podcast app with Cloud.',
            style: text.bodyMedium!.copyWith(color: brand.fgSoft),
          ),
        ),
        if (!signedIn) ...[
          const SizedBox(height: 20),
          TextButton.icon(
            style: brand.button(brand.Tone.quiet, brand.ButtonSize.sm),
            onPressed: () => Navigation.of(context).openSettings(),
            icon: const GlyphIcon(Glyphs.cloud, size: 18),
            label: const Text('About Listenjar Cloud'),
          ),
        ],
      ]),
    );
  }
}

/// Below this width a video's row drops its play button: the row plays.
const _compactRow = 480.0;

final class _ResultRow extends StatefulWidget {
  const _ResultRow({required this.leading, required this.title, required this.subtitle, required this.trailing, required this.onTap});
  final Widget leading;
  final String title;
  final String subtitle;
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
            padding: const EdgeInsets.all(10),
            child: Row(children: [
              widget.leading,
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(widget.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: text.titleMedium!.copyWith(fontSize: 15, height: 1.3)),
                  if (widget.subtitle.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(widget.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodySmall!.copyWith(color: brand.fgSoft, fontSize: 13)),
                  ],
                ]),
              ),
              if (widget.trailing case final trailing?) ...[const SizedBox(width: 8), trailing],
            ]),
          ),
        ),
      ),
    );
  }
}

/// A result's picture: a video's frame with its length on it and, once
/// started, how far the listener got along its foot; a playlist's with its
/// size; a channel's round avatar.
final class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.result, required this.width, this.episode});
  final SearchResult result;
  final double width;

  /// The video as an episode, once it was played or kept.
  final PodcastEpisode? episode;

  @override
  Widget build(BuildContext context) {
    final height = width * 9 / 16;
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
    if (result.kind == SourceRefKind.channel) {
      return SizedBox(
        width: width,
        height: height,
        child: Center(child: ClipOval(child: SizedBox.square(dimension: height, child: image(height)))),
      );
    }
    final player = Services.of(context).player;
    return Semantics(
      excludeSemantics: true,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          width: width,
          height: height,
          child: ListenableBuilder(
            listenable: player,
            builder: (context, _) {
              final e = episode;
              final playing = e != null && player.current?.id == e.id && player.playing;
              final progress = e == null ? null : _SearchPageState._progress(e);
              return Stack(fit: StackFit.expand, children: [
                image(width),
                if (playing)
                  const Positioned(right: 6, bottom: 9, child: _Badge(icon: Glyphs.playing, label: 'Playing', accent: true))
                else if (result.badge case final badge?)
                  Positioned(
                    right: 6,
                    bottom: progress == null ? 6 : 9,
                    child: _Badge(icon: result.kind == SourceRefKind.playlist ? Glyphs.queue : null, label: badge),
                  ),
                if (progress != null)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: 3,
                    child: ColoredBox(
                      color: const Color(0x66FFFFFF),
                      child: FractionallySizedBox(alignment: Alignment.centerLeft, widthFactor: progress, child: const ColoredBox(color: brand.accent)),
                    ),
                  ),
              ]);
            },
          ),
        ),
      ),
    );
  }
}

/// A small ink tag over a thumbnail: a length, a playlist's size, or that
/// it's playing.
final class _Badge extends StatelessWidget {
  const _Badge({required this.label, this.icon, this.accent = false});
  final String label;
  final Glyph? icon;
  final bool accent;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(color: accent ? brand.accent : const Color(0xD90A0B0F), borderRadius: BorderRadius.circular(6)),
    child: Padding(
      padding: EdgeInsets.fromLTRB(icon == null ? 6 : 4, 3, 6, 3),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon case final icon?) ...[GlyphIcon(icon, size: 13, color: brand.white), const SizedBox(width: 3)],
        Text(
          label,
          style: const TextStyle(color: brand.white, fontSize: 12, fontWeight: FontWeight.w600, height: 1.15, fontFeatures: [FontFeature.tabularFigures()]),
        ),
      ]),
    ),
  );
}

/// The two places search asks, as one control: a track with the chosen
/// source held on a white thumb that slides between them.
final class _SourceSwitch extends StatelessWidget {
  const _SourceSwitch({required this.youtube, required this.onChanged});
  final bool youtube;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    Widget segment(bool isYouTube, String label) {
      final on = youtube == isYouTube;
      final color = on ? brand.fg : brand.fgSoft;
      return Semantics(
        selected: on,
        child: TextButton(
          onPressed: () => onChanged(isYouTube),
          style: ButtonStyle(
            minimumSize: const WidgetStatePropertyAll(Size(0, 36)),
            padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 16)),
            backgroundColor: const WidgetStatePropertyAll(Color(0x00FFFFFF)),
            overlayColor: const WidgetStatePropertyAll(Color(0x00FFFFFF)),
            foregroundColor: WidgetStateProperty.fromMap({WidgetState.hovered: brand.fg, WidgetState.any: color}),
            textStyle: WidgetStatePropertyAll(Theme.of(context).textTheme.labelLarge!.copyWith(fontSize: 14)),
            shape: WidgetStateProperty.resolveWith((states) => StadiumBorder(side: states.contains(WidgetState.focused) ? brand.focusSide : brand.focusSideOff)),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            AnimatedSwitcher(
              duration: still ? Duration.zero : brand.quick,
              child: isYouTube
                ? YouTubeMark(key: ValueKey(on), size: 18, color: on ? brand.accent : brand.fgSoft)
                : GlyphIcon(Glyphs.podcast, key: ValueKey(on), size: 18, color: on ? brand.accent : brand.fgSoft),
            ),
            const SizedBox(width: 8),
            Text(label),
          ]),
        ),
      );
    }

    return Align(
      alignment: Alignment.centerLeft,
      child: DecoratedBox(
        decoration: BoxDecoration(color: brand.paperDeep, borderRadius: BorderRadius.circular(999)),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: IntrinsicWidth(
            child: Stack(children: [
              Positioned.fill(
                child: AnimatedAlign(
                  duration: still ? Duration.zero : const Duration(milliseconds: 300),
                  curve: brand.easeOutExpo,
                  alignment: youtube ? Alignment.centerRight : Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: 0.5,
                    heightFactor: 1,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: brand.white,
                        borderRadius: BorderRadius.circular(999),
                        boxShadow: const [BoxShadow(color: Color(0x1F171A38), offset: Offset(0, 2), blurRadius: 6, spreadRadius: -1)],
                      ),
                    ),
                  ),
                ),
              ),
              Row(children: [
                Expanded(child: segment(false, 'Podcasts')),
                Expanded(child: segment(true, 'YouTube')),
              ]),
            ]),
          ),
        ),
      ),
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

/// Rows of grey while results come, the shape of what's coming: square
/// artwork for shows, wide frames for videos.
final class _ResultsSkeleton extends StatelessWidget {
  const _ResultsSkeleton({this.rows = 5, this.videos = false});
  final int rows;
  final bool videos;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
    final width = videos ? (box.maxWidth - 32 < _compactRow ? 120.0 : 160.0) : 60.0;
    return rowsPanel([
      for (var i = 0; i < rows; i++)
        Padding(
          padding: const EdgeInsets.all(10),
          child: Row(children: [
            Container(
              width: width,
              height: videos ? width * 9 / 16 : width,
              decoration: BoxDecoration(color: brand.paperDeep, borderRadius: BorderRadius.circular(videos ? 12 : 10)),
            ),
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
  });
}
