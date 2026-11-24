// The window: the player's sections. ListenJar Cloud has none of its own:
// its feeds are shows in the Library (cloud.dart). Wide windows (desktop, tablets) get a sidebar; phones a bottom bar. The
// mini player sits under every section once something is loaded and opens
// Now Playing (now_playing.dart). Each section keeps one stack of pages, so
// a show opened from search comes back with the search behind it.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'cloud.dart';
import 'downloads_page.dart';
import 'home_page.dart';
import 'library_page.dart';
import 'marks.dart';
import 'now_playing.dart';
import 'plans.dart';
import 'queue_page.dart';
import 'search_page.dart';
import 'settings_page.dart';
import 'show_page.dart';
import 'shared_links.dart';
import 'sleeve.dart' show Glass;
import 'theme.dart' as brand;
import 'ui.dart';

enum Section {
  home('Listen Now', Icons.headphones_rounded),
  library('Library', Icons.grid_view_rounded),
  search('Search', Icons.search_rounded),
  queue('Up Next', Icons.queue_music_rounded),
  downloads('Downloads', Icons.download_rounded),
  settings('Settings', Icons.tune_rounded);

  const Section(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// Phones' bottom bar: Downloads and Settings are a tap away in Library.
const _phoneSections = [Section.home, Section.library, Section.search, Section.queue];

/// From this width the sidebar shows.
const wideWidth = 760.0;

/// How far macOS's titlebar reaches into the window: the window's content
/// runs under it, its buttons floating over the top left, and an empty
/// unified toolbar makes it 52pt (macos/Runner/MainFlutterWindow.swift).
const _macTitlebar = 52.0;

/// Gives macOS's titlebar to everything under [child] as top padding, the way
/// a phone's status bar is: every page and sheet clears the window buttons as
/// it clears a status bar, and artwork still runs on under them.
Widget windowInsets(BuildContext context, Widget child) {
  if (defaultTargetPlatform != TargetPlatform.macOS) return child;
  final media = MediaQuery.of(context);
  return MediaQuery(
    data: media.copyWith(
      padding: media.padding.copyWith(top: math.max(media.padding.top, _macTitlebar)),
      viewPadding: media.viewPadding.copyWith(top: math.max(media.viewPadding.top, _macTitlebar)),
    ),
    child: child,
  );
}

final class Shell extends StatefulWidget {
  const Shell({super.key, required this.links});

  /// Links shared to the app, which the shell opens as they come.
  final IncomingLinks links;

  @override
  State<Shell> createState() => _ShellState();
}

final class _ShellState extends State<Shell> implements NavigationTarget {
  Section _section = Section.home;

  /// How tall the floating mini player is on a wide window, so pages can
  /// scroll their last rows clear of it.
  double _miniPlayer = 0;
  final _navigators = {for (final s in Section.values) s: GlobalKey<NavigatorState>()};

  /// What the page in front is, for the sidebar's glass.
  final _showing = Showing();

  /// Search asked for from elsewhere, for the search page to pick up.
  final search = SearchRequest();

  late final _lifecycle = AppLifecycleListener(
    // Often back from checkout in the browser: the plan and storage may
    // have changed too.
    onResume: () {
      final s = Services.of(context);
      unawaited(s.podcasts.refreshAll());
      if (s.account.user != null) unawaited(s.account.refresh());
    },
  );

  late Navigation _navigation;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _navigation = Navigation.of(context)..target = this;
    _lifecycle;
  }

  @override
  void initState() {
    super.initState();
    widget.links.addListener(_linksArrived);
    // Links from the launch wait for the first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) => _linksArrived());
    // The macOS app menu's Settings… (macos/Runner/AppDelegate.swift) closes
    // Now Playing and any dialog over the shell first.
    _menu.setMethodCallHandler((call) async {
      if (call.method != 'settings' || !mounted) return;
      Navigator.of(context).popUntil((route) => route.isFirst);
      openSettings();
    });
  }

  static const _menu = MethodChannel('listenjar/menu');

  bool _opening = false;

  /// Opens shared links one at a time: each may ask a question.
  Future<void> _linksArrived() async {
    if (_opening) return;
    _opening = true;
    try {
      while (mounted) {
        final link = widget.links.next();
        if (link == null) break;
        await openLink(context, link);
      }
    } finally {
      _opening = false;
    }
  }

  @override
  void dispose() {
    widget.links.removeListener(_linksArrived);
    _menu.setMethodCallHandler(null);
    if (_navigation.target == this) _navigation.target = null;
    _lifecycle.dispose();
    search.dispose();
    _showing.dispose();
    super.dispose();
  }

  void _go(Section section) {
    if (section == _section) {
      // A second tap goes back to the section's first page; on Search it
      // also puts the caret in the field, as Apple Podcasts does.
      _navigators[section]!.currentState?.popUntil((r) => r.isFirst);
      if (section == Section.search) search.focus();
      return;
    }
    setState(() => _section = section);
  }

  @override
  void openShow(int podcastId) {
    _push(_section == Section.settings ? Section.library : _section, ShowPage(podcastId: podcastId));
  }

  @override
  void openFeed(String feedId) => _push(Section.library, CloudShowPage(feedId: feedId), fresh: true);

  @override
  void openSettings() => _go(Section.settings);

  /// Shows [section] with [page] on top; [fresh] first goes back to the
  /// section's first page.
  void _push(Section section, Widget page, {bool fresh = false}) {
    setState(() => _section = section);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final navigator = _navigators[section]!.currentState;
      if (fresh) navigator?.popUntil((r) => r.isFirst);
      navigator?.push(_page(page));
    });
  }

  @override
  void openNowPlaying() => unawaited(showNowPlaying(context));

  @override
  void openPlans({String? title}) =>
    unawaited(title == null ? showPlans(context) : showPlans(context, title: title));

  @override
  void openSearch({String? query, bool youtube = false, String? into}) {
    _navigators[Section.search]!.currentState?.popUntil((r) => r.isFirst);
    setState(() => _section = Section.search);
    search.ask(query: query, youtube: youtube, into: into);
  }

  static Route<void> _page(Widget page) => PageRouteBuilder<void>(
    pageBuilder: (_, _, _) => _surface(page),
    transitionDuration: const Duration(milliseconds: 220),
    reverseTransitionDuration: const Duration(milliseconds: 160),
    transitionsBuilder: (context, animation, _, child) {
      if (MediaQuery.disableAnimationsOf(context)) return child;
      final curved = CurvedAnimation(parent: animation, curve: brand.easeOutExpo);
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween(begin: const Offset(0.03, 0), end: Offset.zero).animate(curved),
          child: child,
        ),
      );
    },
  );

  Widget _root(Section section) => switch (section) {
    Section.home => const HomePage(),
    Section.library => const LibraryPage(),
    Section.search => SearchPage(request: search),
    Section.queue => const QueuePage(),
    Section.downloads => const DownloadsPage(),
    Section.settings => const SettingsPage(),
  };

  /// Each section's stack, kept while another shows.
  Widget _stacks() => IndexedStack(
    index: _section.index,
    children: [
      for (final section in Section.values)
        HeroControllerScope.none(
          child: Navigator(
            key: _navigators[section],
            onGenerateRoute: (_) => _page(_root(section)),
          ),
        ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= wideWidth;
    final mac = defaultTargetPlatform == TargetPlatform.macOS;
    final s = Services.of(context);
    return CallbackShortcuts(
      bindings: {
        SingleActivator(LogicalKeyboardKey.keyF, meta: mac, control: !mac): () => openSearch(),
        SingleActivator(LogicalKeyboardKey.keyL, meta: mac, control: !mac): () => openSearch(),
        SingleActivator(LogicalKeyboardKey.bracketLeft, meta: mac, control: !mac): () =>
          _navigators[_section]!.currentState?.maybePop(),
        for (final (i, section) in [Section.home, Section.library, Section.search, Section.queue, Section.downloads].indexed)
          SingleActivator(LogicalKeyboardKey(LogicalKeyboardKey.digit1.keyId + i), meta: mac, control: !mac): () => _go(section),
      },
      child: playerKeys(
        player: s.player,
        back: SingleActivator(LogicalKeyboardKey.arrowLeft, meta: mac, control: !mac),
        forward: SingleActivator(LogicalKeyboardKey.arrowRight, meta: mac, control: !mac),
        child: Focus(
        autofocus: true,
        child: PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) async {
            if (didPop) return;
            final navigator = _navigators[_section]!.currentState;
            if (navigator != null && await navigator.maybePop()) return;
            if (_section != Section.home) setState(() => _section = Section.home);
          },
          child: Scaffold(
            body: wide
              ? Stack(children: [
                  // The page fills the window and runs on under the
                  // sidebar's glass; it pads its left by the sidebar and its
                  // bottom by the mini player floating over it (MediaQuery
                  // padding), so a show's sleeve and glow carry on under
                  // both. macOS's window buttons sit in the sidebar, so the
                  // page needn't clear them.
                  Positioned.fill(
                    child: MediaQuery(
                      data: MediaQuery.of(context).copyWith(
                        padding: MediaQuery.paddingOf(context).copyWith(
                          left: _railEdge,
                          top: mac ? 0 : MediaQuery.paddingOf(context).top,
                          bottom: MediaQuery.paddingOf(context).bottom + _miniPlayer,
                        ),
                      ),
                      child: _ShowingScope(showing: _showing, child: _stacks()),
                    ),
                  ),
                  Positioned(
                    left: _railEdge,
                    right: 0,
                    bottom: 0,
                    child: _OnHeight(
                      onHeight: (h) => setState(() => _miniPlayer = h),
                      child: const MiniPlayer(wide: true),
                    ),
                  ),
                  Positioned(
                    left: _railInset,
                    top: _railInset,
                    bottom: _railInset,
                    width: _railWidth,
                    child: _Sidebar(section: _section, showing: _showing, onGo: _go),
                  ),
                ])
              // No top inset here: a show's artwork runs under the status
              // bar; pages pad themselves by it (PageBody, SleevePage).
              : SafeArea(top: false, bottom: false, child: _ShowingScope(showing: _showing, child: _stacks())),
            // The page runs on under the mini player and the tab bar, and
            // pads its end by their height (Scaffold's MediaQuery padding).
            extendBody: !wide,
            bottomNavigationBar: wide
              ? null
              : Column(mainAxisSize: MainAxisSize.min, children: [
                  const MiniPlayer(wide: false),
                  _PhoneBar(section: _section, onGo: _go),
                ]),
          ),
        ),
        ),
      ),
    );
  }
}

