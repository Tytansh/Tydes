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
5. Store the web configuration's **public** `strp_` (Stripe Billing) or `rcb_`
   (RevenueCat Billing) SDK key in Render as `REVENUECAT_WEB_API_KEY`. Never put
   a secret/REST/Stripe secret key in this variable.
6. Keep `REVENUECAT_WEB_CHECKOUT_ENABLED=false` during preparation. An optional
   comma-separated `REVENUECAT_WEB_CHECKOUT_USER_IDS` permits only explicitly
   selected pilot accounts. Disabled accounts receive no public SDK key.
   Redeploy the API. The website reads public configuration from authenticated
   `/billing/config`; no new Flutter build is needed merely to activate the key.
7. Test in the provider sandbox with a dedicated test account, then verify live
   configuration separately. Never point public checkout at a sandbox provider.

Until a public web SDK key is configured and checkout is enabled, Subscribe is disabled and the
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

### Authenticated subscription notifications

- RevenueCat callback: `POST https://api.tydes.io/api/v1/billing/webhooks/revenuecat`.
- Set a strong, unique `REVENUECAT_WEBHOOK_AUTHORIZATION` value in Render and
  the identical Authorization header value in RevenueCat. This secret must
  never appear in Flutter, browser config, documentation, or request logs.
- Optional `REVENUECAT_WEBHOOK_SIGNING_SECRET` verifies RevenueCat's raw-body
  HMAC SHA-256 signature and rejects timestamps outside five minutes. If both
  credentials are configured, both must pass.
- The endpoint fails closed with 503 until at least one credential is set;
  missing/invalid credentials return 401. Bodies are capped at 64 KiB.
- `REVENUECAT_WEBHOOK_ENVIRONMENTS=PRODUCTION` by default. Sandbox callbacks
  must be deliberately routed to the corresponding test environment.
- Each callback re-fetches the current RevenueCat subscriber for existing
  Tydes IDs, including both sides of transfers. Event payloads never grant
  Premium directly, and unknown/anonymous IDs cannot create accounts.
- Only successful events receive a durable receipt (Postgres in production,
  state file locally). Failed verification returns 503 for provider retry.
  Replayed events are acknowledged without repeating verification; receipt
  IDs are retained for 90 days, not raw payment/customer payloads.
- Postgres billing updates patch only subscription fields, preserving profile
  edits, bans, and admin Premium grants. Cached period expiration triggers a
  fresh verification even if the ordinary hourly check is not yet due.

### Cancellation setup (2026-11-08)

- Live Stripe portal `bpc_1UZXKuRypzI92JMkqB5Km0Ut` activated and connected to
  the live RevenueCat web configuration's Subscription management tab.
- Cancellation at the end of the billing period is enabled. Invoice history
  and payment-method management are available; plan switching and quantity
  changes are disabled. Redirect returns to `https://tydes.io/#/profile`.
- Public web purchases remain gated off pending sandbox end-to-end testing,
  browser compatibility, and live checkout/merchant-of-record checks.
- User explicitly approved the private callback credential connection. The
  random credential was saved only in RevenueCat and Render, never in source,
  chat output, or a local credentials file.
- Production webhook `whintgra91206fd972c42469937f250ceaf7212` is configured for
  production-only events, all apps. A RevenueCat dashboard TEST delivery
  returned HTTP 200 with `{"status":"test_received"}` on 2026-11-08.
- Render release `c56fb9a` is live (deployment `dep-dbo94e6c6qcc73d08n90`), with
  the live public `strp_` SDK key and `REVENUECAT_WEB_CHECKOUT_ENABLED=false`.
  No pilot-user allowlist is enabled. Existing unrelated environment variables
  and hosting plans were preserved.
- Post-deployment API readiness returned 200. Unauthenticated webhook and
  `/billing/config` requests each returned 401. All 83 backend tests passed.
- No real charge was made. The successful TEST callback proves authenticated
  delivery, not a completed purchase, renewal, refund, or portal cancellation.
- Customer subscription-management links come from RevenueCat, not user input.
- After store success with delayed verification, checkout stays disabled in that
  session and the user is directed to Check/Restore rather than buying twice.
- Production lifecycle updates use the authenticated webhook configured above;
  hourly verification remains a recovery path, not a real-time delivery SLA.
  Sandbox events are deliberately excluded from the production webhook.

### Isolated sandbox checkout verification (2026-11-09)

- Updated `purchases_flutter` from 10.1.1 to pinned 10.19.0. The newer bundled
  web SDK supports Stripe sandbox configuration keys; this update alone did
  **not** resolve the Chrome blank embedded-checkout issue.
