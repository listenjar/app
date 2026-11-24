// Writes the live pricing catalog (pricing/catalog.ts) as Dart constants for
// the desktop app's upgrade prompts: `moon run desktop:codegen`.
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
  `// Generated from pricing/catalog.live.json by \`moon run desktop:codegen\`. Do not edit.

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
  final int storageBytes;
  final List<PlanPrice> prices;

  PlanPrice price(PlanInterval interval) =>
      prices.firstWhere((price) => price.interval == interval);
}

/// The paid plans, smallest first.
const plans = <Plan>[
${plans}
];
`,
)