/// What search should show when another screen opens it.
final class SearchRequest extends ChangeNotifier {
  String? query;
  bool youtube = false;

  /// The id of a ListenJar Cloud podcast of the listener's own to add
  /// videos to, when search was opened from it.
  String? into;
  /// How many times [ask] was called; [focus] leaves it be.
  int asked = 0;

  void ask({String? query, bool youtube = false, String? into}) {
    this.query = query;
    this.youtube = youtube;
    this.into = into;
    asked++;
    notifyListeners();
  }

  /// Puts the caret in search's field, and the keyboard up, keeping what
  /// it searches.
  void focus() => notifyListeners();
}

// The sidebar: a glass panel floating over the page's left, inset from the
// window's edges (DESIGN.md "Sidebar"). It takes the page's tone: light
// glass over paper, dark over a sleeve's ink, crossfading as pages change.
const _railInset = 10.0;
const _railWidth = 216.0;

/// Where the sidebar ends: pages pad their left by this.
const _railEdge = _railInset + _railWidth;
const _railRadius = 18.0;

/// What the page in front is, for the chrome floating over it: whether it's
/// on ink, and which show it's of. Pages say so with [Shown].
final class Showing extends ChangeNotifier {
  final _pages = <State, ({bool onInk, int? show})>{};

  bool get onInk => _pages.values.any((p) => p.onInk);
  int? get show => _pages.values.map((p) => p.show).nonNulls.firstOrNull;

