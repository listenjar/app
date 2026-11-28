// The Listenjar plans and prices, synced from Stripe by
// scripts/sync-stripe-pricing.ts in the listenjar monorepo
// (`moon run root:pricing-sync`) and committed here. Only what the apps read:
// the backend maps product ids to storage and checks lookup keys, the web
// pricing page and the desktop app (tool/pricing-dart.ts) show the rest.
//
// Every plan unlocks the paid features. Local (storage_bytes 0) keeps them on
// the listener's device; 10 GB and 100 GB add Listenjar Cloud, which hosts
// that much audio.
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
  /** What it stores in Listenjar Cloud; 0 for Local, which has no Cloud. */
  storage_bytes: number
  /** A yearly price, and maybe a monthly one; cheapest first. */
  prices: PlanPrice[]
}

export interface PricingCatalog {
  plans: Plan[]
}

export const CATALOG: PricingCatalog = live as PricingCatalog

/** The paid plans, smallest first: Local, then the Cloud ones. */
export const PLANS: readonly Plan[] = CATALOG.plans

/** Whether the plan has Listenjar Cloud: 10 GB and 100 GB do, Local doesn't. */
export const hasCloud = (plan: Plan): boolean => plan.storage_bytes > 0

/** A plan's price for the interval, if it sells one (Local is yearly only). */
export const planPrice = (
  plan: Plan,
  interval: Interval,
): PlanPrice | undefined => plan.prices.find(price => price.interval === interval)

/** The plan selling this lookup key, if any. */
export const planByLookupKey = (key: string): Plan | undefined =>
  PLANS.find(plan => plan.prices.some(price => price.lookup_key === key))
