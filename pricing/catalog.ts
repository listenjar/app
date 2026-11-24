// The ListenJar plans and prices, synced from Stripe by
// scripts/sync-stripe-pricing.ts in the listenjar monorepo
// (`moon run root:pricing-sync`) and committed here. Only what the apps read:
// the backend maps product ids to storage and checks lookup keys, the web
// pricing page and the desktop app (tool/pricing-dart.ts) show the rest.
// Every app reads the live catalog. The sandbox's (catalog.test.json) must
// match it, which `root:pricing-check` enforces, so dev checks out in the
// sandbox exactly what production sells.
import live from "./catalog.live.json" with { type: "json" }

export type Interval = "monthly" | "yearly"

export interface PlanPrice {
  interval: Interval
  /** What https://listenjar.com/checkout?price= takes. */
  lookup_key: string
  currency: string
  /** In cents. */
  amount: number
}

export interface Plan {
  /** The same in live and sandbox. */
  product_id: string
  name: string
  description: string
  storage_bytes: number
  prices: PlanPrice[]
}

export interface PricingCatalog {
  plans: Plan[]
}

export const CATALOG: PricingCatalog = live as PricingCatalog

/** The paid plans, smallest first. */
export const PLANS: readonly Plan[] = CATALOG.plans

/** A plan's price for the interval. */
export const planPrice = (plan: Plan, interval: Interval): PlanPrice =>
  plan.prices.find(price => price.interval === interval)!

/** The plan selling this lookup key, if any. */
export const planByLookupKey = (key: string): Plan | undefined =>
  PLANS.find(plan => plan.prices.some(price => price.lookup_key === key))
