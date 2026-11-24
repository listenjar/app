// The ListenJar section of the app: the signed-in listener's own ListenJar
// feeds (account.dart), what they add to them from YouTube links and
// search, and how each feed syncs from this device (feeds.dart, sync.dart)
// through the ListenJar API (public.yaml) and its oasmith client in
// lib/backend (`moon run desktop:codegen`). A podcast of the listener's own
// opens in place of the list (podcast.dart): its episodes and artwork, with
// the link field adding videos to it. Signed out, it says what an account
// adds to the free player. The shell (shell.dart) shows it beside the
// player's own sections.
import 'dart:async';
import 'dart:io';

import 'package:cancellation_token/cancellation_token.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/link.dart';
import 'package:url_launcher/url_launcher.dart';

import 'account.dart';
import 'backend/api.dart';
import 'feeds.dart';
import 'links.dart';
import 'marks.dart';
import 'plans.dart';
import 'podcast.dart';
import 'podcast_apps.dart';
import 'shell.dart' show PageBody, windowCommand;
import 'ui.dart' show Services, pageTitle;
import 'sync.dart';
import 'theme.dart' as brand;
import 'youtube.dart' show SearchResult, SourceRefKind, YouTubeService;

/// How long typing pauses before the link field searches YouTube.
const _searchDelay = Duration(milliseconds: 300);

class CloudPage extends StatefulWidget {
  const CloudPage({super.key, required this.youtube, required this.account, required this.feeds});
  final YouTubeService youtube;
  final Account account;
  final Feeds feeds;

  @override
  State<CloudPage> createState() => _CloudPageState();
}

class _CloudPageState extends State<CloudPage> {
  Account get _account => widget.account;
  Feeds get _feeds => widget.feeds;
  late final _shown = Listenable.merge([_account, _feeds]);

  /// Cancels the window's own calls when it goes away; the feeds' go on.
  final _life = CancellationToken();

  /// The window's one scroll view; the scrollbar needs it on desktop, where
  /// no PrimaryScrollController is attached.
  final _scroll = ScrollController();

  /// Coming back to the window, often from checkout in the browser: the
  /// plan and storage may have changed.
  late final _lifecycle = AppLifecycleListener(onResume: () => unawaited(_account.refresh()));

  /// The podcast apps this device can open feeds in, asked once.
  final _podcastApps = installedPodcastApps();

  /// The link field in the top bar (⌘L), and the link being added.
  final _link = TextEditingController();
  final _linkFocus = FocusNode();
  bool _linkHover = false;
  CancellationToken? _adding;
  Object? _addError;

  /// Video feeds whose video is being added to a podcast of the listener's own.
  final _copying = <String>{};

  /// The podcast of the listener's own open in place of the list, while it
  /// is still theirs.
  String? _openId;
  Feed? get _open => _feeds.feeds.where((f) => f.id == _openId).firstOrNull;

  void _openPodcast(Feed feed) {
    setState(() => _openId = feed.id);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _back() {
    if (_openId == null) return;
    setState(() => _openId = null);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  /// Anything else typed there searches YouTube: the search waiting or in
  /// flight, then the query last answered, what it found or why it failed.
  /// Answers are kept, so editing back to a query asks YouTube once.
  CancellationToken? _searching;
  String? _answered;
  int _found = 0;
  Object? _searchError;
  final _searches = <String, List<SearchResult>>{};

  @override
  void initState() {
    super.initState();
    _shown.addListener(_rebuild);
    _link.addListener(() => setState(() => _addError = null));
    _linkFocus.addListener(_rebuild);
    _lifecycle;
  }

  @override
  void dispose() {
    _shown.removeListener(_rebuild);
    _lifecycle.dispose();
    _life.cancel();
    _link.dispose();
    _linkFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  Future<void> _startSignIn() => _account.signIn((url) async {
    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) throw StateError('open the browser');
  });

  /// Looks the pasted link, or the search result's, up on YouTube and adds
  /// it; the sync takes it from there.
  Future<void> _add([String? input]) async {
    final link = input ?? _link.text;
    if (_account.user == null || _adding != null || parseYouTubeLink(link) == null) return;
    _searching?.cancel();
    final token = CancellationToken();
    setState(() {
      _adding = token;
      _addError = null;
    });
    Object? error;
    try {
      await _feeds.add(link, _life.merge(token));
      if (!mounted) return;
      // The new feed is in the list.
      _back();
      _link.clear();
      _linkFocus.requestFocus();
    } on CancelledException {
      if (_life.isCancelled || token.isCancelled) return;
      error = 'It took too long.';
    } catch (e) {
      error = e;
    } finally {
      if (mounted) setState(() => _adding = null);
    }
    if (mounted) setState(() => _addError = error);
  }

  /// Adds the pasted video, or the video of [from], a YouTube video feed,
  /// to [feed], a podcast of the listener's own, or to a new one they name.
  /// Its audio is stored once for both, so the plan's storage stays the same.
  Future<void> _addTo(Feed? feed, {Feed? from, String? link}) async {
    link ??= from?.source?.url ?? _link.text;
    if (_account.user == null || _adding != null || parseYouTubeLink(link)?.kind != SourceKind.video) return;
    if (from != null && _copying.contains(from.id)) return;
    final target = feed ?? await _newPodcast();
    if (target == null || !mounted) return;
    final token = CancellationToken();
    setState(() {
      if (from == null) {
        _adding = token;
      } else {
        _copying.add(from.id);
      }
      _addError = null;
    });
    Object? error;
    try {
      await _feeds.addVideo(target, link, _life.merge(token));
      if (!mounted) return;
      if (from == null) {
        _link.clear();
        _linkFocus.requestFocus();
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            from == null ? 'Added to “${target.title}”. It uploads from this computer.' : 'Added to “${target.title}”.',
          ),
        ),
      );
    } on CancelledException {
      if (_life.isCancelled || token.isCancelled) return;
      error = 'It took too long.';
    } catch (e) {
      error = e;
    } finally {
      if (mounted) {
        setState(() {
          if (from == null) {
            _adding = null;
          } else {
            _copying.remove(from.id);
          }
        });
      }
    }
    if (mounted) setState(() => _addError = error);
  }

