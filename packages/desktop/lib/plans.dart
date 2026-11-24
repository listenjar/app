// Plans in the window: which plan the listener is on and how much of its
// storage they use, the sheet that sends them to Stripe Checkout, which the
// API makes for the signed-in listener (prices from lib/pricing, `moon run
// desktop:codegen`), the sheet that makes
// room when the storage is full, and naming a podcast of their own. The
// backend decides what a plan allows (public.yaml); this only shows it.
//
// Every plan unlocks the paid features on this device: following YouTube
// playlists and channels, and podcasts of the listener's own. Local stops
// there; 10 GB and 100 GB add ListenJar Cloud, which hosts them for any
// podcast app.
import 'dart:async';

import 'package:cancellation_token/cancellation_token.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import 'account.dart';
import 'backend/api.dart';
import 'cloud.dart' show failure;
import 'config.dart';
import 'feeds.dart';
import 'links.dart';
import 'marks.dart';
import 'pricing/catalog.dart' as pricing;
import 'sign_in_form.dart';
import 'theme.dart' as brand;
import 'ui.dart' show Services;

/// What every plan adds to Free, as the pricing page puts it.
const _planPerks = [
  'YouTube playlists and channels, kept in sync',
  'Podcasts of your own: any videos, one feed',
];

/// Whether the listener's plan unlocks the paid features on this device:
/// any plan, Local included.
bool isPaid(User? user) => user?.plan == Plan.paid;

/// Whether the listener's plan has ListenJar Cloud: 10 GB or 100 GB. Local
/// pays without it.
bool hasCloud(User? user) => user?.plan == Plan.paid && user?.storageLimitBytes != null;

/// The catalog plan the listener pays for, by its storage (none for Local).
pricing.Plan? catalogPlan(User user) => switch (user.plan) {
  Plan.free => null,
  Plan.paid => pricing.plans.where((p) => p.storageBytes == (user.storageLimitBytes ?? 0)).firstOrNull,
};

/// A bigger Cloud plan than the listener's, if there is one.
pricing.Plan? biggerPlan(User user) => pricing.plans.where((p) => p.cloud && p.storageBytes > (user.storageLimitBytes ?? 0)).firstOrNull;

/// "10 GB" out of "ListenJar 10 GB", "Local" out of "ListenJar Local".
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

/// Where Stripe sends the browser back, whether the listener paid, left or
/// changed their plan: this app's own address, which brings it to the front,
/// and coming back refreshes the plan (shell.dart).
String get _stripeReturn => Uri(scheme: appScheme, host: 'plans').toString();

/// Stripe Checkout for [price], made by the API for the signed-in listener.
Future<Uri> _checkoutUrl(Account account, pricing.PlanPrice price) async {
  final checkout = await account.api
    .createCheckout(body: CheckoutRequest(price: price.lookupKey, returnUrl: _stripeReturn))
    .asCancellable(account.timeout());
  return Uri.parse(checkout.url);
}

/// Stripe's billing portal, where the signed-in listener changes or cancels
/// their plan.
Future<Uri> _portalUrl(Account account) async {
  final portal = await account.api
    .createBillingPortal(body: BillingPortalRequest(returnUrl: _stripeReturn))
    .asCancellable(account.timeout());
  return Uri.parse(portal.url);
}

/// Opens [url], one of Stripe's pages, in the browser.
Future<void> _openStripe(ScaffoldMessengerState? messenger, Uri url) async {
  final opened = await launchUrl(url, mode: LaunchMode.externalApplication);
  messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(opened
        ? 'Finish in your browser. Your plan shows here once it’s done.'
        : 'Couldn’t open your browser. Try again.'),
    ));
}

/// Opens the billing portal in the browser, to change or cancel the plan.
Future<void> manageBilling(BuildContext context) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    await _openStripe(messenger, await _portalUrl(Services.of(context).account));
  } catch (e) {
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(failure('Couldn’t open your plan', e, other: 'Try again.'))));
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

/// Whether the window is phone-narrow: sheets hug its edges closer.
bool _narrow(BuildContext context) => MediaQuery.sizeOf(context).width < 480;

Widget _sheet({required BuildContext context, required Widget child, double width = 520}) {
  final narrow = _narrow(context);
  return Dialog(
    backgroundColor: brand.white,
    surfaceTintColor: brand.white,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(brand.radiusSheet)),
    insetPadding: EdgeInsets.all(narrow ? 16 : 24),
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: width),
      child: Padding(
        padding: narrow ? const EdgeInsets.fromLTRB(20, 20, 20, 20) : const EdgeInsets.fromLTRB(28, 26, 28, 24),
        child: child,
      ),
    ),
  );
}

