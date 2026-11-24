// The window: the player's sections and the ListenJar section side by side.
// Wide windows (desktop, tablets) get a sidebar; phones a bottom bar. The
// mini player sits under every section once something is loaded and opens
// Now Playing (now_playing.dart). Each section keeps one stack of pages, so
// a show opened from search comes back with the search behind it.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'cloud.dart';
import 'downloads_page.dart';
import 'home_page.dart';
import 'library_page.dart';
import 'marks.dart';
import 'now_playing.dart';
import 'queue_page.dart';
import 'search_page.dart';
import 'settings_page.dart';
import 'show_page.dart';
import 'shared_links.dart';
import 'theme.dart' as brand;
import 'ui.dart';

enum Section {
  home('Listen Now', Icons.headphones_rounded),
  library('Library', Icons.grid_view_rounded),
  search('Search', Icons.search_rounded),
  queue('Up Next', Icons.queue_music_rounded),
  downloads('Downloads', Icons.download_rounded),
  cloud('ListenJar Cloud', Icons.cloud_outlined),
  settings('Settings', Icons.tune_rounded);

  const Section(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// Phones' bottom bar: Downloads and Settings are a tap away in Library.
const _phoneSections = [Section.home, Section.library, Section.search, Section.queue, Section.cloud];

/// From this width the sidebar shows.
const wideWidth = 760.0;

final class Shell extends StatefulWidget {
  const Shell({super.key, required this.links});

  /// Links shared to the app, which the shell opens as they come.
  final IncomingLinks links;

  @override
  State<Shell> createState() => _ShellState();
}

final class _ShellState extends State<Shell> implements NavigationTarget {
  Section _section = Section.home;
  final _navigators = {for (final s in Section.values) s: GlobalKey<NavigatorState>()};

  /// Search asked for from elsewhere, for the search page to pick up.
  final search = SearchRequest();

  late final _lifecycle = AppLifecycleListener(
    onResume: () => unawaited(Services.of(context).podcasts.refreshAll()),
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
  }

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
    if (_navigation.target == this) _navigation.target = null;
    _lifecycle.dispose();
    search.dispose();
    super.dispose();
  }

  void _go(Section section) {
    if (section == _section) {
      // A second tap goes back to the section's first page.
      _navigators[section]!.currentState?.popUntil((r) => r.isFirst);
      return;
    }
    setState(() => _section = section);
  }

  @override
  void openShow(int podcastId) {
    final section = _section == Section.settings || _section == Section.cloud ? Section.library : _section;
    setState(() => _section = section);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _navigators[section]!.currentState?.push(_page(ShowPage(podcastId: podcastId)));
    });
  }

  @override
  void openNowPlaying() => unawaited(showNowPlaying(context));

  @override
  void openSearch({String? query, bool youtube = false}) {
    _navigators[Section.search]!.currentState?.popUntil((r) => r.isFirst);
    setState(() => _section = Section.search);
    search.ask(query: query, youtube: youtube);
  }

  @override
  void openCloud() => _go(Section.cloud);

  static Route<void> _page(Widget page) => PageRouteBuilder<void>(
    pageBuilder: (_, _, _) => page,
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
    Section.cloud => const CloudSection(),
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
              ? Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  _Sidebar(section: _section, onGo: _go),
                  Expanded(
                    child: Column(children: [
                      Expanded(child: _stacks()),
                      const MiniPlayer(wide: true),
                    ]),
                  ),
                ])
              : SafeArea(bottom: false, child: _stacks()),
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
  int asked = 0;

  void ask({String? query, bool youtube = false}) {
    this.query = query;
    this.youtube = youtube;
    asked++;
    notifyListeners();
  }
}