- Tested a loopback-only build with a new, user-created and email-verified
  non-Premium account. Sandbox public configuration was supplied in memory
  only to that account. No live environment key, checkout gate, default
  offering, reviewer access, or real payment method was changed.
- Created the separate `sandbox_checkout_test` offering with only the existing
  sandbox monthly product, and a sandbox-only RevenueCat Web Purchase Link.
  Never publish or distribute that link as a customer purchase option.
- Both embedded checkout and RevenueCat's HTTPS hosted checkout were blank in
  the tested Chrome profile. The same hosted checkout loaded in Codex's in-app
  browser. The specific Chrome cause remains unconfirmed; do not attribute it
  to an extension without an isolated reproduction.
- Verified Stripe's sandbox `livemode: false` before submission. Its fake
  insufficient-funds card was declined. A successful fake-card purchase then
  activated the correct customer's sandbox entitlement in RevenueCat.
- Tydes' authenticated **Check subscription** verified that entitlement through
  the real backend and displayed **Premium active**. This was not a manual
  complimentary grant. No real money was charged.
- Checkout showed the US$3.99 monthly base price, plus US$0.20 test tax for a
  synthetic Canadian billing postal code. That test total is not a promise of
  every customer's final tax or proof of live Managed Payments coverage.
- **Manage subscription** opened the configured sandbox portal. Its email-login
  page was checked, then the authenticated Stripe dashboard's **Open customer
  portal** action supplied a session for this synthetic test customer. No real
  customer's email or portal session was used.
- The customer portal accepted end-of-period cancellation and showed service
  ending December 8, 2026. Paid-period access correctly remains active; actual
  time-based expiry, refund/revocation, native-device login, and live purchases
  have not yet been verified end-to-end.
- Public checkout remains disabled. Before enabling it, resolve Chrome's blank
  form, verify live payout/readiness and actual merchant-of-record eligibility,
  and complete remaining lifecycle/cross-device checks.

### Owner-only live pilot and production build repair (2026-11-09)

- Ordinary Chrome navigation rendered the hosted sandbox card form correctly;
  an automation-created tab remained blank. This narrows the earlier Chrome
  finding to the tested browser-control path, not all Chrome checkout usage.
  No browser extensions, security settings, or cookies were disabled.
- The owner's account has an expired historical Apple **sandbox** subscription
  and no active live RevenueCat entitlement. It was not manually granted
  Premium as part of this test.
- Stripe Account status showed **Payments** and **Payouts** active, no active
  verification tasks, and a CAD Wise account linked. This is not evidence of
  a completed payout or a guarantee that future verification cannot be needed.
- Added only the owner's verified account ID to Render's
  `REVENUECAT_WEB_CHECKOUT_USER_IDS`. The global
  `REVENUECAT_WEB_CHECKOUT_ENABLED` stays **false**. The pilot is a real monthly
  purchase option; never enter sandbox fake-card numbers in that live flow.
  Do not use an owner payment or another real card as a test transaction;
  exercise purchase failures, activation, refunds, and cancellation in sandbox.
  The agent does not submit real payments.
- The pilot exposed a separate production artifact problem: the deployed
  `main.dart.js` omitted the web payment plugin's registration/interop code,
  despite the vendor asset being present. The working sandbox build included
  it. A fresh production compilation with a new `BILLING_BUILD_REVISION` Dart
  define restored the missing code. Do not rely on build exit status alone.
- Before copying a Flutter release into Sites, run:

  ```sh
  bash tool/verify_web_billing.sh /absolute/path/to/web-build
  ```

  This rejects the observed incomplete artifact and checks both the compiled
  plugin and its vendored JavaScript. It does not replace browser checkout QA.
- Rechecked 75 billing/API integration tests, including owner-only gating,
  expiration, refund-state reconciliation, duplicate/out-of-order callbacks,
  and isolation between accounts. These automated tests are not a claim that
  every lifecycle event has been observed in a real transaction.
- Published the repaired artifact as Sites version 59, source commit
  `02d09d24dcec10fe0b92cd4c885c9a5aa14fa21f`, deployment
  `appgdep_6af150bd6c208191b2d586a6e630cf38`. On `tydes.io`, the signed-in
  pilot account then loaded **US$3.99 / month** and an enabled **Subscribe
  monthly** button. The initial account-only environment deployment was
  `dep-dbokp2ajnfac73f7kcsg`. No real payment was submitted by the agent.

### Billing safeguards and customer disclosures (2026-11-09)

- RevenueCat Project settings -> General -> Sandbox testing access now uses
  **Allowed App User IDs only**. The saved list contains the dedicated verified
  test account and the owner's internal account (two IDs). Other users cannot
  gain Premium from sandbox/Test Store purchases. Real production purchases
  are unaffected. Add future approved TestFlight testers explicitly; do not
  restore the default **Anybody** setting for public testing.
