// Plans in the window: which plan the listener is on and how much of its
// storage they use, the sheet that sends them to checkout on the website
// (prices from lib/pricing, `moon run desktop:codegen`), the sheet that makes
// room when the storage is full, and naming a podcast of their own. The
// backend decides what a plan allows (public.yaml); this only shows it.
import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import 'account.dart';
import 'backend/api.dart';
import 'config.dart';
import 'feeds.dart';
import 'links.dart';
import 'marks.dart';
import 'pricing/catalog.dart' as pricing;
import 'theme.dart' as brand;

/// What every plan adds to Free, as the pricing page puts it.
const _planPerks = [
  'YouTube playlists and channels, kept in sync',
  'Podcasts of your own: any videos, one feed',
];

/// The catalog plan the listener pays for, by its storage.
pricing.Plan? catalogPlan(User user) =>
  pricing.plans.where((p) => p.storageBytes == user.storageLimitBytes).firstOrNull;

/// A bigger plan than the listener's, if there is one.
pricing.Plan? biggerPlan(User user) =>
  pricing.plans.where((p) => p.storageBytes > (user.storageLimitBytes ?? 0)).firstOrNull;

/// "10 GB" out of "ListenJar 10 GB".
String _size(pricing.Plan plan) => plan.name.replaceFirst(RegExp(r'^ListenJar\s+'), '');

/// "10 GB plan", or "Free plan".
String planName(User user) => switch (user.plan) {
  Plan.free => 'Free plan',
  Plan.paid => switch (catalogPlan(user)) {
    final plan? => '${_size(plan)} plan',
    null => 'Your plan',
  },
};

/// Storage in decimal units, as plans are sold: "820 MB", "3.2 GB", "10 GB".
String formatBytes(int bytes) {
  const mb = 1000 * 1000, gb = 1000 * mb;
  if (bytes == 0) return '0 MB';
  if (bytes < mb) return '<1 MB';
  if (bytes < gb) return '${(bytes / mb).round()} MB';
  final value = bytes / gb;
  return value < 10 && value.roundToDouble() != value ? '${value.toStringAsFixed(1)} GB' : '${value.round()} GB';
}

String _money(int cents, String currency) {
  final symbol = currency == 'usd' ? r'$' : '${currency.toUpperCase()} ';
  return cents % 100 == 0 ? '$symbol${cents ~/ 100}' : '$symbol${(cents / 100).toStringAsFixed(2)}';
}

/// "about 170 hours", from the plan's description.
String? _hours(pricing.Plan plan) => RegExp(r'\((about [^)]+)\)').firstMatch(plan.description)?.group(1);

Uri _web(String path, [Map<String, String>? query]) =>
  currentConfig().web.replace(path: path, queryParameters: query);

/// The website's checkout for [price]; someone who pays already lands in
/// the billing portal.
Uri checkoutUrl(pricing.PlanPrice price) => _web('/checkout', {'price': price.lookupKey});

/// The billing portal: change or cancel the plan.
Uri get billingUrl => _web('/billing');

Future<void> openInBrowser(BuildContext context, Uri url) async {
  final messenger = ScaffoldMessenger.of(context);
  if (await launchUrl(url, mode: LaunchMode.externalApplication)) {
    messenger.showSnackBar(const SnackBar(
      content: Text('Finish in your browser. Your plan shows here once it’s done.'),
    ));
  } else {
    messenger.showSnackBar(SnackBar(content: Text('Couldn’t open your browser. Go to $url')));
  }
}

/// When the daily cleanup removes a free listener's feed, in a few words.
String? removedIn(Feed feed, DateTime now) {
  final at = DateTime.tryParse(feed.expiresAt ?? '');
  if (at == null) return null;
  final left = at.difference(now);
  if (left <= Duration.zero) return 'removed soon';
  if (left < const Duration(hours: 1)) return 'removed within the hour';
  if (left < const Duration(hours: 36)) {
    final hours = (left.inMinutes / 60).round();
    return 'removed in $hours ${hours == 1 ? 'hour' : 'hours'}';
  }
  return 'removed in ${(left.inHours / 24).round()} days';
}