  void _set(State page, ({bool onInk, int? show})? what) {
    final before = (onInk, show);
    if (what == null) {
      _pages.remove(page);
    } else {
      _pages[page] = what;
    }
    if ((onInk, show) != before) notifyListeners();
  }
}

final class _ShowingScope extends InheritedWidget {
  const _ShowingScope({required this.showing, required super.child});
  final Showing showing;

  @override
  bool updateShouldNotify(_ShowingScope old) => showing != old.showing;
}

/// Tells the window's chrome what [child] is while it's in front: its
/// route on top, in the section showing.
final class Shown extends StatefulWidget {
  const Shown({super.key, this.onInk = false, this.show, required this.child});
  final bool onInk;

  /// The show the page is of.
  final int? show;
  final Widget child;

  @override
  State<Shown> createState() => _ShownState();
}

final class _ShownState extends State<Shown> {
  Showing? _showing;

  @override
  Widget build(BuildContext context) {
    _showing = context.getInheritedWidgetOfExactType<_ShowingScope>()?.showing;
    final front = (ModalRoute.isCurrentOf(context) ?? true) && Visibility.of(context);
    final what = front ? (onInk: widget.onInk, show: widget.show) : null;
    // After the frame: the sidebar may have built already.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _showing?._set(this, what);
    });
    return widget.child;
  }

  @override
  void dispose() {
    final showing = _showing;
    WidgetsBinding.instance.addPostFrameCallback((_) => showing?._set(this, null));
    super.dispose();
  }
}

