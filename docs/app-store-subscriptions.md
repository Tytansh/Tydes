# Tydes Premium Subscription Setup

Use this checklist before App Store review or TestFlight purchase testing.

## Product IDs

Keep these identifiers stable across App Store Connect, RevenueCat, backend, and Flutter builds.

- App Store subscription product ID: `tydes_premium_monthly`
- RevenueCat entitlement ID: `premium`
- RevenueCat offering ID: `premium`
- RevenueCat monthly package ID: `$rc_monthly`
- Display price: `US$4.99 / month`

## App Store Connect

1. Create the Tydes app record.
2. Add an auto-renewable subscription group for Premium.
3. Add monthly product `tydes_premium_monthly`.
4. Set price tier to US$4.99 monthly or the matching local price tier.
5. Add subscription review screenshot and description.
6. Make sure Paid Apps Agreements, tax, and banking are complete.

## RevenueCat

1. Connect the iOS app in RevenueCat.
2. Import or create product `tydes_premium_monthly`.
3. Create entitlement `premium`.
4. Create offering `premium`.
5. Add the monthly package using package ID `$rc_monthly`.
6. Attach product `tydes_premium_monthly` to that package.
7. Copy the iOS SDK API key for Flutter builds.
8. Copy the RevenueCat secret API key into Render as `REVENUECAT_SECRET_API_KEY`.

## Render backend environment

Required:

```text
REVENUECAT_ENTITLEMENT_ID=premium
REVENUECAT_SECRET_API_KEY=<RevenueCat secret API key>
```

After changing either value, redeploy `tydes-api`.

## Flutter production run

Use the real iOS SDK API key from RevenueCat for TestFlight/App Store builds.

```bash
cd /Users/tytans/Documents/Playground/apps/mobile_flutter
flutter run \
  --dart-define=API_BASE_URL=https://api.tydes.io/api/v1 \
  --dart-define=REVENUECAT_IOS_API_KEY=<real_ios_revenuecat_sdk_key> \
  --dart-define=REVENUECAT_ANDROID_API_KEY=<real_android_revenuecat_sdk_key_if_available> \
  --dart-define=REVENUECAT_ENTITLEMENT_ID=premium \
  --dart-define=REVENUECAT_OFFERING_ID=premium \
  --dart-define=REVENUECAT_PACKAGE_ID='$rc_monthly'
```

## App Store reviewer account

Create one real Tydes account for review and write it in App Review Notes.

Recommended:

```text
Email: reviewer@tydes.io or another email you control
Password: a real password only stored in App Store Connect review notes
Premium: active test subscription or backend/admin premium override for review
```

Do not put reviewer passwords in GitHub.

## Manual test

1. Fresh install the app.
2. Sign in as the reviewer account.
3. Open Settings -> Manage premium.
4. Confirm price shows `US$4.99` from RevenueCat.
5. Tap Upgrade to Premium in sandbox/TestFlight.
6. Confirm Tydes shows Premium active.
7. Tap Restore Purchases and confirm Premium remains active.
8. Confirm live forecasts/tides unlock beyond the free spot.
