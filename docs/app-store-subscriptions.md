# Tydes Premium Subscription Setup

Use this checklist before App Store review or TestFlight purchase testing.

## Product IDs

Keep these identifiers stable across App Store Connect, RevenueCat, backend, and Flutter builds.

- App Store subscription product ID: `tydes_premium_monthly`
- RevenueCat entitlement ID: `premium`
- RevenueCat offering ID: `premium`
- RevenueCat monthly package ID: `$rc_monthly`
- Display price: `US$3.99 / month`

## App Store Connect

1. Create the Tydes app record.
2. Add an auto-renewable subscription group for Premium.
3. Add monthly product `tydes_premium_monthly`.
4. Set price tier to US$3.99 monthly or the matching local price tier.
5. Add subscription review screenshot and description.
6. Make sure Paid Apps Agreements, tax, and banking are complete.

## RevenueCat

1. Connect the iOS app in RevenueCat.
2. Import or create product `tydes_premium_monthly`.
3. Create entitlement `premium`.
4. Create offering `premium`.
5. Add the monthly package using package ID `$rc_monthly`.
6. Attach product `tydes_premium_monthly` to that package.
7. Verify the public iOS SDK API key matches the default in
   `RevenueCatService`; use a Dart define only when overriding it.
8. Copy the RevenueCat secret API key into Render as `REVENUECAT_SECRET_API_KEY`.

## Website subscriptions (Stripe Billing + RevenueCat)

Website checkout is a separate product configuration from Apple purchases. Keep
both products attached to the same `premium` entitlement and use the signed-in
Tydes user ID on both platforms. Do not use email addresses as subscription IDs.

1. The account owner connects their Stripe account to RevenueCat through the
   official RevenueCat app in the Stripe marketplace. The owner must complete
   any business/bank verification, account activation, permission grants, and
   agreements. Do not create a sandbox account as a substitute for live billing.
2. In RevenueCat -> Web, choose **Stripe Billing**, using the connected Stripe
   account. Request Managed Payments when available. Managed Payments is not
   supported by the separate RevenueCat Billing engine. Use Tydes branding.
3. Create the monthly USD 3.99 product and price in **Stripe**, then import the
   price into the matching RevenueCat Stripe configuration. Review checkout,
   cancellation, billing email, and applicable tax settings before live sales.
   Managed Payments must be enabled in Stripe and the product must be eligible;
   the RevenueCat toggle alone does not guarantee merchant-of-record handling.
4. Attach that product to entitlement `premium` and to package `$rc_monthly` in
   offering `premium`, alongside the existing Apple product.
5. Store the web configuration's **public** `rcb_` SDK key in Render as
   `REVENUECAT_WEB_API_KEY`. Never put a secret/REST/Stripe key in this variable.
6. Redeploy the API. The website reads public configuration from authenticated
   `/billing/config`; no new Flutter build is needed merely to activate the key.
7. Test in the provider sandbox with a dedicated test account, then verify live
   configuration separately. Never point public checkout at a sandbox provider.

Until a public web SDK key is configured, web Subscribe is disabled and the
page explains that purchases are unavailable on that platform. Existing
subscribers can still use Check subscription with their signed-in account.

### Verification and lifecycle

- Purchases and restores are verified using the backend RevenueCat secret, not
  a client-supplied Premium flag, user ID, or receipt status.
- Authenticated account reads refresh RevenueCat at most hourly after a
  successful verification, with a bounded retry rate during outages.
- Persisted expiration/grace-period dates remove expired access during session
  resolution. A verified renewal extends access on the next account refresh.
- Reopening/resuming the app refreshes account access without blanking the feed.
- Complimentary admin/reviewer access survives subscription expiration.
- Customer subscription-management links come from RevenueCat, not user input.
- After store success with delayed verification, checkout stays disabled in that
  session and the user is directed to Check/Restore rather than buying twice.
- No billing webhook has been configured by this code change. For immediate
  server-to-server cancellation/refund updates, add an authenticated webhook
  integration before a wider paid launch; hourly verification is the current
  recovery path, not a claim of real-time webhook delivery.

### Last dashboard inspection (2026-11-06)

The Apple product `tydes_premium_monthly` was attached to the expected offering,
monthly package, and entitlement. The Apple in-app purchase key was marked
valid. The separate App Store Connect API key was absent, so RevenueCat could
not pull/check product store status. There were no web providers and no Stripe
accounts connected. No live charge or paid subscription was created during
implementation. Recheck these dashboard states before launch.