- Saved the existing public business contact `support@tydes.io`, support URL
  `https://tydes.io/support`, Privacy URL `https://tydes.io/privacy`, and Terms
  URL `https://tydes.io/terms` in live Stripe customer-support details. No bank,
  identity, business classification, phone, or price changes were made.
- The owner explicitly approved publishing website-billing disclosures naming
  Stripe/Link and RevenueCat, monthly auto-renewal, cancellation and payment
  data handling. Published Terms, Privacy and Support as Sites version 60,
  source commit `c01b56da379ea5b1a83d678d6bee9188cb8e6c9a`, deployment
  `appgdep_6af157b7f118819192ab31c2c5cc6a46`. The previously verified working
  Flutter bundle was preserved, and the web billing build guard passed.
- Enabled live Stripe emails for upcoming renewals, expiring cards, failed
  card payments and failed bank-debit payments. Emails include the Stripe
  customer portal; payment-method updates use a Stripe-hosted page. The owner
  specifically approved leaving legacy mixed-link mode after Stripe warned
  that this migration cannot be reversed. No paid notification/recovery add-on
  was enabled. The existing upcoming-renewal schedule remains seven days.
- Re-ran the 75 API/billing tests successfully. This does not replace the
  still-outstanding sandbox refund/expiry and native cross-device checks.
- Global public checkout remains disabled. The existing owner-only pilot
  allowlist was not widened, and no real payment was submitted.

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

### Live account preparation (2026-11-08)

The owner completed Stripe onboarding and entered the live Tydes account.
Only the Premium product was copied from the sandbox; the copy options for
Managed Payments settings and the RevenueCat app were explicitly unchecked.

- Live Stripe account: `acct_1UYiHvRypzI92JMk`
- Copied product: `prod_VaDu6F9vhRX18Z` / Tydes Premium Monthly
- Live price: `price_1UZTAuRypzI92JMkiyHblAWP`, USD 3.99 recurring monthly
- No trial; zero active subscriptions at inspection
- Product category remained Website Information Services - Personal Use
  (`txcd_10701401`); the product page marked it eligible for Managed Payments
- The live setup guide marked both Managed Payments steps complete and
  "Activate products" complete. This does not prove any specific checkout
  transaction will use Managed Payments; verify that before live sales.
- After explicit owner approval, the official RevenueCat app version 0.3.2
  was installed in the live account and linked to `tytan@tydes.io`.
- RevenueCat Account settings confirmed both the existing sandbox connection
  and the Tydes account above in **Live** mode, with a green app-version status.
- The separate live Stripe Billing web configuration and product mapping were
  subsequently completed as recorded below. The sandbox web configuration
  must not be substituted for the live configuration.

The owner approved the app terms and live permissions, including management of
customers, subscriptions, checkout, payments/refunds, and products/prices, with
data shared with RevenueCat. The authorized installation and link were then
completed and verified. No API keys or production checkout configuration were
changed, and no real charges, payouts, customers, or subscriptions were created
by these steps.

### Live web product mapping (2026-11-08)

- Project collaborator settings confirmed `tytan@tydes.io` as Owner.
- Created **Tydes Web — Live**, `app8dce4f6854`, using Stripe Billing and the
  live account `acct_1UYiHvRypzI92JMk`.
- Enabled **Use Managed Payments in RevenueCat purchases when available**.
  This still allows standard-Billing fallback; verify actual checkout handling
  before enabling public purchases.
- Saved customer-facing name **Tydes**. The Appearance attention marker cleared.
- Imported live price `price_1UZTAuRypzI92JMkiyHblAWP` (USD 3.99 monthly,
  no free trial) as RevenueCat product `proda37a7136f6`; status **Published**.
- Attached the product to existing entitlement `premium`.
- Added it to offering `premium`, package `$rc_monthly`, alongside the Apple,
  sandbox, and Test Store products. All prior product selections were retained.
- The live provider's **Customer Portal URL** was initially empty; it is now
  connected to the activated Stripe portal (see Cancellation setup above).
- Render sign-in was restored through the existing GitHub login. Its Deploys
  page confirms backend commit `90d3b90` (verified checkout preparation) was
  deployed. Subsequent callback deployment/configuration is recorded above;
  no hosting plans were changed.

Public website checkout remains explicitly disabled, although the live public
SDK key and private callback authentication are now installed securely.
Remaining launch checks include sandbox end-to-end purchase/cancellation and
cross-platform entitlement tests, actual Managed Payments behavior, and payout
readiness. The installed Flutter SDK's vendor web bundle contains Stripe
Billing support; full checkout behavior is still unverified. No real
payment or subscription was created to verify these settings.

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