/// The full date, for a tooltip.
String removedAt(Feed feed) {
  final at = DateTime.tryParse(feed.expiresAt ?? '')?.toLocal();
  if (at == null) return '';
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final time = '${at.hour}:${at.minute.toString().padLeft(2, '0')}';
  return 'Free podcasts are removed about a day after you add them. This one goes '
    '${months[at.month - 1]} ${at.day} at $time.';
}

/// A quiet button on paper or mist: white, deep paper under the pointer.
ButtonStyle whiteButton() => brand.button(brand.Tone.quiet, brand.ButtonSize.sm).copyWith(
  backgroundColor: WidgetStateProperty.fromMap({
    WidgetState.hovered: brand.paperDeep,
    WidgetState.any: brand.white,
  }),
);

/// A thin pill of how full the storage is: accent, danger once full.
final class StorageMeter extends StatelessWidget {
  const StorageMeter({super.key, required this.used, required this.limit, this.width = 140});
  final int used;
  final int limit;
  final double width;

  @override
  Widget build(BuildContext context) {
    final fraction = limit <= 0 ? 0.0 : (used / limit).clamp(0.0, 1.0);
    return Semantics(
      label: 'Storage',
      value: '${(fraction * 100).round()}%',
      child: Container(
        width: width,
        height: 6,
        decoration: BoxDecoration(color: brand.paperDeep, borderRadius: BorderRadius.circular(3)),
        alignment: Alignment.centerLeft,
        child: FractionallySizedBox(
          // A sliver shows even a little use.
          widthFactor: used > 0 ? fraction.clamp(0.03, 1.0) : 0,
          child: Container(
            decoration: BoxDecoration(
              color: fraction >= 1 ? brand.danger : brand.accent,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        ),
      ),
    );
  }
}

/// Above the feeds: the plan, and on it what the listener can do next.
/// Free shows what it keeps and the way to a plan; a plan shows its
/// storage and makes podcasts of the listener's own.
final class PlanBar extends StatelessWidget {
  const PlanBar({super.key, required this.user, required this.onPlans, required this.onNewPodcast});
  final User user;
  final VoidCallback onPlans;
  final VoidCallback onNewPodcast;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final soft = text.bodySmall!.copyWith(color: brand.fgSoft, height: 1.3);
    final title = text.titleMedium!.copyWith(fontSize: 15);
    final (detail, action) = switch (user) {
      User(plan: Plan.free) => (
        Text('Single videos, each removed about a day after you add it', style: soft),
        // Quiet: the accent belongs to the moment a plan is needed.
        TextButton(style: whiteButton(), onPressed: onPlans, child: const Text('Keep them with a plan')),
      ),
      User(:final storageLimitBytes, :final storageUsedBytes) => (
        Row(children: [
          if (storageLimitBytes != null) ...[
            StorageMeter(used: storageUsedBytes ?? 0, limit: storageLimitBytes),
            const SizedBox(width: 10),
          ],
          Flexible(
            child: Text(
              storageLimitBytes == null
                ? 'Playlists, channels and podcasts of your own'
                : '${formatBytes(storageUsedBytes ?? 0)} of ${formatBytes(storageLimitBytes)} used',
              style: soft.copyWith(
                color: (storageUsedBytes ?? 0) >= (storageLimitBytes ?? 1 << 62) ? brand.danger : brand.fgSoft,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ]),
        TextButton.icon(
          style: whiteButton(),
          onPressed: onNewPodcast,
          icon: const Icon(Icons.add_rounded, size: 18),
          label: const Text('New podcast'),
        ),
      ),
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 0, 16),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(planName(user), style: title),
            const SizedBox(height: 5),
            detail,
          ]),
        ),
        const SizedBox(width: 16),
        action,
      ]),
    );
  }
}

/// A notice in the feeds' column: what happened in a line, what it means
/// underneath, and what to do about it. [tone] danger for something that
/// stopped, mist for an offer.
final class Notice extends StatelessWidget {
  const Notice({super.key, required this.title, required this.body, required this.actions, this.danger = false});
  final String title;
  final String body;
  final List<Widget> actions;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: danger ? brand.white : brand.mist,
        borderRadius: BorderRadius.circular(brand.radiusTile),
        boxShadow: danger ? const [brand.shadowSoft] : null,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 18, 18),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: text.titleMedium!.copyWith(fontSize: 15, color: danger ? brand.danger : brand.fg)),
              const SizedBox(height: 4),
              Text(body, style: text.bodySmall!.copyWith(color: brand.fgSoft)),
            ]),
          ),
          const SizedBox(width: 20),
          Wrap(spacing: 8, runSpacing: 8, children: actions),
        ]),
      ),
    );
  }
}