/// The sidebar's colours on paper ([t] 0) or ink ([t] 1).
final class _RailTone {
  _RailTone(double t)
    : tint = Color.lerp(const Color(0xB8FFFFFF), const Color(0x73121319), t)!,
      edge = Color.lerp(brand.line, brand.inkLine, t)!,
      shadow = Color.lerp(const Color(0x14171A38), const Color(0x59000000), t)!,
      fg = Color.lerp(brand.fg, brand.snow, t)!,
      soft = Color.lerp(brand.fgSoft, brand.snowSoft, t)!,
      faint = Color.lerp(brand.fgFaint, brand.snowFaint, t)!,
      accent = Color.lerp(brand.accent, brand.accentLight, t)!,
      held = Color.lerp(const Color(0x121C1D20), const Color(0x1FFFFFFF), t)!,
      hover = Color.lerp(const Color(0x091C1D20), const Color(0x0FFFFFFF), t)!;
  final Color tint, edge, shadow, fg, soft, faint, accent, held, hover;
}

final class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.section, required this.showing, required this.onGo});
  final Section section;
  final Showing showing;
  final void Function(Section) onGo;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: showing,
    builder: (context, _) => TweenAnimationBuilder<double>(
      tween: Tween(end: showing.onInk ? 1 : 0),
      duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : brand.toneSpeed,
      curve: brand.easeOutExpo,
      builder: (context, t, _) => _panel(context, _RailTone(t)),
    ),
  );

  Widget _panel(BuildContext context, _RailTone tone) {
    final s = Services.of(context);
    final mac = defaultTargetPlatform == TargetPlatform.macOS;
    const shape = RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(_railRadius)));
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(_railRadius),
        boxShadow: [BoxShadow(color: tone.shadow, offset: const Offset(0, 8), blurRadius: 28, spreadRadius: -10)],
      ),
      child: Stack(children: [
        Positioned.fill(
          child: Glass(
            tint: tone.tint,
            shape: shape.copyWith(side: BorderSide(color: tone.edge)),
          ),
        ),
        Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          // macOS's window buttons sit in the panel's top; elsewhere the
          // mark does. Either way it's the window's handle.
          GestureDetector(
            behavior: HitTestBehavior.translucent,
            onPanStart: (_) => windowCommand('startDrag'),
            onDoubleTap: () => windowCommand('zoom'),
            child: mac
              ? SizedBox(height: math.max(MediaQuery.paddingOf(context).top - _railInset, 18))
              : Padding(
                  padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
                  child: Align(alignment: Alignment.centerLeft, child: logo(height: 20)),
                ),
          ),
          Expanded(
            child: ListenableBuilder(
              listenable: Listenable.merge([s.library, s.feeds]),
              builder: (context, _) {
                final queued = s.library.queue.length;
                final downloading = s.library.unfinishedDownloads().length;
                final shows = s.library.podcasts;
                final feeds = {for (final f in s.feeds.feeds) f.id};
                return ListView(padding: const EdgeInsets.fromLTRB(8, 0, 8, 8), children: [
                  for (final item in [Section.home, Section.library, Section.search, Section.queue, Section.downloads])
                    _RailItem(
                      tone: tone,
                      // A show in front takes the pill; its section keeps
                      // its accent.
                      selected: item == section && !shows.any((p) => p.id == showing.show),
                      icon: Icon(item.icon, size: 18, color: item == section ? tone.accent : tone.soft),
                      label: item.label,
                      count: switch (item) {
                        Section.queue when queued > 0 => '$queued',
                        Section.downloads when downloading > 0 => '$downloading',
                        _ => null,
                      },
                      onTap: () => onGo(item),
                    ),
                  if (shows.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(10, 20, 10, 6),
                      child: Text(
                        'Following',
                        style: Theme.of(context).textTheme.labelSmall!.copyWith(color: tone.faint, fontSize: 11.5, fontWeight: FontWeight.w600),
                      ),
                    ),
                    for (final show in shows)
                      _RailItem(
                        tone: tone,
                        selected: show.id == showing.show,
                        icon: Artwork(url: show.artworkUrl, title: show.title, size: 22, radius: 5),
                        label: show.title,
                        onTap: () => switch (show.cloudFeedId) {
                          final feed? when feeds.contains(feed) => Navigation.of(context).openFeed(feed),
                          _ when show.id == showing.show => null,
                          _ => Navigation.of(context).openShow(show.id),
                        },
                      ),
                  ],
                ]);
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: _RailItem(
              tone: tone,
              selected: section == Section.settings,
              icon: Icon(Section.settings.icon, size: 18, color: section == Section.settings ? tone.accent : tone.soft),
              label: Section.settings.label,
              onTap: () => onGo(Section.settings),
            ),
          ),
        ]),
      ]),
    );
  }
}