  /// Names and makes a podcast of the listener's own.
  Future<Feed?> _newPodcast() async {
    final title = await askPodcastTitle(context);
    if (title == null || !mounted) return null;
    try {
      return await _feeds.create(title);
    } catch (e) {
      if (mounted) setState(() => _addError = e);
      return null;
    }
  }

  void _plans([String title = 'Keep what you add']) => unawaited(showPlans(context, title: title));

  void _makeRoom() => unawaited(showMakeRoom(context, account: _account, feeds: _feeds, onRemove: _remove));

  /// The link field's suggestions: what YouTube's search finds for the
  /// typed text, once typing pauses. Links and URLs don't search.
  Future<Iterable<SearchResult>> _search(TextEditingValue value) async {
    final query = value.text.trim();
    _searching?.cancel();
    _searching = null;
    if (!_isQuery(query)) return const [];
    if (_searches[query] case final results?) {
      _answer(query, results, null);
      return results;
    }
    final token = CancellationToken();
    setState(() => _searching = token);
    try {
      await Future<void>.delayed(_searchDelay).asCancellable(token);
      final merged = _life.merge(token).merge(TimeoutCancellationToken(callTimeout));
      final results = await (await widget.youtube.session(merged)).search(query, merged);
      if (_searches.length >= 50) _searches.remove(_searches.keys.first);
      _searches[query] = results;
      _answer(query, results, null);
      return results;
    } on CancelledException {
      // Typed on, or the window went away; else it timed out.
      if (!token.isCancelled && !_life.isCancelled) _answer(query, const [], 'It took too long.');
      return const [];
    } catch (e) {
      _answer(query, const [], e);
      return const [];
    } finally {
      if (_searching == token && mounted) setState(() => _searching = null);
    }
  }

  void _answer(String query, List<SearchResult> results, Object? error) {
    if (!mounted) return;
    setState(() {
      _answered = query;
      _found = results.length;
      _searchError = error;
    });
  }