### Sandbox setup (2026-11-07)

The owner approved installing the official RevenueCat Stripe app and linking
the Tydes sandbox to the RevenueCat account `tytan@tydes.io`. RevenueCat's
account connection table confirms Sandbox mode and app version 0.3.2.

- Stripe sandbox: `acct_1UYSgr2OJTZx2LP3`
- RevenueCat web configuration: `Tydes Web — Sandbox`, `appa40b206756`
- Engine: Stripe Billing, not RevenueCat Billing
- Managed Payments requested in the RevenueCat configuration
- Customer-facing name: `Tydes`
- Stripe product: `prod_VaDu6F9vhRX18Z` / Tydes Premium Monthly
- Stripe price: `price_1UZ3SS2OJTZx2LP3YHENkGNd`, USD 3.99 recurring monthly,
  no free trial, tax-exclusive
- Imported RevenueCat product: `prod2839bdf097`
- Attached entitlement: `premium`
- Added to offering `premium`, package `$rc_monthly`, alongside (not replacing)
  the Apple and existing Test Store products
- Sandbox candidate product category: Website Information Services - Personal
  Use (`txcd_10701401`); Stripe marked this category eligible for Managed
  Payments. This is a test configuration, not a final legal tax determination.

Stripe's sandbox setup guide marked both "Get started with Managed Payments"
and "Tell us what you're selling" complete. The sandbox default category was
set to the same candidate category as the Premium test product.

No live payments, production checkout key, or real purchase were enabled by
this sandbox setup. The account verification guide showed email verified but
"Activate Payments" not started and Stripe profile creation blocked. Before
going live, the owner must complete activation and any business/bank/identity
verification privately, verify the final product classification and Managed
Payments approval, connect the live Stripe account separately, and perform
end-to-end purchase/cancellation tests. No sandbox SDK key should be exposed
through the production website's billing configuration.

## Render backend environment

Required:

```text
REVENUECAT_ENTITLEMENT_ID=premium
REVENUECAT_SECRET_API_KEY=<RevenueCat secret API key>
```

Optional reviewer/demo premium override:

```text
TYDES_PREMIUM_EMAILS=reviewer@tydes.io
```

Use this only for accounts we control, such as the App Store reviewer account.
Do not put normal customer emails here.

After changing either value, redeploy `tydes-api`.

## Flutter production run

The public RevenueCat iOS SDK key is compiled into the app by default. It is a
client identifier, not the secret backend API key. The Dart define below is
only needed to override the default for a different RevenueCat app.

```bash
cd /Users/tytans/Documents/Playground/apps/mobile_flutter
flutter run \
  --dart-define=API_BASE_URL=https://api.tydes.io/api/v1 \
  --dart-define=REVENUECAT_IOS_API_KEY=<optional_ios_sdk_key_override> \
  --dart-define=REVENUECAT_ANDROID_API_KEY=<real_android_revenuecat_sdk_key_if_available> \
  --dart-define=REVENUECAT_ENTITLEMENT_ID=premium \
  --dart-define=REVENUECAT_OFFERING_ID=premium \
  --dart-define=REVENUECAT_PACKAGE_ID='$rc_monthly' \
  --dart-define=MAPTILER_API_KEY='<maptiler_api_key>' \
  --dart-define=MAPTILER_MAP_ID='outdoor-v2'
```

See `docs/map-provider.md` before TestFlight/App Store builds. The app has a
development fallback, but production should use a provider that is safe for
mobile app traffic.

## App Store reviewer account

Create one real Tydes account for review and write it in App Review Notes.

Recommended:

```text
Email: reviewer@tydes.io or another email you control
Password: a real password only stored in App Store Connect review notes
Premium: active test subscription or backend/admin premium override for review
```

For the backend override path, set this in Render:

```text
TYDES_PREMIUM_EMAILS=reviewer@tydes.io
```

Do not put reviewer passwords in GitHub.

## Manual test

1. Fresh install the app.
2. Sign in as the reviewer account.
3. Open Settings -> Manage premium.
4. Confirm RevenueCat shows `US$3.99` in the US storefront or Apple's
   localized equivalent (for example, `CA$4.99` in Canada).
5. Tap Upgrade to Premium in sandbox/TestFlight.
6. Confirm Tydes shows Premium active.
7. Tap Restore Purchases and confirm Premium remains active.
8. Confirm live forecasts/tides unlock beyond the free spot.