/// The sheet of plans: pick one and how often to pay, then pay on Stripe
/// Checkout in the browser, signing in here first if need be. [title] says
/// why it opened; [cloud] when it's for something only ListenJar Cloud does,
/// which leaves Local out. Someone who pays already (on Local) changes plans
/// in the billing portal instead.
Future<void> showPlans(BuildContext context, {String title = 'Keep what you add', bool cloud = false}) => showDialog<void>(
  context: context,
  builder: (_) => _PlansSheet(title: title, cloud: cloud, account: Services.of(context).account),
);

/// What ListenJar Cloud adds to every plan's perks, as the pricing page puts it.
const _cloudPerk = 'ListenJar Cloud: they play in any podcast app';

final class _PlansSheet extends StatefulWidget {
  const _PlansSheet({required this.title, required this.cloud, required this.account});
  final String title;
  final bool cloud;
  final Account account;

  @override
  State<_PlansSheet> createState() => _PlansSheetState();
}

final class _PlansSheetState extends State<_PlansSheet> {
  late final _plans = [for (final p in pricing.plans) if (p.cloud || !widget.cloud) p];
  var _interval = pricing.PlanInterval.monthly;
  late var _plan = _plans.first;

  /// Signing in first, to go on to checkout once that's done.
  var _signingIn = false;

  /// Waiting on the API for Stripe's page.
  var _opening = false;

  /// Why the last try didn't open Stripe's page.
  String? _problem;

  Account get _account => widget.account;
  bool get _paid => isPaid(_account.user);

  // Local is yearly only: picked on Monthly, it checks out yearly.
  pricing.PlanPrice get _price => _plan.price(_interval) ?? _plan.price(pricing.PlanInterval.yearly)!;

  @override
  void initState() {
    super.initState();
    _account.addListener(_accountChanged);
  }

  @override
  void dispose() {
    _account.removeListener(_accountChanged);
    super.dispose();
  }

  void _accountChanged() {
    if (_signingIn && _account.user != null) {
      _signingIn = false;
      unawaited(_go());
    }
    setState(() {});
  }