  Future<void> _copyFeedLink(Feed feed) async {
    final url = feed.rssUrl;
    if (url == null) return;
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Feed link copied. Add it to your podcast app as a podcast by URL.')),
    );
  }

  /// What removing [feed] does, in its own terms: what leaves the podcast
  /// app, and that its audio goes. Audio is shared, so when another feed of
  /// the listener's may have the same videos, it says those keep theirs.
  String _removeConsequence(Feed feed) {
    final shared = _feeds.feeds.any((f) => f.id != feed.id);
    return switch (feed.source?.kind) {
      SourceKind.video => [
        'It leaves your podcast app, and its audio is deleted.',
        if (shared) 'If another podcast of yours has this video, it stays there.',
      ],
      SourceKind.playlist || SourceKind.channel => [
        'ListenJar stops following it. Its episodes leave your podcast app, and their audio is deleted.',
        if (shared) 'Videos another podcast of yours also has stay there.',
      ],
      null => [
        'Its episodes leave your podcast app, and their audio is deleted.',
        if (shared) 'Videos another podcast of yours also has stay there.',
      ],
    }.join(' ');
  }

  /// Asks, then removes the feed and everything uploaded to it.
  Future<void> _remove(Feed feed) async {
    final text = Theme.of(context).textTheme;
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: brand.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(brand.radiusSheet)),
        title: Text('Remove “${feed.title}”?', style: text.titleLarge),
        content: Text(_removeConsequence(feed), style: text.bodyMedium!.copyWith(color: brand.fgSoft)),
        actions: [
          TextButton(
            style: brand.button(brand.Tone.quiet, brand.ButtonSize.sm),
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep it'),
          ),
          TextButton(
            style: brand.button(brand.Tone.ink, brand.ButtonSize.sm),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (sure == true && mounted) await _feeds.remove(feed);
  }

  // The section's own bar holds the link field and the account; the
  // listener's feeds fill the page below it.
  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final width = MediaQuery.sizeOf(context).width;
    final gutter = (width * 0.04).clamp(16.0, 40.0);
    if (_account.user == null) {
      return PageBody(maxWidth: 600, children: [
        pageTitle(context, 'ListenJar Cloud'),
        const SizedBox(height: 20),
        brand.panel(padding: 28, child: _signInPanel(text)),
      ]);
    }
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.bracketLeft, meta: true): _back,
      },
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _topBar(text),
        Expanded(
          child: Scrollbar(
            controller: _scroll,
            child: SingleChildScrollView(
              controller: _scroll,
              padding: EdgeInsets.fromLTRB(gutter, 20, gutter, 48),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 880),
                  child: AnimatedSwitcher(
                        duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 220),
                        switchInCurve: brand.easeOutExpo,
                        switchOutCurve: const Threshold(0),
                        transitionBuilder: (child, animation) => FadeTransition(
                          opacity: animation,
                          child: SlideTransition(
                            position: Tween(begin: const Offset(0, 0.012), end: Offset.zero).animate(animation),
                            child: child,
                          ),
                        ),
                        layoutBuilder: (current, _) => current ?? const SizedBox.shrink(),
                        child: switch (_open) {
                          final feed? => KeyedSubtree(key: ValueKey(feed.id), child: _podcast(text, feed)),
                          null => KeyedSubtree(key: const ValueKey('list'), child: _feedsList(text)),
                        },
                      ),
                ),
              ),
            ),
          ),
        ),
      ]),
    );
  }

  /// The section's bar: back from an open podcast, the link field, the
  /// account.
  Widget _topBar(TextTheme text) {
    final mac = defaultTargetPlatform == TargetPlatform.macOS;
    final wide = MediaQuery.sizeOf(context).width >= 760;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => windowCommand('startDrag'),
      child: Container(
        height: mac && wide ? 60 : 56,
        padding: EdgeInsets.only(left: 14, right: 14, top: mac && wide ? 8 : 0),
        decoration: const BoxDecoration(
          color: brand.paper,
          border: Border(bottom: BorderSide(color: brand.line)),
        ),
        child: Row(children: [
          if (_open != null) ...[
            Tooltip(
              message: 'Back to your feeds (⌘[)',
              waitDuration: const Duration(milliseconds: 500),
              child: TextButton.icon(
                style: brand.button(brand.Tone.quiet, brand.ButtonSize.sm).copyWith(
                  minimumSize: const WidgetStatePropertyAll(Size(0, 32)),
                  padding: const WidgetStatePropertyAll(EdgeInsets.only(left: 6, right: 12)),
                  backgroundColor: WidgetStateProperty.fromMap({
                    WidgetState.hovered: brand.paperDeep,
                    WidgetState.any: const Color(0x00000000),
                  }),
                ),
                onPressed: _back,
                icon: const Icon(Icons.chevron_left_rounded, size: 20),
                label: const Text('Feeds'),
              ),
            ),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: _linkField(text),
              ),
            ),
          ),
          if (_account.user case final user?) ...[const SizedBox(width: 12), _accountMenu(text, user)],
        ]),
      ),
    );
  }

  /// Search YouTube or paste a link: says what it recognises as you type,
  /// and lists what search finds under it (arrows and Return, or a click,
  /// add one). A compact address field like a browser's: recessed paper at
  /// rest, a shade deeper under the pointer, white with the accent ring
  /// while typing.
  Widget _linkField(TextTheme text) => RawAutocomplete<SearchResult>(
    textEditingController: _link,
    focusNode: _linkFocus,
    displayStringForOption: (result) => result.title,
    optionsBuilder: _search,
    // An open podcast takes a video; anything else is a feed of its own.
    onSelected: (result) => switch (_open) {
      final open? when result.kind == SourceRefKind.video => _addTo(open, link: result.url),
      _ => _add(result.url),
    },
    fieldViewBuilder: (context, _, _, submit) => _linkInput(text, submit),
    optionsViewBuilder: (context, select, options) => _SearchResults(results: options.toList(), onSelected: select),
  );

  Widget _linkInput(TextTheme text, VoidCallback submit) {
    final typed = _link.text.trim();
    final link = parseYouTubeLink(typed);
    final adding = _adding != null;
    final searching = _searching != null;
    final answered = !searching && _isQuery(typed) && _answered == typed;
    final focused = _linkFocus.hasFocus;
    final hint = text.bodySmall!.copyWith(color: brand.fgSoft);
    // Even leading keeps the glyphs (and the caret) on the icon's centre line;
    // proportional leading drops SF Pro a few pixels low.
    final input = text.bodySmall!.copyWith(
      color: brand.fg,
      height: 1.2,
      leadingDistribution: TextLeadingDistribution.even,
    );
    final open = _open;
    final trailing = switch ((adding, link)) {
      (true, _) => Text('Looking it up…', style: hint),
      (_, final l?) when l.kind == SourceKind.video && open != null => TextButton(
        style: _chip(text),
        onPressed: () => _addTo(open),
        child: const Text('Add to this podcast'),
      ),
      (_, final l?) when l.kind == SourceKind.video && _account.user?.plan == Plan.paid => _addSplit(text, l),
      (_, final l?) => TextButton(
        style: _chip(text),
        onPressed: _add,
        child: Text('Add ${kindLabel(l.kind).replaceFirst('YouTube ', '')}'),
      ),
      _ when _looksLikeUrl(typed) => Text('Not a YouTube link', style: hint.copyWith(color: brand.danger)),
      _ when answered && _searchError != null => Tooltip(
        message: '$_searchError',
        child: Text('Couldn’t search YouTube', style: hint.copyWith(color: brand.danger)),
      ),
      _ when answered && _found == 0 => Text('Nothing found', style: hint),
      _ when focused || typed.isNotEmpty => null,
      _ => Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          color: brand.paper,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: brand.line),
        ),
        child: Text('⌘L', style: text.labelSmall!.copyWith(color: brand.fgSoft, fontSize: 11, height: 1.4)),
      ),
    };
    final icon = typed.isNotEmpty && link == null && !_looksLikeUrl(typed) ? Icons.search_rounded : Icons.link_rounded;
    return MouseRegion(
      cursor: SystemMouseCursors.text,
      onEnter: (_) => setState(() => _linkHover = true),
      onExit: (_) => setState(() => _linkHover = false),
      child: GestureDetector(
        // Clicking the padding focuses the field, not the window drag.
        onTap: _linkFocus.requestFocus,
        onPanStart: (_) {},
        child: AnimatedContainer(
          duration: brand.quick,
          curve: brand.easeOutExpo,
          height: 34,
          padding: const EdgeInsets.only(left: 11, right: 4),
          decoration: BoxDecoration(
            color: focused ? brand.white : (_linkHover ? brand.paperDeep : const Color(0xFFEFEDE8)),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: focused ? brand.accent.withValues(alpha: 0.6) : brand.line,
              width: focused ? 1.5 : 1,
            ),
            boxShadow: focused ? const [BoxShadow(color: Color(0x1F5165EE), blurRadius: 0, spreadRadius: 3)] : null,
          ),
          child: Row(children: [
            SizedBox.square(
              dimension: 16,
              child: adding || searching
                ? const Padding(
                    padding: EdgeInsets.all(1.5),
                    child: CircularProgressIndicator(strokeWidth: 1.75, color: brand.accent),
                  )
                : Icon(icon, size: 16, color: focused ? brand.accent : brand.fgFaint),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _link,
                focusNode: _linkFocus,
                enabled: !adding,
                // A link adds itself; typed words add the highlighted result.
                onSubmitted: (_) => switch ((link, open)) {
                  (final l?, final o?) when l.kind == SourceKind.video => _addTo(o),
                  (_?, _) => _add(),
                  _ => submit(),
                },
                style: input,
                strutStyle: StrutStyle.fromTextStyle(input, forceStrutHeight: true),
                cursorColor: brand.accent,
                cursorHeight: 16,
                cursorWidth: 1.5,
                cursorRadius: const Radius.circular(1),
                decoration: InputDecoration(
                  isCollapsed: true,
                  border: InputBorder.none,
                  // Clear of the caret, which sits at the start of the empty field.
                  hint: Padding(
                    padding: const EdgeInsets.only(left: 3),
                    child: Text(
                      open == null ? 'Search YouTube or paste a link' : 'Search YouTube or paste a video to add it here',
                      style: input.copyWith(color: brand.fgFaint),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: 8), trailing],
            const SizedBox(width: 4),
          ]),
        ),
      ),
    );
  }

  /// The small accent button inside the link field.
  ButtonStyle _chip(TextTheme text, [BorderRadius? radius]) => brand.button(brand.Tone.accent, brand.ButtonSize.sm).copyWith(
    minimumSize: const WidgetStatePropertyAll(Size(0, 26)),
    padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 12)),
    shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: radius ?? BorderRadius.circular(7))),
    textStyle: WidgetStatePropertyAll(text.labelLarge!.copyWith(fontSize: 13)),
  );

  /// A video, for a listener with a plan: its own podcast (Return), or the
  /// chevron's menu of their own podcasts to add it to.
  Widget _addSplit(TextTheme text, YouTubeLink link) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      TextButton(
        style: _chip(text, const BorderRadius.horizontal(left: Radius.circular(7))),
        onPressed: _add,
        child: const Text('Add video'),
      ),
      const SizedBox(width: 1),
      MenuAnchor(
        alignmentOffset: const Offset(0, 8),
        style: _menuStyle,
        menuChildren: _ownPodcasts(text, _addTo),
        builder: (context, menu, _) => Tooltip(
          message: 'Add to a podcast of yours',
          waitDuration: const Duration(milliseconds: 400),
          child: TextButton(
            style: _chip(text, const BorderRadius.horizontal(right: Radius.circular(7))).copyWith(
              padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 5)),
            ),
            onPressed: () => menu.isOpen ? menu.close() : menu.open(),
            child: const Icon(Icons.expand_more_rounded, size: 17),
          ),
        ),
      ),
    ]);
  }

  /// The menu of the listener's own podcasts to add a video to, then a new one.
  List<Widget> _ownPodcasts(TextTheme text, void Function(Feed?) pick) {
    final own = _feeds.own;
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
        child: Text('Add to a podcast of yours', style: text.bodySmall!.copyWith(color: brand.fgSoft, fontSize: 12.5)),
      ),
      for (final feed in own)
        MenuItemButton(
          leadingIcon: const Icon(Icons.podcasts_rounded, size: 18, color: brand.fgSoft),
          onPressed: () => pick(feed),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 260),
            child: Text(feed.title, style: text.bodyMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ),
      if (own.isNotEmpty) const Divider(height: 9, color: brand.line),
      MenuItemButton(
        leadingIcon: const Icon(Icons.add_rounded, size: 18, color: brand.fgSoft),
        onPressed: () => pick(null),
        child: Text('New podcast…', style: text.bodyMedium),
      ),
    ];
  }

  /// A YouTube video feed's video, for a listener with a plan: added to a
  /// podcast of theirs from the row, without pasting its link again.
  Widget _addToPodcast(TextTheme text, Feed feed) {
    if (_copying.contains(feed.id)) {
      return const SizedBox.square(
        dimension: 40,
        child: Center(
          child: SizedBox.square(
            dimension: 15,
            child: CircularProgressIndicator(strokeWidth: 1.75, color: brand.accent),
          ),
        ),
      );
    }
    return MenuAnchor(
      alignmentOffset: const Offset(0, 6),
      style: _menuStyle,
      menuChildren: _ownPodcasts(text, (target) => _addTo(target, from: feed)),
      builder: (context, menu, _) => IconButton(
        tooltip: 'Add to a podcast of yours',
        visualDensity: VisualDensity.compact,
        onPressed: () => menu.isOpen ? menu.close() : menu.open(),
        icon: const Icon(Icons.playlist_add_rounded, size: 19, color: brand.fgSoft),
      ),
    );
  }

  static final _menuStyle = MenuStyle(
    backgroundColor: const WidgetStatePropertyAll(brand.white),
    shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
    padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 6)),
  );

  /// The listener's initial; it opens who is signed in, syncing and signing out.
  Widget _accountMenu(TextTheme text, User user) => MenuAnchor(
    alignmentOffset: const Offset(0, 6),
    style: MenuStyle(
      backgroundColor: const WidgetStatePropertyAll(brand.white),
      shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
      padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 6)),
    ),
    menuChildren: [
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(user.email, style: text.bodySmall!.copyWith(color: brand.fgSoft)),
          const SizedBox(height: 2),
          Text(
            [
              planName(user),
              if (user.storageLimitBytes case final limit?) '${formatBytes(user.storageUsedBytes ?? 0)} of ${formatBytes(limit)}',
            ].join(' · '),
            style: text.bodySmall!.copyWith(color: brand.fg, fontWeight: FontWeight.w600),
          ),
        ]),
      ),
      const Divider(height: 1, color: brand.line),
      if (user.plan == Plan.free)
        MenuItemButton(
          leadingIcon: const Icon(Icons.workspace_premium_outlined, size: 18, color: brand.fgSoft),
          onPressed: _plans,
          child: Text('See plans…', style: text.bodyMedium),
        )
      else
        MenuItemButton(
          leadingIcon: const Icon(Icons.open_in_new_rounded, size: 18, color: brand.fgSoft),
          onPressed: () => openInBrowser(context, billingUrl),
          child: Text('Manage plan', style: text.bodyMedium),
        ),
      MenuItemButton(
        leadingIcon: const Icon(Icons.sync_rounded, size: 18, color: brand.fgSoft),
        onPressed: _feeds.loading ? null : _feeds.syncNow,
        child: Text('Sync now', style: text.bodyMedium),
      ),
      MenuItemButton(
        leadingIcon: const Icon(Icons.logout_rounded, size: 18, color: brand.fgSoft),
        onPressed: _account.signOut,
        child: Text('Sign out', style: text.bodyMedium),
      ),
    ],
    builder: (context, menu, _) => Tooltip(
      message: user.email,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () {
          if (menu.isOpen) return menu.close();
          unawaited(_account.refresh());
          menu.open();
        },
        child: _avatar(text, user),
      ),
    ),
  );

  /// The Google account's picture, or the listener's initial without one.
  Widget _avatar(TextTheme text, User user) {
    const size = 30.0;
    final name = user.name.isEmpty ? user.email : user.name;
    final initial = Container(
      alignment: Alignment.center,
      color: brand.accent,
      child: Text(
        name.isEmpty ? '?' : name.characters.first.toUpperCase(),
        style: text.labelLarge!.copyWith(color: brand.white, height: 1),
      ),
    );
    return Container(
      width: size,
      height: size,
      foregroundDecoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: brand.line)),
      child: ClipOval(
        child: switch (user.pictureUrl) {
          null => initial,
          final url => Image.network(
            url,
            fit: BoxFit.cover,
            cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).round(),
            errorBuilder: (_, _, _) => initial,
            frameBuilder: (_, child, frame, sync) => sync || frame != null ? child : initial,
          ),
        },
      ),
    );
  }

  /// How to sign in, while nobody is.
  Widget _signInPanel(TextTheme text) {
    final (title, body, action) = switch (_account) {
      Account(restoring: true) => (null, null, null),
      Account(signingIn: final token?) => (
        'Finish in your browser',
        'Allow the app on the page that opened. It comes back here when you do.',
        TextButton(style: brand.button(brand.Tone.quiet), onPressed: token.cancel, child: const Text('Cancel')),
      ),
      _ => (
        'Your YouTube, as podcasts',
        'Follow YouTube playlists and channels, or gather any videos into a podcast of your own. '
          'ListenJar keeps them as podcast feeds in the cloud, so new episodes reach this app and any podcast app you use. '
          'This device fetches them from YouTube and uploads them; the plans pay for the storage.',
        brand.accentShadow(
          enabled: true,
          child: TextButton.icon(
            style: brand.button(brand.Tone.accent),
            onPressed: _startSignIn,
            iconAlignment: IconAlignment.end,
            icon: const Arrow(),
            label: const Text('Sign in with your browser'),
          ),
        ),
      ),
    };
    if (title == null) return const _Skeleton(lines: 2);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: text.titleLarge),
        const SizedBox(height: 8),
        Text(body!, style: text.bodyMedium!.copyWith(color: brand.fgSoft)),
        if (_account.authError case final error?) ...[
          const SizedBox(height: 16),
          _problem(text, _failure('Couldn’t sign in', error, other: 'Try again.'), error),
        ],
        const SizedBox(height: 22),
        Wrap(spacing: 10, runSpacing: 10, children: [
          ?action,
          if (!_account.restoring && _account.signingIn == null)
            TextButton(style: brand.button(brand.Tone.quiet), onPressed: () => _plans('ListenJar Cloud plans'), child: const Text('See plans')),
        ]),
      ],
    );
  }

  /// What went wrong adding a link, and a full plan, above the list or an
  /// open podcast.
  List<Widget> _problems(TextTheme text) => [
      if (_addError case PlanLimit(storageFull: false)) ...[
        Notice(
          title: 'Playlists and channels come with a plan',
          body: 'On Free, ListenJar takes single videos for a day. A plan follows a playlist or a channel '
            'and adds its new videos as episodes, and keeps them.',
          actions: [
            TextButton(
              style: whiteButton(),
              onPressed: () => setState(() => _addError = null),
              child: const Text('Not now'),
            ),
            brand.accentShadow(
              enabled: true,
              child: TextButton(
                style: brand.button(brand.Tone.accent, brand.ButtonSize.sm),
                onPressed: () => _plans('Follow playlists and channels'),
                child: const Text('See plans'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
      ] else if (_addError case PlanLimit(storageFull: true)) ...[
        _storageFull(),
        const SizedBox(height: 12),
      ] else if (_addError case final error?) ...[
        _problem(
          text,
          _failure('Couldn’t add that link', error, other: 'Check it plays on YouTube, then try again.'),
          error,
        ),
        const SizedBox(height: 12),
      ],
      if (_feeds.storageFull && _addError is! PlanLimit) ...[
        _storageFull(),
        const SizedBox(height: 12),
      ],
  ];

  /// An open podcast of the listener's own: problems, then its page.
  Widget _podcast(TextTheme text, Feed feed) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ..._problems(text),
      const SizedBox(height: 8),
      PodcastPage(
        feed: feed,
        feeds: _feeds,
        listenIn: _listenIn(text, feed, feed.rssUrl),
        onRemove: () => _remove(feed),
      ),
    ],
  );

  /// The listener's feeds: problems first, then each feed, or how to start.
  Widget _feedsList(TextTheme text) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (_account.user case final user? when _feeds.feeds.isNotEmpty || user.plan == Plan.paid)
        PlanBar(user: user, onPlans: _plans, onNewPodcast: () => unawaited(_newPodcast())),
      ..._problems(text),
      if (_feeds.feedsError case final error?)
        _problem(text, _failure('Couldn’t load your podcasts', error, other: 'Sync again.'), error)
      else if (_feeds.loading && _feeds.feeds.isEmpty)
        const _Skeleton(lines: 3, rows: true)
      else if (_feeds.feeds.isEmpty)
        _emptyFeeds(text)
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
              for (final (i, feed) in _feeds.feeds.indexed) ...[
                if (i > 0) const Divider(height: 1, thickness: 1, indent: 84, color: brand.line),
                // A podcast of the listener's own opens its episodes and artwork.
                feed.source == null
                  ? _OpenableRow(
                      key: ValueKey(feed.id),
                      label: 'Open “${feed.title}”',
                      onOpen: () => _openPodcast(feed),
                      child: _feedRow(text, feed),
                    )
                  : _feedRow(text, feed),
              ],
            ]),
          ),
        ),
    ],
  );

  /// The plan's storage is full and episodes wait: make room, or move to
  /// a bigger plan.
  Widget _storageFull() {
    final user = _account.user!;
    final waiting = _feeds.waitingForRoom;
    final bigger = biggerPlan(user);
    return Notice(
      danger: true,
      title: switch (user.storageLimitBytes) {
        final limit? => 'Your ${formatBytes(limit)} is full',
        null => 'Your storage is full',
      },
      body: [
        if (waiting > 0) waiting == 1 ? '1 episode is waiting to upload.' : '$waiting episodes are waiting to upload.',
        'Remove podcasts or episodes you’ve heard${bigger == null ? '' : ', or move to a bigger plan'}, and they upload by themselves.',
      ].join(' '),
      actions: [
        if (bigger != null)
          TextButton(
            style: brand.button(brand.Tone.quiet, brand.ButtonSize.sm),
            onPressed: () => openInBrowser(context, billingUrl),
            child: Text('Move to ${bigger.name.replaceFirst('ListenJar ', '')}'),
          ),
        TextButton(
          style: brand.button(brand.Tone.ink, brand.ButtonSize.sm),
          onPressed: _makeRoom,
          child: const Text('Make room'),
        ),
      ],
    );
  }

  /// A feed: its artwork, its title, and what syncing is doing with it.
  Widget _feedRow(TextTheme text, Feed feed) {
    final sync = _feeds.statusOf(feed);
    final (status, failed) = _statusLine(feed, sync);
    final expiry = removedIn(feed, DateTime.now());
    final phase = sync?.phase ?? FeedPhase.waiting;
    final dot = switch (phase) {
      FeedPhase.failed => brand.danger,
      FeedPhase.upToDate => const Color(0xFF2F9E6E),
      FeedPhase.syncing || FeedPhase.scanning => brand.accent,
      FeedPhase.waiting => brand.fgFaint,
    };
    final fraction = phase == FeedPhase.syncing ? sync?.fraction : null;
    return Padding(
      key: ValueKey(feed.id),
      padding: const EdgeInsets.fromLTRB(16, 14, 10, 14),
      child: Row(children: [
        _artwork(feed.imageUrl),
        const SizedBox(width: 16),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _FeedTitle(title: feed.title, url: feed.source?.url, style: text.titleMedium!.copyWith(fontSize: 15)),
            const SizedBox(height: 4),
            Row(children: [
              Container(width: 7, height: 7, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
              const SizedBox(width: 7),
              Flexible(
                child: Text(
                  [
                    switch (feed.source) {
                      final source? => kindLabel(source.kind),
                      null => 'Podcast of your own',
                    },
                    status,
                  ].join(' · '),
                  style: text.bodySmall!.copyWith(color: failed ? brand.danger : brand.fgSoft),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (expiry != null)
                Tooltip(
                  message: removedAt(feed),
                  child: Text(' · $expiry', style: text.bodySmall!.copyWith(color: brand.fgSoft), maxLines: 1),
                ),
            ]),
            if (fraction != null) ...[
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: fraction,
                  minHeight: 3,
                  color: brand.accent,
                  backgroundColor: brand.mist,
                ),
              ),
            ],
          ]),
        ),
        const SizedBox(width: 16),
        if (feed.source?.kind == SourceKind.video && _account.user?.plan == Plan.paid) ...[
          _addToPodcast(text, feed),
          const SizedBox(width: 6),
        ],
        _listenIn(text, feed, feed.rssUrl),
        const SizedBox(width: 2),
        IconButton(
          tooltip: 'Remove',
          visualDensity: VisualDensity.compact,
          onPressed: () => _remove(feed),
          icon: const Icon(Icons.close_rounded, size: 17, color: brand.fgFaint),
        ),
      ]),
    );
  }

  /// A feed's artwork, square like a podcast's; a plain tile without one.
  Widget _artwork(String? url) {
    const size = 52.0;
    final placeholder = Container(
      color: brand.paper,
      alignment: Alignment.center,
      child: const Icon(Icons.podcasts_rounded, size: 22, color: brand.fgSoft),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox.square(
        dimension: size,
        child: url == null
          ? placeholder
          : Image.network(
              url,
              fit: BoxFit.cover,
              cacheHeight: (size * MediaQuery.devicePixelRatioOf(context)).round(),
              errorBuilder: (_, _, _) => placeholder,
              frameBuilder: (_, child, frame, sync) => sync || frame != null ? child : placeholder,
            ),
      ),
    );
  }

  /// A podcast app's icon in the menu, rounded like an app icon.
  Widget _menuIcon(String asset) => Padding(
    padding: const EdgeInsetsDirectional.only(end: 4),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image.asset(asset, width: 24, height: 24, filterQuality: FilterQuality.medium),
    ),
  );

  /// "Listen in…": the podcast apps on this device, then copying the link.
  /// Until the feed's first episode is uploaded it has no RSS, so the button
  /// waits, disabled, while the status line shows the sync.
  Widget _listenIn(TextTheme text, Feed feed, String? rss) => rss == null
    ? Tooltip(
        message: 'Ready once the first episode is uploaded',
        child: TextButton(
          // Deep paper and faint text: brand.button's disabled look.
          style: brand.button(brand.Tone.quiet, brand.ButtonSize.sm),
          onPressed: null,
          child: const Text('Listen in…'),
        ),
      )
    : FutureBuilder(
    future: _podcastApps,
    builder: (context, snapshot) => MenuAnchor(
      style: MenuStyle(
        backgroundColor: const WidgetStatePropertyAll(brand.white),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 6)),
      ),
      menuChildren: [
        for (final app in snapshot.data ?? const <PodcastApp>[])
          MenuItemButton(
            leadingIcon: _menuIcon(app.icon),
            onPressed: () => openInPodcastApp(app, rss),
            child: Text(app.web ? '${app.title} (web)' : app.title, style: text.bodyMedium),
          ),
        MenuItemButton(
          leadingIcon: _menuIcon(podcastAppIcon('rss')),
          onPressed: () => _copyFeedLink(feed),
          child: Text('Copy feed link', style: text.bodyMedium),
        ),
      ],
      builder: (context, menu, _) => TextButton(
        style: brand.button(brand.Tone.quiet, brand.ButtonSize.sm),
        onPressed: () => menu.isOpen ? menu.close() : menu.open(),
        child: const Text('Listen in…'),
      ),
    ),
  );

  /// What syncing is doing with a feed, in a line, and whether it failed.
  (String, bool) _statusLine(Feed feed, FeedSync? sync) {
    String episodes(int n) => n == 1 ? '1 episode' : '$n episodes';
    switch (sync) {
      case FeedSync(phase: FeedPhase.failed, error: PlanLimit(storageFull: true), :final waiting):
        return (waiting > 0 ? 'Storage full · $waiting waiting to upload' : 'Storage full', true);
      case FeedSync(phase: FeedPhase.failed, error: PlanLimit()):
        return ('Paused until you have a plan', true);
      case FeedSync(phase: FeedPhase.upToDate, episodes: 0) when feed.source == null:
        return ('No episodes yet. Paste a video link above to add one', false);
    }
    return switch (sync?.phase) {
      null || FeedPhase.waiting => ('Waiting to sync', false),
      FeedPhase.scanning => ('Checking YouTube…', false),
      FeedPhase.syncing => (
        [
          if (sync!.current case final title?)
            '${sync.stage ?? 'Syncing'} “$title”${sync.fraction == null ? '' : ' ${(sync.fraction! * 100).floor()}%'}',
          '${sync.queued} to go',
        ].join(' · '),
        false,
      ),
      FeedPhase.upToDate => (
        [
          episodes(sync!.episodes),
          'up to date',
          if (sync.skipped > 0) '${sync.skipped} unavailable',
        ].join(' · '),
        false,
      ),
      FeedPhase.failed => ('Couldn’t sync: ${sync!.error}', true),
    };
  }

  /// Before the first link: what the field above is for.
  Widget _emptyFeeds(TextTheme text) => Padding(
    padding: const EdgeInsets.only(top: 72),
    child: Column(children: [
      logo(height: 34),
      const SizedBox(height: 28),
      Text('Turn YouTube into a podcast', style: text.headlineSmall, textAlign: TextAlign.center),
      const SizedBox(height: 10),
      ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Text(
          'Search for a video, a playlist or a whole channel in the field above, '
          'or paste its link. Its episodes arrive in your podcast app.',
          style: text.bodyMedium!.copyWith(color: brand.fgSoft),
          textAlign: TextAlign.center,
        ),
      ),
    ]),
  );

  /// What went wrong and what to do, with the detail underneath.
  Widget _problem(TextTheme text, String message, Object error) => DecoratedBox(
    decoration: BoxDecoration(color: brand.paper, borderRadius: BorderRadius.circular(brand.radiusSheet)),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(message, style: text.bodyMedium!.copyWith(color: brand.danger)),
        const SizedBox(height: 4),
        SelectableText(
          error is CancelledException ? 'It took too long.' : '$error',
          style: text.bodySmall!.copyWith(color: brand.fgSoft),
        ),
      ]),
    ),
  );
}

