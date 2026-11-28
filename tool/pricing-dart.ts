// Writes the live pricing catalog (pricing/catalog.ts) as Dart constants for
// the desktop app's upgrade prompts: `moon run app:codegen`.
//
//   node tool/pricing-dart.ts OUTPUT.dart
import { mkdirSync, writeFileSync } from "node:fs"
import { dirname } from "node:path"
import { PLANS } from "../pricing/catalog.ts"

const [output] = process.argv.slice(2)
if (!output) throw new Error("usage: pricing-dart.ts OUTPUT.dart")

const str = (value: string) => JSON.stringify(value).replaceAll("$", "\\$")

const plans = PLANS.map(
  plan => `  Plan(
    name: ${str(plan.name)},
    description: ${str(plan.description)},
    storageBytes: ${plan.storage_bytes},
    prices: [
${plan.prices
  .map(
    price =>
      `      PlanPrice(interval: PlanInterval.${price.interval}, lookupKey: ${str(price.lookup_key)}, currency: ${str(price.currency)}, amount: ${price.amount}),`,
  )
  .join("\n")}
    ],
  ),`,
).join("\n")

mkdirSync(dirname(output), { recursive: true })
writeFileSync(
  output,
  `// Generated from pricing/catalog.live.json by \`moon run app:codegen\`. Do not edit.

enum PlanInterval { monthly, yearly }

class PlanPrice {
  const PlanPrice({
    required this.interval,
    required this.lookupKey,
    required this.currency,
    required this.amount,
  });

  final PlanInterval interval;

  /// What https://listenjar.com/checkout?price= takes.
  final String lookupKey;
  final String currency;

  /// In cents.
  final int amount;
}

class Plan {
  const Plan({
    required this.name,
    required this.description,
    required this.storageBytes,
    required this.prices,
  });

  final String name;
  final String description;

  /// What it stores in Listenjar Cloud; 0 for Local, which has no Cloud.
  final int storageBytes;

  /// A yearly price, and maybe a monthly one; cheapest first.
  final List<PlanPrice> prices;

  /// Whether it has Listenjar Cloud: 10 GB and 100 GB do, Local doesn't.
  bool get cloud => storageBytes > 0;

  /// Its price for [interval], if it sells one (Local is yearly only).
  PlanPrice? price(PlanInterval interval) {
    for (final price in prices) {
      if (price.interval == interval) return price;
    }
    return null;
  }
}

/// The paid plans, smallest first: Local, then the Cloud ones.
const plans = <Plan>[
${plans}
];
`,
)