/// A row of the sidebar: a section, or a show by its artwork.
final class _RailItem extends StatefulWidget {
  const _RailItem({required this.tone, required this.selected, required this.icon, required this.label, required this.onTap, this.count});
  final _RailTone tone;
  final bool selected;
  final Widget icon;
  final String label;
  final VoidCallback onTap;

  /// A plain number at the row's end: what's queued or downloading.
  final String? count;

  @override
  State<_RailItem> createState() => _RailItemState();
}

final class _RailItemState extends State<_RailItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final tone = widget.tone;
    final selected = widget.selected;
    return Semantics(
      selected: selected,
      button: true,
      label: widget.label,
      excludeSemantics: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            height: 34,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: selected ? tone.held : _hover ? tone.hover : null,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(children: [
              SizedBox(width: 22, child: Center(child: widget.icon)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.labelLarge!.copyWith(fontSize: 13.5, color: tone.fg, fontWeight: selected ? FontWeight.w600 : FontWeight.w500),
                ),
              ),
              if (widget.count case final count?)
                Text(
                  count,
                  style: text.labelSmall!.copyWith(color: tone.faint, fontSize: 12, fontFeatures: const [FontFeature.tabularFigures()]),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

final class _PhoneBar extends StatelessWidget {
  const _PhoneBar({required this.section, required this.onGo});
  final Section section;
  final void Function(Section) onGo;

  @override
  Widget build(BuildContext context) {
    final index = _phoneSections.indexOf(section);
    return NavigationBarTheme(
      data: NavigationBarThemeData(
        backgroundColor: brand.white,
        indicatorColor: brand.mist,
        surfaceTintColor: brand.white,
        labelTextStyle: WidgetStateProperty.resolveWith((states) => TextStyle(
          fontSize: 12,
          fontWeight: states.contains(WidgetState.selected) ? FontWeight.w700 : FontWeight.w500,
          color: states.contains(WidgetState.selected) ? brand.fg : brand.fgSoft,
        )),
        iconTheme: WidgetStateProperty.resolveWith((states) => IconThemeData(
          color: states.contains(WidgetState.selected) ? brand.accent : brand.fgSoft,
        )),
      ),
      child: NavigationBar(
        height: 64,
        // Downloads and Settings live in Library on phones.
        selectedIndex: index == -1 ? 1 : index,
        onDestinationSelected: (i) => onGo(_phoneSections[i]),
        destinations: [
          for (final s in _phoneSections)
            NavigationDestination(icon: Icon(s.icon), label: s.label),
        ],
      ),
    );
  }
}

/// A section's scrolling page: a centred column with the dashboard's
/// gutters (DESIGN.md "Layout").
final class PageBody extends StatelessWidget {
  const PageBody({super.key, required this.children, this.maxWidth = 960, this.controller});
  final List<Widget> children;
  final double maxWidth;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    // The sidebar floats over the page's left (MediaQuery padding).
    final left = MediaQuery.paddingOf(context).left;
    final gutter = ((width - left) * 0.04).clamp(16.0, 40.0);
    final mac = defaultTargetPlatform == TargetPlatform.macOS;
    return Scrollbar(
      controller: controller,
      child: ListView(
        controller: controller,
        primary: controller == null,
        // Scrolling on a phone puts the keyboard away, as iOS and Android
        // pages do. Not on a computer: a trackpad's scroll is a drag too,
        // and would take focus out of the field being typed in.
        keyboardDismissBehavior: switch (defaultTargetPlatform) {
          TargetPlatform.iOS || TargetPlatform.android => ScrollViewKeyboardDismissBehavior.onDrag,
          _ => ScrollViewKeyboardDismissBehavior.manual,
        },
        padding: EdgeInsets.fromLTRB(
          left + gutter,
          MediaQuery.paddingOf(context).top + (mac && width >= wideWidth ? 40 : 24),
          gutter,
          MediaQuery.paddingOf(context).bottom + 40,
        ),
        children: [
          // Every page starts at the same left edge; a narrower one ends
          // sooner instead of moving to the middle.
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 960),
              child: Align(
                alignment: Alignment.topLeft,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxWidth),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A page pushed onto a section's stack, sliding in as the platform does
/// (with iOS's back swipe).
Route<void> pageRoute(Widget page) => MaterialPageRoute<void>(builder: (_) => _surface(page));

// Each page is a Material of its own, so its ink (an InkWell's hover, focus
// or pressed highlight) paints with the page. On the Scaffold's Material it
// painted under every section, and a hidden page's stuck highlight showed
// through the others as grey bars. Opaque, so a page sliding or fading in
// covers the one under it instead of showing it through.
Widget _surface(Widget page) => Material(color: brand.paper, child: page);

/// A back button for pages pushed onto a section.
Widget backButton(BuildContext context, String label) => Align(
  alignment: Alignment.centerLeft,
  child: Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextButton.icon(
      style: brand.button(brand.Tone.quiet, brand.ButtonSize.sm).copyWith(
        minimumSize: const WidgetStatePropertyAll(Size(0, 32)),
        padding: const WidgetStatePropertyAll(EdgeInsets.only(left: 6, right: 12)),
        backgroundColor: WidgetStateProperty.fromMap({WidgetState.hovered: brand.paperDeep, WidgetState.any: const Color(0x00000000)}),
      ),
      onPressed: () => Navigator.of(context).maybePop(),
      icon: const Icon(Icons.chevron_left_rounded, size: 20),
      label: Text(label),
    ),
  ),
);

const _windowChannel = MethodChannel('listenjar/window');

/// Asks macOS's window (macos/Runner) to move or zoom; elsewhere the system
/// titlebar does it.
void windowCommand(String method) {
  if (defaultTargetPlatform != TargetPlatform.macOS) return;
  unawaited(_windowChannel.invokeMethod<void>(method).catchError((_) {}, test: (e) => e is MissingPluginException));
}

/// Tells [onHeight] its child's height whenever it changes.
final class _OnHeight extends SingleChildRenderObjectWidget {
  const _OnHeight({required this.onHeight, required super.child});
  final ValueChanged<double> onHeight;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderOnHeight(onHeight);

  @override
  void updateRenderObject(BuildContext context, _RenderOnHeight renderObject) => renderObject.onHeight = onHeight;
}

final class _RenderOnHeight extends RenderProxyBox {
  _RenderOnHeight(this.onHeight);
  ValueChanged<double> onHeight;
  double? _told;

  @override
  void performLayout() {
    super.performLayout();
    final height = size.height;
    if (height == _told) return;
    _told = height;
    WidgetsBinding.instance.addPostFrameCallback((_) => onHeight(height));
  }
}