/// What failed, said as [what], and what the listener can do about it: check
/// their connection when the network failed, wait when ListenJar's server
/// did, and [other] otherwise.
String _failure(String what, Object error, {required String other}) => switch (error) {
  SocketException() || HttpException() || TimeoutException() || CancelledException() || http.ClientException() =>
    '$what. Check your connection, then try again.',
  ApiStatusException(:final statusCode) when statusCode >= 500 =>
    '$what. Something went wrong on our side, so try again in a minute.',
  _ => '$what. $other',
};

/// Words to search YouTube for: not a link, nor too short to mean much.
bool _isQuery(String text) => text.characters.length >= 2 && parseYouTubeLink(text) == null && !_looksLikeUrl(text);

/// A link, though not one ListenJar takes.
bool _looksLikeUrl(String text) =>
  RegExp(r'^(https?://|www\.)|^[\w-]+(\.[\w-]+)+/', caseSensitive: false).hasMatch(text.trim());

/// What search found, under the link field: a white sheet of rows, the
/// highlighted one (arrows, or the pointer) in mist with what Return does.
final class _SearchResults extends StatelessWidget {
  const _SearchResults({required this.results, required this.onSelected});
  final List<SearchResult> results;
  final AutocompleteOnSelected<SearchResult> onSelected;