Widget _sheet({required BuildContext context, required Widget child, double width = 520}) => Dialog(
  backgroundColor: brand.white,
  surfaceTintColor: brand.white,
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(brand.radiusSheet)),
  insetPadding: const EdgeInsets.all(24),
  child: ConstrainedBox(
    constraints: BoxConstraints(maxWidth: width),
    child: Padding(padding: const EdgeInsets.fromLTRB(28, 26, 28, 24), child: child),
  ),
);

/// The sheet of plans: pick a size and how often to pay, then check out on
/// the website. [title] says why it opened.
Future<void> showPlans(BuildContext context, {String title = 'Keep what you add'}) => showDialog<void>(
  context: context,
  builder: (context) => _PlansSheet(title: title),
);

final class _PlansSheet extends StatefulWidget {
  const _PlansSheet({required this.title});
  final String title;

  @override
  State<_PlansSheet> createState() => _PlansSheetState();
}

final class _PlansSheetState extends State<_PlansSheet> {
  var _interval = pricing.PlanInterval.monthly;
  var _plan = pricing.plans.first;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final price = _plan.price(_interval);
    return _sheet(
      context: context,
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: Text(widget.title, style: text.titleLarge)),
          IconButton(
            tooltip: 'Close',
            visualDensity: VisualDensity.compact,
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close_rounded, size: 18, color: brand.fgSoft),
          ),
        ]),
        const SizedBox(height: 12),
        for (final perk in _planPerks)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(children: [
              const Icon(Icons.check_rounded, size: 17, color: brand.accent),
              const SizedBox(width: 10),
              Expanded(child: Text(perk, style: text.bodySmall!.copyWith(color: brand.fg))),
            ]),
          ),
        const SizedBox(height: 18),
        _IntervalSwitch(value: _interval, onChanged: (v) => setState(() => _interval = v)),
        const SizedBox(height: 14),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final (i, plan) in pricing.plans.indexed) ...[
            if (i > 0) const SizedBox(width: 12),
            Expanded(
              child: _PlanTile(
                plan: plan,
                interval: _interval,
                selected: plan == _plan,
                onTap: () => setState(() => _plan = plan),
              ),
            ),
          ],
        ]),
        const SizedBox(height: 22),
        Row(children: [
          Expanded(
            child: Text(
              'Checkout opens in your browser.',
              style: text.bodySmall!.copyWith(color: brand.fgSoft),
            ),
          ),
          const SizedBox(width: 16),
          brand.accentShadow(
            enabled: true,
            child: TextButton.icon(
              style: brand.button(brand.Tone.accent),
              autofocus: true,
              onPressed: () {
                Navigator.pop(context);
                unawaited(openInBrowser(context, checkoutUrl(price)));
              },
              iconAlignment: IconAlignment.end,
              icon: const Arrow(),
              label: Text('Get ${_size(_plan)}'),
            ),
          ),
        ]),
      ]),
    );
  }
}

/// Monthly or yearly: two speed-chip pills.
final class _IntervalSwitch extends StatelessWidget {
  const _IntervalSwitch({required this.value, required this.onChanged});
  final pricing.PlanInterval value;
  final ValueChanged<pricing.PlanInterval> onChanged;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Semantics(
      label: 'Billing period',
      child: Row(children: [
        for (final interval in pricing.PlanInterval.values) ...[
          if (interval != pricing.PlanInterval.values.first) const SizedBox(width: 6),
          TextButton(
            style: ButtonStyle(
              minimumSize: const WidgetStatePropertyAll(Size(0, 32)),
              padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 14)),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              overlayColor: const WidgetStatePropertyAll(Color(0x00000000)),
              animationDuration: brand.quick,
              textStyle: WidgetStatePropertyAll(text.labelLarge!.copyWith(fontSize: 13)),
              backgroundColor: WidgetStatePropertyAll(
                interval == value ? brand.accent : brand.paper,
              ),
              foregroundColor: WidgetStatePropertyAll(interval == value ? brand.white : brand.fgSoft),
              shape: WidgetStateProperty.resolveWith((states) => StadiumBorder(
                side: states.contains(WidgetState.focused) ? brand.focusSide : brand.focusSideOff,
              )),
            ),
            onPressed: () => onChanged(interval),
            child: Text(switch (interval) {
              pricing.PlanInterval.monthly => 'Monthly',
              pricing.PlanInterval.yearly => 'Yearly',
            }),
          ),
        ],
      ]),
    );
  }
}