  /// Stripe Checkout for the plan, or the billing portal for someone who
  /// pays already, in the browser; signed out, the sign-in comes first.
  Future<void> _go() async {
    if (_account.user == null) {
      setState(() {
        _signingIn = true;
        _problem = null;
      });
      return;
    }
    setState(() {
      _opening = true;
      _problem = null;
    });
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final url = _paid
        ? await _portalUrl(_account)
        : await _checkoutUrl(_account, _price).catchError(
            // They pay already, as of a moment ago: the portal changes it.
            (_) => _portalUrl(_account),
            test: (e) => e is ApiStatusException && e.statusCode == 409,
          );
      if (!mounted) return;
      Navigator.pop(context);
      await _openStripe(messenger, url);
    } catch (e) {
      if (mounted) {
        setState(() {
          _opening = false;
          _problem = failure('Couldn’t open checkout', e, other: 'Try again.');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    if (_signingIn) return _signIn();
    final narrow = _narrow(context);
    final note = Text(
      _paid ? 'Your plan changes in your browser.' : 'Checkout opens in your browser.',
      style: text.bodySmall!.copyWith(color: brand.fgSoft),
      textAlign: narrow ? TextAlign.center : null,
    );
    final go = brand.accentShadow(
      enabled: !_opening,
      child: TextButton.icon(
        style: brand.button(brand.Tone.accent),
        autofocus: true,
        onPressed: _opening ? null : () => unawaited(_go()),
        iconAlignment: IconAlignment.end,
        icon: const Arrow(),
        label: Text(switch (_opening) {
          true => 'Opening…',
          false when _paid => 'Move to ${_size(_plan)}',
          false => 'Get ${_size(_plan)}',
        }),
      ),
    );
    Widget tile(pricing.Plan plan, {required bool row}) => _PlanTile(
      plan: plan,
      interval: _interval,
      selected: plan == _plan,
      row: row,
      onTap: () => setState(() => _plan = plan),
    );
    return _sheet(
      context: context,
      width: _plans.length > 2 ? 620 : 520,
      // A short window scrolls the sheet rather than clipping the plans.
      child: SingleChildScrollView(
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
          for (final perk in [..._planPerks, if (widget.cloud) _cloudPerk])
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Padding(padding: EdgeInsets.only(top: 1), child: Icon(Icons.check_rounded, size: 17, color: brand.accent)),
                const SizedBox(width: 10),
                Expanded(child: Text(perk, style: text.bodySmall!.copyWith(color: brand.fg))),
              ]),
            ),
          const SizedBox(height: 18),
          _IntervalSwitch(value: _interval, onChanged: (v) => setState(() => _interval = v)),
          const SizedBox(height: 14),
          // Side by side while each plan has room for its price on a line;
          // narrower, one plan to a row.
          LayoutBuilder(builder: (context, box) {
            const gap = 12.0;
            if (box.maxWidth >= 170 * _plans.length + gap * (_plans.length - 1)) {
              return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                for (final (i, plan) in _plans.indexed) ...[
                  if (i > 0) const SizedBox(width: gap),
                  Expanded(child: tile(plan, row: false)),
                ],
              ]);
            }
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (final (i, plan) in _plans.indexed) ...[
                if (i > 0) const SizedBox(height: 8),
                tile(plan, row: true),
              ],
            ]);
          }),
          const SizedBox(height: 22),
          if (narrow)
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [go, const SizedBox(height: 10), note])
          else
            Row(children: [Expanded(child: note), const SizedBox(width: 16), go]),
          if (_problem case final problem?) ...[
            const SizedBox(height: 12),
            Text(problem, style: text.bodySmall!.copyWith(color: brand.danger)),
          ],
        ]),
      ),
    );
  }

  /// Signed out: the plan goes with an account, so signing in comes first;
  /// checkout opens by itself once it's done.
  Widget _signIn() => _sheet(
    context: context,
    width: 480,
    child: SingleChildScrollView(
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          TextButton.icon(
            style: brand.button(brand.Tone.quiet, brand.ButtonSize.sm),
            onPressed: () => setState(() => _signingIn = false),
            icon: const Icon(Icons.arrow_back_rounded, size: 16),
            label: const Text('Plans'),
          ),
          const Spacer(),
          IconButton(
            tooltip: 'Close',
            visualDensity: VisualDensity.compact,
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close_rounded, size: 18, color: brand.fgSoft),
          ),
        ]),
        const SizedBox(height: 14),
        SignInForm(
          account: _account,
          describe: (error) => failure('Couldn’t sign in', error, other: 'Try again.'),
          why: (
            'Sign in to get ${_size(_plan)}',
            'Your plan goes with your ListenJar account. Checkout opens in your browser once you’re in.',
          ),
        ),
      ]),
    ),
  );
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
  const _PlanTile({required this.plan, required this.interval, required this.selected, required this.row, required this.onTap});
  final pricing.Plan plan;
  final pricing.PlanInterval interval;
  final bool selected;

  /// Laid out as a row, for a narrow sheet: what it is on the left, its
  /// price on the right.
  final bool row;
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
    // Local sells only yearly.
    final price = plan.price(widget.interval) ?? plan.price(pricing.PlanInterval.yearly)!;
    final tabular = const [FontFeature.tabularFigures()];
    final per = switch (price.interval) {
      _ when price.interval != widget.interval => 'Yearly only',
      pricing.PlanInterval.monthly => 'Billed every month',
      pricing.PlanInterval.yearly => '${_money((price.amount / 12).round(), price.currency)} a month, billed yearly',
    };
    final period = switch (price.interval) {
      pricing.PlanInterval.monthly => '/ month',
      pricing.PlanInterval.yearly => '/ year',
    };
    final what = switch (_hours(plan)) {
      _ when !plan.cloud => 'On your device, no Cloud',
      final hours? => '$hours in the Cloud',
      null => 'In the Cloud',
    };
    final soft = text.bodySmall!.copyWith(color: brand.fgSoft);
    final small = soft.copyWith(fontSize: 12.5, fontFeatures: tabular);
    final check = AnimatedOpacity(
      opacity: widget.selected ? 1 : 0,
      duration: brand.quick,
      child: const Icon(Icons.check_circle_rounded, size: 20, color: brand.accent),
    );
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
            padding: widget.row ? const EdgeInsets.fromLTRB(16, 14, 16, 14) : const EdgeInsets.fromLTRB(18, 16, 18, 18),
            decoration: BoxDecoration(
              color: widget.selected || _hover ? brand.mist : brand.paper,
              borderRadius: BorderRadius.circular(brand.radiusTile),
              border: Border.all(color: widget.selected ? brand.accent : brand.accent.withValues(alpha: 0), width: 2),
            ),
            child: widget.row
              ? Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Flexible(child: Text(_size(plan), style: text.titleMedium)),
                        const SizedBox(width: 6),
                        check,
                      ]),
                      const SizedBox(height: 2),
                      Text(what, style: soft),
                      Text(per, style: small),
                    ]),
                  ),
                  const SizedBox(width: 12),
                  Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text(_money(price.amount, price.currency), style: text.titleLarge!.copyWith(fontFeatures: tabular)),
                    Text(period, style: soft),
                  ]),
                ])
              : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(child: Text(_size(plan), style: text.titleLarge)),
                    check,
                  ]),
                  const SizedBox(height: 2),
                  Text(what, style: soft),
                  const SizedBox(height: 14),
                  Text.rich(
                    TextSpan(children: [
                      TextSpan(
                        text: _money(price.amount, price.currency),
                        style: text.titleLarge!.copyWith(fontFeatures: tabular),
                      ),
                      TextSpan(text: ' $period', style: soft),
                    ]),
                  ),
                  const SizedBox(height: 2),
                  Text(per, style: small),
                ]),
          ),
        ),
      ),
    );
  }
}