final class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.section, required this.onGo});
  final Section section;
  final void Function(Section) onGo;

  @override
  Widget build(BuildContext context) {
    final s = Services.of(context);
    final mac = defaultTargetPlatform == TargetPlatform.macOS;
    return Container(
      width: 236,
      decoration: const BoxDecoration(
        color: Color(0xFFEFEDE8),
        border: Border(right: BorderSide(color: brand.line)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // Clear of macOS's window buttons, and the window's handle.
        GestureDetector(
          behavior: HitTestBehavior.translucent,
          onPanStart: (_) => windowCommand('startDrag'),
          onDoubleTap: () => windowCommand('zoom'),
          child: SizedBox(height: mac ? 52 : 18),
        ),
        Padding(padding: const EdgeInsets.fromLTRB(22, 0, 22, 22), child: Align(alignment: Alignment.centerLeft, child: logo(height: 26))),
        Expanded(
          child: ListenableBuilder(
            listenable: Listenable.merge([s.library, s.account]),
            builder: (context, _) {
              final queued = s.library.queue.length;
              final downloading = s.library.unfinishedDownloads().length;
              return ListView(padding: const EdgeInsets.symmetric(horizontal: 12), children: [
                for (final item in [Section.home, Section.library, Section.search, Section.queue, Section.downloads])
                  _NavItem(
                    section: item,
                    selected: item == section,
                    badge: switch (item) {
                      Section.queue when queued > 0 => '$queued',
                      Section.downloads when downloading > 0 => '$downloading',
                      _ => null,
                    },
                    onTap: () => onGo(item),
                  ),
                const SizedBox(height: 18),
                _NavItem(
                  section: Section.cloud,
                  selected: section == Section.cloud,
                  subtitle: s.account.user == null ? 'Your YouTube as podcasts' : s.account.user!.email,
                  onTap: () => onGo(Section.cloud),
                ),
              ]);
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
          child: _NavItem(section: Section.settings, selected: section == Section.settings, onTap: () => onGo(Section.settings)),
        ),
      ]),
    );
  }
}

final class _NavItem extends StatefulWidget {
  const _NavItem({required this.section, required this.selected, required this.onTap, this.badge, this.subtitle});
  final Section section;
  final bool selected;
  final VoidCallback onTap;
  final String? badge;
  final String? subtitle;

  @override
  State<_NavItem> createState() => _NavItemState();
}

final class _NavItemState extends State<_NavItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final selected = widget.selected;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Semantics(
        selected: selected,
        button: true,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: brand.quick,
              curve: brand.easeOutExpo,
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: widget.subtitle == null ? 9 : 8),
              decoration: BoxDecoration(
                color: selected ? brand.white : (_hover ? brand.paperDeep : const Color(0x00000000)),
                borderRadius: BorderRadius.circular(12),
                boxShadow: selected ? const [BoxShadow(color: Color(0x14171A38), offset: Offset(0, 4), blurRadius: 12, spreadRadius: -6)] : null,
              ),
              child: Row(children: [
                Icon(widget.section.icon, size: 20, color: selected ? brand.accent : brand.fgSoft),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(
                      widget.section.label,
                      style: text.labelLarge!.copyWith(fontSize: 14.5, color: brand.fg, fontWeight: selected ? FontWeight.w700 : FontWeight.w600),
                    ),
                    if (widget.subtitle case final sub?) ...[
                      const SizedBox(height: 3),
                      Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodySmall!.copyWith(fontSize: 12, color: brand.fgSoft, height: 1.2)),
                    ],
                  ]),
                ),
                if (widget.badge case final badge?)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(color: brand.mist, borderRadius: BorderRadius.circular(99)),
                    child: Text(
                      badge,
                      style: text.labelSmall!.copyWith(color: brand.accentHover, fontWeight: FontWeight.w600, fontFeatures: const [FontFeature.tabularFigures()]),
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
            NavigationDestination(icon: Icon(s.icon), label: s == Section.cloud ? 'Cloud' : s.label),
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
    final gutter = (width * 0.04).clamp(16.0, 40.0);
    final mac = defaultTargetPlatform == TargetPlatform.macOS;
    return Scrollbar(
      controller: controller,
      child: ListView(
        controller: controller,
        primary: controller == null,
        padding: EdgeInsets.fromLTRB(gutter, mac && width >= wideWidth ? 40 : 24, gutter, 40),
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