/// One plan: its size and hours, its price for the interval. Selected, it
/// takes mist and the accent ring.
final class _PlanTile extends StatefulWidget {
  const _PlanTile({required this.plan, required this.interval, required this.selected, required this.onTap});
  final pricing.Plan plan;
  final pricing.PlanInterval interval;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_PlanTile> createState() => _PlanTileState();
}

final class _PlanTileState extends State<_PlanTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final plan = widget.plan;
    final price = plan.price(widget.interval);
    final tabular = const [FontFeature.tabularFigures()];
    final per = switch (widget.interval) {
      pricing.PlanInterval.monthly => 'Billed every month',
      pricing.PlanInterval.yearly => '${_money((price.amount / 12).round(), price.currency)} a month, billed yearly',
    };
    return Semantics(
      selected: widget.selected,
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
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
            decoration: BoxDecoration(
              color: widget.selected || _hover ? brand.mist : brand.paper,
              borderRadius: BorderRadius.circular(brand.radiusTile),
              border: Border.all(color: widget.selected ? brand.accent : brand.accent.withValues(alpha: 0), width: 2),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text(_size(plan), style: text.titleLarge)),
                AnimatedOpacity(
                  opacity: widget.selected ? 1 : 0,
                  duration: brand.quick,
                  child: const Icon(Icons.check_circle_rounded, size: 20, color: brand.accent),
                ),
              ]),
              if (_hours(plan) case final hours?) ...[
                const SizedBox(height: 2),
                Text('$hours of audio', style: text.bodySmall!.copyWith(color: brand.fgSoft)),
              ],
              const SizedBox(height: 14),
              Text.rich(
                TextSpan(children: [
                  TextSpan(
                    text: _money(price.amount, price.currency),
                    style: text.titleLarge!.copyWith(fontFeatures: tabular),
                  ),
                  TextSpan(
                    text: switch (widget.interval) {
                      pricing.PlanInterval.monthly => ' / month',
                      pricing.PlanInterval.yearly => ' / year',
                    },
                    style: text.bodySmall!.copyWith(color: brand.fgSoft),
                  ),
                ]),
              ),
              const SizedBox(height: 2),
              Text(per, style: text.bodySmall!.copyWith(color: brand.fgSoft, fontSize: 12.5, fontFeatures: tabular)),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Asks for a podcast of the listener's own's name; null if they cancel.
Future<String?> askPodcastTitle(BuildContext context) => showDialog<String>(
  context: context,
  builder: (context) => const _NewPodcastSheet(),
);

final class _NewPodcastSheet extends StatefulWidget {
  const _NewPodcastSheet();

  @override
  State<_NewPodcastSheet> createState() => _NewPodcastSheetState();
}

final class _NewPodcastSheetState extends State<_NewPodcastSheet> {
  final _title = TextEditingController();

  @override
  void initState() {
    super.initState();
    _title.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  void _done() {
    final title = _title.text.trim();
    if (title.isNotEmpty) Navigator.pop(context, title);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final ready = _title.text.trim().isNotEmpty;
    return _sheet(
      context: context,
      width: 440,
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('New podcast', style: text.titleLarge),
        const SizedBox(height: 6),
        Text(
          'A podcast you fill yourself. Paste a video link in the field at the top, then add it here.',
          style: text.bodySmall!.copyWith(color: brand.fgSoft),
        ),
        const SizedBox(height: 18),
        TextField(
          controller: _title,
          autofocus: true,
          maxLength: 500,
          onSubmitted: (_) => _done(),
          style: text.bodyMedium,
          cursorColor: brand.accent,
          decoration: InputDecoration(
            hintText: 'Name it, like “Long walks”',
            hintStyle: text.bodyMedium!.copyWith(color: brand.fgFaint),
            counterText: '',
            filled: true,
            fillColor: brand.paper,
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: brand.line),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: brand.accent.withValues(alpha: 0.6), width: 1.5),
            ),
          ),
        ),
        const SizedBox(height: 22),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          TextButton(
            style: brand.button(brand.Tone.quiet, brand.ButtonSize.sm),
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          const SizedBox(width: 8),
          brand.accentShadow(
            enabled: ready,
            child: TextButton(
              style: brand.button(brand.Tone.accent, brand.ButtonSize.sm),
              onPressed: ready ? _done : null,
              child: const Text('Create'),
            ),
          ),
        ]),
      ]),
    );
  }
}