/// Asks for a podcast of the listener's own's name; null if they cancel.
/// A podcast of the listener's own to make: its name, and whether it lives
/// in ListenJar Cloud or on this device.
typedef NewPodcast = ({String title, bool cloud});

/// Asks what to call a new podcast of the listener's own, offering [name],
/// and where to keep it, starting where [startsInCloud] says.
Future<NewPodcast?> askNewPodcast(BuildContext context, {String? name}) {
  final s = Services.of(context);
  return showDialog<NewPodcast>(
    context: context,
    builder: (context) => _NewPodcastSheet(
      hasCloud: hasCloud(s.account.user),
      cloud: startsInCloud(s),
      name: name,
    ),
  );
}

/// Whether something new of the listener's (a playlist or channel they
/// follow, a podcast they make) starts in ListenJar Cloud: on a plan that
/// has it, when Settings says so. Otherwise on this device.
bool startsInCloud(Services s) => hasCloud(s.account.user) && s.library.settings.newInCloud;

final class _NewPodcastSheet extends StatefulWidget {
  const _NewPodcastSheet({required this.hasCloud, required this.cloud, this.name});

  /// Whether the plan has ListenJar Cloud; on Local, picking it leads to
  /// the plans that do.
  final bool hasCloud;

  /// Whether it starts in the Cloud rather than on this device.
  final bool cloud;

  /// The name it starts with, selected to type over.
  final String? name;

  @override
  State<_NewPodcastSheet> createState() => _NewPodcastSheetState();
}

final class _NewPodcastSheetState extends State<_NewPodcastSheet> {
  late final _title = TextEditingController.fromValue(switch (widget.name?.trim()) {
    final name? when name.isNotEmpty => TextEditingValue(text: name, selection: TextSelection(baseOffset: 0, extentOffset: name.length)),
    _ => TextEditingValue.empty,
  });
  late bool _cloud = widget.cloud;

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
    if (title.isNotEmpty) Navigator.pop(context, (title: title, cloud: _cloud));
  }

  Widget _where(TextTheme text, {required bool cloud, required IconData icon, required String title, required String body}) {
    final on = _cloud == cloud;
    return Semantics(
      selected: on,
      button: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => setState(() => _cloud = cloud),
        child: AnimatedContainer(
          duration: brand.quick,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: on ? brand.paper : brand.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: on ? brand.accent.withValues(alpha: 0.6) : brand.line, width: on ? 1.5 : 1),
          ),
          child: Row(children: [
            Icon(icon, color: on ? brand.accent : brand.fgSoft, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: text.titleMedium!.copyWith(fontSize: 14)),
                Text(body, style: text.bodySmall!.copyWith(color: brand.fgSoft)),
              ]),
            ),
          ]),
        ),
      ),
    );
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
        const SizedBox(height: 14),
        _where(text, cloud: false, icon: Icons.laptop_mac_rounded, title: 'On this device', body: ownLocalHint),
        const SizedBox(height: 8),
        _where(text, cloud: true, icon: Icons.cloud_outlined, title: 'In ListenJar Cloud', body: widget.hasCloud ? ownCloudHint : cloudPlanHint),
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

/// What keeping a podcast of the listener's own on this device means, in a line.
const ownLocalHint = 'Its videos stream from YouTube when you play them. Only this app has it.';

/// What keeping it in ListenJar Cloud means, in a line.
const ownCloudHint = 'This device uploads each video you add, for any podcast app. Uses your storage.';

/// What the Cloud takes, for a listener on Local.
const cloudPlanHint = 'For any podcast app. Takes a 10 GB or 100 GB plan.';

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
                  unawaited(manageBilling(context));
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