  @override
  Widget build(BuildContext context) {
    final highlight = context.dependOnInheritedWidgetOfExactType<AutocompleteHighlightedOption>()?.notifier;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: ConstrainedBox(
        // Six and a half rows: the half says there's more.
        constraints: const BoxConstraints(maxHeight: 6.5 * _SearchRow.height + 12),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: brand.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: const [
              BoxShadow(color: Color(0x14171A38), offset: Offset(0, 2), blurRadius: 6),
              BoxShadow(color: Color(0x33171A38), offset: Offset(0, 18), blurRadius: 40, spreadRadius: -12),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: ListView.builder(
              padding: const EdgeInsets.all(6),
              shrinkWrap: true,
              itemCount: results.length,
              itemExtent: _SearchRow.height,
              itemBuilder: (context, i) => _SearchRow(
                result: results[i],
                highlighted: (highlight?.value ?? 0) == i,
                onHover: () => highlight?.value = i,
                onTap: () => onSelected(results[i]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _SearchRow extends StatelessWidget {
  const _SearchRow({required this.result, required this.highlighted, required this.onHover, required this.onTap});
  static const height = 58.0;
  final SearchResult result;
  final bool highlighted;
  final VoidCallback onHover;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    if (highlighted) {
      // Arrowed past the edge: bring it in, without moving a visible row.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        for (final policy in const [ScrollPositionAlignmentPolicy.keepVisibleAtStart, ScrollPositionAlignmentPolicy.keepVisibleAtEnd]) {
          unawaited(Scrollable.ensureVisible(context, alignmentPolicy: policy));
        }
      });
    }
    final kind = switch (result.kind) {
      SourceRefKind.video => 'Video',
      SourceRefKind.playlist => 'Playlist',
      SourceRefKind.channel => 'Channel',
    };
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => onHover(),
      onHover: (_) {
        if (!highlighted) onHover();
      },
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: brand.quick,
          curve: brand.easeOutExpo,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: highlighted ? brand.mist : brand.white,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(children: [
            _SearchThumbnail(result: result),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    result.title,
                    style: text.bodySmall!.copyWith(color: brand.fg, fontWeight: FontWeight.w600, height: 1.3),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [kind, ...result.details].join(' · '),
                    style: text.bodySmall!.copyWith(color: brand.fgSoft, fontSize: 12.5, height: 1.3),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            AnimatedOpacity(
              opacity: highlighted ? 1 : 0,
              duration: brand.quick,
              child: Padding(
                padding: const EdgeInsets.only(left: 12, right: 4),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text('Add', style: text.labelLarge!.copyWith(color: brand.accent, fontSize: 13)),
                  const SizedBox(width: 4),
                  const Icon(Icons.keyboard_return_rounded, size: 15, color: brand.accent),
                ]),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// A result's picture, in a 64-wide slot so titles line up: a video's
/// frame, a playlist's with the edge of the stack behind it, a channel's
/// round avatar.
final class _SearchThumbnail extends StatelessWidget {
  const _SearchThumbnail({required this.result});
  final SearchResult result;

  @override
  Widget build(BuildContext context) {
    const width = 64.0;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final placeholder = Container(color: brand.paper);
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
      width: width,
      height: 40,
      child: switch (result.kind) {
        SourceRefKind.channel => Center(
          child: ClipOval(child: SizedBox.square(dimension: 36, child: image(36))),
        ),
        SourceRefKind.video => Center(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(width: width, height: 36, child: image(width)),
          ),
        ),
        SourceRefKind.playlist => Stack(children: [
          Positioned(
            left: 5,
            right: 5,
            top: 0,
            height: 8,
            child: DecoratedBox(
              decoration: BoxDecoration(color: brand.paperDeep, borderRadius: BorderRadius.circular(4)),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 36,
            child: ClipRRect(borderRadius: BorderRadius.circular(6), child: image(width)),
          ),
        ]),
      },
    );
  }
}

/// A feed row that opens: a paper tint under the pointer or with keyboard
/// focus, and a chevron saying where it goes. Its own buttons keep their
/// clicks.
final class _OpenableRow extends StatefulWidget {
  const _OpenableRow({super.key, required this.label, required this.onOpen, required this.child});
  final String label;
  final VoidCallback onOpen;
  final Widget child;

  @override
  State<_OpenableRow> createState() => _OpenableRowState();
}

final class _OpenableRowState extends State<_OpenableRow> {
  bool _hover = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: widget.label,
    child: FocusableActionDetector(
      mouseCursor: SystemMouseCursors.click,
      onShowHoverHighlight: (hover) => setState(() => _hover = hover),
      onShowFocusHighlight: (focused) => setState(() => _focused = focused),
      actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => widget.onOpen())},
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onOpen,
        child: AnimatedContainer(
          duration: brand.quick,
          curve: brand.easeOutExpo,
          decoration: BoxDecoration(
            color: _hover || _focused ? const Color(0xFFFAF9F6) : brand.white,
            border: _focused ? Border.all(color: brand.accent, width: 2) : null,
          ),
          child: Row(children: [
            Expanded(child: widget.child),
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: AnimatedSlide(
                offset: Offset(_hover ? 0.15 : 0, 0),
                duration: brand.quick,
                curve: brand.easeOutExpo,
                child: Icon(Icons.chevron_right_rounded, size: 20, color: _hover ? brand.fgSoft : brand.fgFaint),
              ),
            ),
          ]),
        ),
      ),
    ),
  );
}

/// A feed's title, a link to its source on YouTube: underlined under the
/// pointer, like the website's links.
final class _FeedTitle extends StatefulWidget {
  const _FeedTitle({required this.title, required this.url, required this.style});
  final String title;
  final String? url;
  final TextStyle style;