/// Making room in a full plan: the listener's podcasts by how much they
/// store, each removable; the episodes of their own podcasts one by one. A
/// playlist's or channel's episodes come back with the next sync, so those
/// go whole.
Future<void> showMakeRoom(
  BuildContext context, {
  required Account account,
  required Feeds feeds,
  required Future<void> Function(Feed) onRemove,
}) => showDialog<void>(
  context: context,
  builder: (context) => _MakeRoomSheet(account: account, feeds: feeds, onRemove: onRemove),
);

final class _MakeRoomSheet extends StatefulWidget {
  const _MakeRoomSheet({required this.account, required this.feeds, required this.onRemove});
  final Account account;
  final Feeds feeds;
  final Future<void> Function(Feed) onRemove;

  @override
  State<_MakeRoomSheet> createState() => _MakeRoomSheetState();
}

final class _MakeRoomSheetState extends State<_MakeRoomSheet> {
  /// Each feed's uploaded episodes, as they load.
  final _episodes = <String, List<Episode>>{};
  Object? _error;
  final _removing = <String>{};
  late final _shown = Listenable.merge([widget.account, widget.feeds]);

  /// The storage use the list was added up at: when it moves (an upload
  /// landed, something was removed), the list adds up again.
  int? _counted;

  @override
  void initState() {
    super.initState();
    widget.account.addListener(_recount);
    unawaited(widget.account.refresh(force: true));
    unawaited(_load());
  }

  @override
  void dispose() {
    widget.account.removeListener(_recount);
    super.dispose();
  }

  void _recount() {
    if (widget.account.user?.storageUsedBytes != _counted) unawaited(_load());
  }