  @override
  State<_FeedTitle> createState() => _FeedTitleState();
}

final class _FeedTitleState extends State<_FeedTitle> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final label = Text(
      widget.title,
      style: widget.style.copyWith(
        decoration: _hover ? TextDecoration.underline : null,
        decorationColor: widget.style.color,
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    final url = Uri.tryParse(widget.url ?? '');
    if (url == null || !url.hasScheme) return label;
    return Tooltip(
      message: url.toString(),
      waitDuration: const Duration(milliseconds: 600),
      child: Link(
        uri: url,
        target: LinkTarget.blank,
        builder: (context, follow) => MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(onTap: follow, child: label),
        ),
      ),
    );
  }
}

/// Placeholder bars that pulse like the website's skeletons, still when the
/// system asks for less motion.
final class _Skeleton extends StatefulWidget {
  const _Skeleton({required this.lines, this.rows = false});
  final int lines;

  /// Feed-row tiles instead of text bars.
  final bool rows;

  @override
  State<_Skeleton> createState() => _SkeletonState();
}

final class _SkeletonState extends State<_Skeleton> with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 700));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _pulse.stop();
      _pulse.value = 0;
    } else if (!_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Loading',
    child: FadeTransition(
      opacity: Tween(begin: 1.0, end: 0.5).animate(CurvedAnimation(parent: _pulse, curve: Curves.easeInOut)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < widget.lines; i++) ...[
            if (i > 0) SizedBox(height: widget.rows ? 8 : 12),
            widget.rows
              ? Container(
                  height: 52,
                  decoration: BoxDecoration(color: brand.paper, borderRadius: BorderRadius.circular(brand.radiusTile)),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(widthFactor: 0.6 - i * 0.12, child: _bar(14)),
                )
              : FractionallySizedBox(widthFactor: i == 0 ? 0.4 : 0.8, child: _bar(i == 0 ? 20 : 14)),
          ],
        ],
      ),
    ),
  );

  Widget _bar(double height) => Container(
    height: height,
    decoration: BoxDecoration(color: brand.paperDeep, borderRadius: BorderRadius.circular(height)),
  );
}

/// The ListenJar section, with the app's own account and feeds.
final class CloudSection extends StatelessWidget {
  const CloudSection({super.key});

  @override
  Widget build(BuildContext context) {
    final s = Services.of(context);
    return CloudPage(youtube: s.youtube, account: s.account, feeds: s.feeds);
  }
}