  Future<void> _load() async {
    _counted = widget.account.user?.storageUsedBytes;
    try {
      for (final feed in [...widget.feeds.feeds]) {
        final episodes = await widget.feeds.episodes(feed);
        if (!mounted) return;
        setState(() => _episodes[feed.id] = [for (final e in episodes) if (e.uploadedAt != null) e]);
      }
      if (mounted) setState(() => _episodes.removeWhere((id, _) => !widget.feeds.feeds.any((f) => f.id == id)));
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  int _bytes(Feed feed) => (_episodes[feed.id] ?? const []).fold(0, (n, e) => n + (e.byteLength ?? 0));

  Future<void> _removeEpisode(Feed feed, Episode episode) async {
    setState(() => _removing.add(episode.id));
    try {
      await widget.feeds.removeEpisode(feed, episode);
      if (mounted) setState(() => _episodes[feed.id]?.removeWhere((e) => e.id == episode.id));
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _removing.remove(episode.id));
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _shown,
    builder: (context, _) {
      final text = Theme.of(context).textTheme;
      final user = widget.account.user;
      final used = user?.storageUsedBytes ?? 0;
      final limit = user?.storageLimitBytes ?? 0;
      final waiting = widget.feeds.waitingForRoom;
      final feeds = [...widget.feeds.feeds.where((f) => _episodes.containsKey(f.id))]
        ..sort((a, b) => _bytes(b).compareTo(_bytes(a)));
      final loading = _episodes.length < widget.feeds.feeds.length && _error == null;
      return _sheet(
        context: context,
        width: 560,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: Text('Make room', style: text.titleLarge)),
            IconButton(
              tooltip: 'Close',
              visualDensity: VisualDensity.compact,
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close_rounded, size: 18, color: brand.fgSoft),
            ),
          ]),
          const SizedBox(height: 10),
          if (limit > 0) ...[
            StorageMeter(used: used, limit: limit, width: double.infinity),
            const SizedBox(height: 8),
            Text(
              [
                '${formatBytes(used)} of ${formatBytes(limit)} used',
                if (waiting > 0) waiting == 1 ? '1 episode waiting for room' : '$waiting episodes waiting for room',
              ].join(' · '),
              style: text.bodySmall!.copyWith(
                color: used >= limit ? brand.danger : brand.fgSoft,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
          const SizedBox(height: 6),
          Text(
            'A video’s audio counts once, however many of your podcasts have it. Playlists and '
            'channels refill from YouTube, so they go whole.',
            style: text.bodySmall!.copyWith(color: brand.fgSoft),
          ),
          const SizedBox(height: 16),
          if (_error case final error?)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text('Couldn’t load everything: $error', style: text.bodySmall!.copyWith(color: brand.danger)),
            ),
          Flexible(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(brand.radiusTile),
              child: ColoredBox(
                color: brand.paper,
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  children: [
                    for (final (i, feed) in feeds.indexed) ...[
                      if (i > 0) const Divider(height: 1, thickness: 1, indent: 16, endIndent: 16, color: brand.line),
                      _feed(text, feed),
                      if (feed.source == null)
                        for (final episode in _episodes[feed.id]!) _episode(text, feed, episode),
                    ],
                    if (loading)
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text('Adding up your podcasts…', style: text.bodySmall!.copyWith(color: brand.fgSoft)),
                      ),
                  ],
                ),
              ),
            ),
          ),
          if (biggerPlan(user!) case final bigger?) ...[
            const SizedBox(height: 18),
            Row(children: [
              Expanded(
                child: Text(
                  'Or move to ${_size(bigger)} and keep everything.',
                  style: text.bodySmall!.copyWith(color: brand.fgSoft),
                ),
              ),
              const SizedBox(width: 12),
              TextButton.icon(
                style: brand.button(brand.Tone.ink, brand.ButtonSize.sm),
                onPressed: () {
                  Navigator.pop(context);
                  unawaited(openInBrowser(context, billingUrl));
                },
                iconAlignment: IconAlignment.end,
                icon: const Arrow(size: 16),
                label: const Text('Change plan'),
              ),
            ]),
          ],
        ]),
      );
    },
  );

  Widget _feed(TextTheme text, Feed feed) {
    final kind = switch (feed.source) {
      final source? => kindLabel(source.kind),
      null => 'Podcast of your own',
    };
    final count = _episodes[feed.id]!.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              feed.title,
              style: text.bodySmall!.copyWith(color: brand.fg, fontWeight: FontWeight.w600),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              '$kind · ${count == 1 ? '1 episode' : '$count episodes'}',
              style: text.bodySmall!.copyWith(color: brand.fgSoft, fontSize: 12.5),
            ),
          ]),
        ),
        const SizedBox(width: 12),
        _bytesLabel(text, _bytes(feed)),
        const SizedBox(width: 8),
        TextButton(
          style: whiteButton().copyWith(
            minimumSize: const WidgetStatePropertyAll(Size(0, 32)),
            padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 14)),
          ),
          onPressed: () => widget.onRemove(feed),
          child: const Text('Remove'),
        ),
      ]),
    );
  }

  Widget _episode(TextTheme text, Feed feed, Episode episode) {
    final removing = _removing.contains(episode.id);
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 0, 8, 6),
      child: Row(children: [
        Expanded(
          child: Text(
            episode.title,
            style: text.bodySmall!.copyWith(color: removing ? brand.fgFaint : brand.fg, fontSize: 13),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 12),
        _bytesLabel(text, episode.byteLength ?? 0),
        const SizedBox(width: 4),
        IconButton(
          tooltip: 'Remove this episode',
          visualDensity: VisualDensity.compact,
          onPressed: removing ? null : () => _removeEpisode(feed, episode),
          icon: const Icon(Icons.close_rounded, size: 16, color: brand.fgSoft),
        ),
      ]),
    );
  }

  Widget _bytesLabel(TextTheme text, int bytes) => SizedBox(
    width: 64,
    child: Text(
      formatBytes(bytes),
      textAlign: TextAlign.end,
      style: text.bodySmall!.copyWith(color: brand.fgSoft, fontSize: 13, fontFeatures: const [FontFeature.tabularFigures()]),
    ),
  );
}
